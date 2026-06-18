package usecase

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/domain"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/port"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/admission"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/debuglog"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	pkgjwt "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/jwt"
	pkgvalidator "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/validator"
	"golang.org/x/crypto/bcrypt"
)

const bcryptMaxPasswordBytes = 72
const (
	maxNameCharacters     = 120
	minPasswordCharacters = 8
)

type AuthUsecase struct {
	repo       port.UserRepository
	jwtSecret  string
	jwtExpiry  time.Duration
	bcryptCost int
	limiter    *admission.Limiter
}

func NewAuthUsecase(repo port.UserRepository, jwtSecret string, jwtExpiry time.Duration, bcryptCost int, limiter *admission.Limiter) *AuthUsecase {
	return &AuthUsecase{
		repo:       repo,
		jwtSecret:  jwtSecret,
		jwtExpiry:  jwtExpiry,
		bcryptCost: bcryptCost,
		limiter:    limiter,
	}
}

func (u *AuthUsecase) Register(ctx context.Context, name, email, password string) (*domain.User, error) {
	name = strings.TrimSpace(name)
	email = normalizeEmail(email)

	if err := validateRegisterInput(name, email, password); err != nil {
		return nil, err
	}
	hashedPassword, err := pkgerrors.CallIfActive(ctx, func() ([]byte, error) {
		return bcrypt.GenerateFromPassword([]byte(password), u.bcryptCost)
	})
	if err != nil {
		if pkgerrors.IsContext(err) {
			return nil, err
		}
		return nil, pkgerrors.Internal("internal server error", fmt.Errorf("hash password: %w", err))
	}

	user, err := pkgerrors.CallIfActive(ctx, func() (*domain.User, error) {
		return u.repo.Insert(ctx, name, email, string(hashedPassword))
	})
	if err != nil {
		return nil, err
	}
	clearPasswordHash(user)
	return user, nil
}

func (u *AuthUsecase) Login(ctx context.Context, email, password string) (token string, user *domain.User, err error) {
	// Reuse one timer across the full login path so every debug failure in this
	// usecase can be compared against the same end-to-end application duration.
	startedAt := time.Now()
	email = normalizeEmail(email)

	if err := validateLoginInput(email, password); err != nil {
		return "", nil, err
	}

	err = u.limiter.Do(ctx, func() error {
		var dbErr error
		user, dbErr = pkgerrors.CallIfActive(ctx, func() (*domain.User, error) {
			return u.repo.FindByEmail(ctx, email)
		})
		if dbErr != nil {
			return dbErr
		}

		return pkgerrors.DoIfActive(ctx, func() error {
			return bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password))
		})
	})
	if err != nil {
		if errors.Is(err, pkgerrors.ErrNotFound) || errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
			return "", nil, pkgerrors.InvalidCredentials("invalid email or password")
		}
		if admission.IsRejected(err) {
			debuglog.ErrorWithDuration(context.Background(), slog.LevelWarn, "auth-service login failed", "auth_login_usecase_failure", startedAt, err, "category", "resource_exhausted")
			return "", nil, pkgerrors.ResourceExhausted("auth service is temporarily overloaded")
		}
		if pkgerrors.IsContext(err) {
			debuglog.ErrorWithDuration(context.Background(), slog.LevelWarn, "auth-service login failed", "auth_login_usecase_failure", startedAt, err, "category", "context")
			if ctxErr := pkgerrors.FromContext(err, "request timeout", "request canceled"); ctxErr != nil {
				return "", nil, ctxErr
			}
			return "", nil, err
		}
		debuglog.ErrorWithDuration(context.Background(), slog.LevelError, "auth-service login failed", "auth_login_usecase_failure", startedAt, err, "category", "compare_password_internal")
		return "", nil, pkgerrors.Internal("internal server error", fmt.Errorf("login failed: %w", err))
	}

	token, err = pkgerrors.CallIfActive(ctx, func() (string, error) {
		return pkgjwt.Sign(user.ID, user.Email, u.jwtSecret, u.jwtExpiry)
	})
	if err != nil {
		if pkgerrors.IsContext(err) {
			debuglog.ErrorWithDuration(context.Background(), slog.LevelWarn, "auth-service login failed", "auth_login_usecase_failure", startedAt, err, "category", "jwt_context")
			return "", nil, err
		}
		debuglog.ErrorWithDuration(context.Background(), slog.LevelError, "auth-service login failed", "auth_login_usecase_failure", startedAt, err, "category", "jwt_internal")
		return "", nil, pkgerrors.Internal("internal server error", fmt.Errorf("sign jwt: %w", err))
	}

	clearPasswordHash(user)
	return token, user, nil
}

func (u *AuthUsecase) GetUserByID(ctx context.Context, id string) (*domain.User, error) {
	if err := pkgvalidator.ValidateUUIDField(id, "user_id"); err != nil {
		return nil, err
	}
	user, err := pkgerrors.CallIfActive(ctx, func() (*domain.User, error) {
		return u.repo.FindByID(ctx, id)
	})
	if err != nil {
		return nil, err
	}

	clearPasswordHash(user)
	return user, nil
}

func (u *AuthUsecase) GetUsersByIDs(ctx context.Context, ids []string) ([]*domain.User, error) {
	for _, id := range ids {
		if err := pkgvalidator.ValidateUUIDField(id, "user_ids"); err != nil {
			return nil, err
		}
	}
	users, err := pkgerrors.CallIfActive(ctx, func() ([]*domain.User, error) {
		return u.repo.FindByIDs(ctx, ids)
	})
	if err != nil {
		return nil, err
	}

	for _, user := range users {
		clearPasswordHash(user)
	}
	return users, nil
}

func clearPasswordHash(user *domain.User) {
	if user == nil {
		return
	}
	user.PasswordHash = ""
}

func normalizeEmail(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}

func validateRegisterInput(name, email, password string) error {
	if name == "" {
		return invalidInputDetail("name", "is required")
	}
	if utf8.RuneCountInString(name) > maxNameCharacters {
		return invalidInputDetail("name", "must be at most 120 characters")
	}
	return validateSharedAuthInput(email, password)
}

func validateLoginInput(email, password string) error {
	return validateSharedAuthInput(email, password)
}

func validateSharedAuthInput(email, password string) error {
	if email == "" {
		return invalidInputDetail("email", "is required")
	}
	if strings.TrimSpace(password) == "" {
		return invalidInputDetail("password", "is required")
	}
	if utf8.RuneCountInString(password) < minPasswordCharacters {
		return invalidInputDetail("password", "must be at least 8 characters")
	}
	if !isValidEmail(email) {
		return invalidInputDetail("email", "must be a valid email")
	}
	if len(password) > bcryptMaxPasswordBytes {
		return invalidInputDetail("password", "must be at most 72 bytes for bcrypt compatibility")
	}
	return nil
}

func isValidEmail(email string) bool {
	addr, err := mail.ParseAddress(email)
	return err == nil && addr.Address == email && addr.Name == ""
}

func invalidInputDetail(field, description string) error {
	return pkgerrors.InvalidInputDetails("invalid request payload", map[string]string{
		field: description,
	})
}
