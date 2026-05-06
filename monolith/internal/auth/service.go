package auth

import (
	"context"
	"errors"
	"fmt"
	"net/mail"
	"reflect"
	"strings"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
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
	repo   Repository
	hasher PasswordHasher
	signer TokenSigner
}

func NewService(repo Repository, hasher PasswordHasher, signer TokenSigner) *Service {
	mustNotBeNil("repo", repo)
	mustNotBeNil("hasher", hasher)
	mustNotBeNil("signer", signer)
	return &Service{repo: repo, hasher: hasher, signer: signer}
}

func (s *Service) Register(ctx context.Context, req RegisterRequest) (UserResponse, error) {
	name := strings.TrimSpace(req.Name)
	email := strings.ToLower(strings.TrimSpace(req.Email))
	if name == "" {
		return UserResponse{}, apperror.BadRequest("invalid request payload", map[string]any{"name": "is required"})
	}
	if !isEmail(email) {
		return UserResponse{}, apperror.BadRequest("invalid request payload", map[string]any{"email": "must be a valid email"})
	}
	if len(req.Password) < 8 {
		return UserResponse{}, apperror.BadRequest("invalid request payload", map[string]any{"password": "must be at least 8 characters"})
	}

	passwordHash, err := s.hasher.Hash(req.Password)
	if err != nil {
		return UserResponse{}, apperror.Internal("internal server error", fmt.Errorf("hashing password: %w", err))
	}

	user, err := s.repo.CreateUser(ctx, name, email, passwordHash)
	if err != nil {
		return UserResponse{}, err
	}

	return toUserResponse(user), nil
}

func (s *Service) Login(ctx context.Context, req LoginRequest) (LoginResponse, error) {
	email := strings.ToLower(strings.TrimSpace(req.Email))
	if !isEmail(email) {
		return LoginResponse{}, apperror.BadRequest("invalid request payload", map[string]any{"email": "must be a valid email"})
	}
	if len(req.Password) < 8 {
		return LoginResponse{}, apperror.BadRequest("invalid request payload", map[string]any{"password": "must be at least 8 characters"})
	}

	user, err := s.repo.FindUserByEmail(ctx, email)
	if err != nil {
		return LoginResponse{}, err
	}
	if err := s.hasher.Compare(user.PasswordHash, req.Password); err != nil {
		if errors.Is(err, ErrPasswordMismatch) {
			return LoginResponse{}, apperror.Unauthorized("invalid email or password")
		}
		return LoginResponse{}, apperror.Internal("internal server error", fmt.Errorf("comparing password: %w", err))
	}

	token, err := s.signer.Sign(user.ID)
	if err != nil {
		return LoginResponse{}, apperror.Internal("internal server error", fmt.Errorf("signing token: %w", err))
	}

	return LoginResponse{Token: token, User: toUserResponse(user)}, nil
}

func isEmail(value string) bool {
	if value == "" {
		return false
	}
	addr, err := mail.ParseAddress(value)
	return err == nil && addr.Address == value && addr.Name == ""
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
