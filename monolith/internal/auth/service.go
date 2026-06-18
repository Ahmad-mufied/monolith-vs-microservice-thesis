package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/mail"
	"reflect"
	"strings"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/admission"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/debuglog"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/validation"
)

type Repository interface {
	CreateUser(ctx context.Context, name, email, passwordHash string) (User, error)
	FindUserByEmail(ctx context.Context, email string) (User, error)
}

type PasswordHasher interface {
	Hash(password string) (string, error)
	Compare(hash, password string) error
}

type TokenSigner interface {
	Sign(userID string) (string, error)
}

type Service struct {
	repo    Repository
	hasher  PasswordHasher
	signer  TokenSigner
	limiter *admission.Limiter
}

const (
	maxPasswordBytes = 72
)

func NewService(repo Repository, hasher PasswordHasher, signer TokenSigner, limiter *admission.Limiter) *Service {
	mustNotBeNil("repo", repo)
	mustNotBeNil("hasher", hasher)
	mustNotBeNil("signer", signer)
	mustNotBeNil("limiter", limiter)
	return &Service{repo: repo, hasher: hasher, signer: signer, limiter: limiter}
}

func (s *Service) Register(ctx context.Context, req RegisterRequest) (RegisterResponse, error) {
	name := strings.TrimSpace(req.Name)
	email := strings.ToLower(strings.TrimSpace(req.Email))

	normalizedReq := RegisterRequest{Name: name, Email: email, Password: req.Password}
	if err := validation.Struct(normalizedReq); err != nil {
		return RegisterResponse{}, err
	}
	if !isEmail(email) {
		return RegisterResponse{}, apperror.BadRequest("invalid request payload", map[string]any{"email": "must be a valid email"})
	}
	if err := validatePasswordBytes(req.Password); err != nil {
		return RegisterResponse{}, err
	}
	passwordHash, err := apperror.CallIfActive(ctx, func() (string, error) {
		return s.hasher.Hash(req.Password)
	})
	if err != nil {
		if apperror.IsContext(err) {
			return RegisterResponse{}, err
		}
		return RegisterResponse{}, apperror.Internal("internal server error", fmt.Errorf("hashing password: %w", err))
	}

	user, err := apperror.CallIfActive(ctx, func() (User, error) {
		return s.repo.CreateUser(ctx, name, email, passwordHash)
	})
	if err != nil {
		return RegisterResponse{}, err
	}

	return RegisterResponse{
		Message: "User registered successfully",
		Data: RegisterResponseData{
			User: toUserSummary(user),
		},
	}, nil
}

func (s *Service) Login(ctx context.Context, req LoginRequest) (LoginResponse, error) {
	email := strings.ToLower(strings.TrimSpace(req.Email))

	normalizedReq := LoginRequest{Email: email, Password: req.Password}
	if err := validation.Struct(normalizedReq); err != nil {
		return LoginResponse{}, err
	}
	if !isEmail(email) {
		return LoginResponse{}, apperror.BadRequest("invalid request payload", map[string]any{"email": "must be a valid email"})
	}
	if err := validatePasswordBytes(req.Password); err != nil {
		return LoginResponse{}, err
	}
	var user User
	err := s.limiter.Do(ctx, func() error {
		var dbErr error
		user, dbErr = apperror.CallIfActive(ctx, func() (User, error) {
			return s.repo.FindUserByEmail(ctx, email)
		})
		if dbErr != nil {
			return dbErr
		}

		return apperror.DoIfActive(ctx, func() error {
			return s.hasher.Compare(user.PasswordHash, req.Password)
		})
	})
	if err != nil {
		if appErr, ok := errors.AsType[*apperror.Error](err); ok {
			switch appErr.Code {
			case apperror.CodeUnauthorized, apperror.CodeNotFound:
				return LoginResponse{}, apperror.Unauthorized("invalid email or password")
			}
		}
		if errors.Is(err, ErrPasswordMismatch) {
			return LoginResponse{}, apperror.Unauthorized("invalid email or password")
		}
		if admission.IsRejected(err) {
			debuglog.Error(context.Background(), slog.LevelWarn, "monolith auth login failed", "monolith_auth_login_service_failure", err, "category", "resource_exhausted")
			return LoginResponse{}, apperror.ServiceUnavailable("login service is temporarily overloaded", err)
		}
		if apperror.IsContext(err) {
			debuglog.Error(context.Background(), slog.LevelWarn, "monolith auth login failed", "monolith_auth_login_service_failure", err, "category", "context")
			if ctxErr := apperror.FromContext(err, "request timeout", "request canceled"); ctxErr != nil {
				return LoginResponse{}, ctxErr
			}
			return LoginResponse{}, err
		}
		debuglog.Error(context.Background(), slog.LevelError, "monolith auth login failed", "monolith_auth_login_service_failure", err, "category", "login_internal")
		return LoginResponse{}, apperror.Internal("internal server error", fmt.Errorf("login failed: %w", err))
	}

	token, err := apperror.CallIfActive(ctx, func() (string, error) {
		return s.signer.Sign(user.ID)
	})
	if err != nil {
		if apperror.IsContext(err) {
			debuglog.Error(context.Background(), slog.LevelWarn, "monolith auth login failed", "monolith_auth_login_service_failure", err, "category", "jwt_context")
			return LoginResponse{}, err
		}
		debuglog.Error(context.Background(), slog.LevelError, "monolith auth login failed", "monolith_auth_login_service_failure", err, "category", "jwt_internal")
		return LoginResponse{}, apperror.Internal("internal server error", fmt.Errorf("signing token: %w", err))
	}

	return LoginResponse{
		Message: "Login successful",
		Data: LoginResponseData{
			Token: token,
			User:  toUserSummary(user),
		},
	}, nil
}

func isEmail(value string) bool {
	if value == "" {
		return false
	}
	addr, err := mail.ParseAddress(value)
	return err == nil && addr.Address == value && addr.Name == ""
}

func validatePasswordBytes(password string) error {
	if len(password) > maxPasswordBytes {
		// #nosec G101 -- "password" is the public request field name in the validation payload, not a hardcoded credential.
		return apperror.BadRequest("invalid request payload", map[string]any{"password": "must be at most 72 bytes for bcrypt compatibility"})
	}
	return nil
}

func mustNotBeNil(name string, value any) {
	if value == nil {
		panic(fmt.Sprintf("auth service dependency %q is required", name))
	}
	v := reflect.ValueOf(value)
	switch v.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		if v.IsNil() {
			panic(fmt.Sprintf("auth service dependency %q is required", name))
		}
	}
}
