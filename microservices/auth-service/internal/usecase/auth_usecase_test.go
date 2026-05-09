package usecase

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/domain"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	"golang.org/x/crypto/bcrypt"
)

type fakeUserRepo struct {
	insertFn      func(ctx context.Context, name, email, passwordHash string) (*domain.User, error)
	findByEmailFn func(ctx context.Context, email string) (*domain.User, error)
	findByIDFn    func(ctx context.Context, id string) (*domain.User, error)
	findByIDsFn   func(ctx context.Context, ids []string) ([]*domain.User, error)
}

func (f *fakeUserRepo) Insert(ctx context.Context, name, email, passwordHash string) (*domain.User, error) {
	return f.insertFn(ctx, name, email, passwordHash)
}

func (f *fakeUserRepo) FindByEmail(ctx context.Context, email string) (*domain.User, error) {
	return f.findByEmailFn(ctx, email)
}

func (f *fakeUserRepo) FindByID(ctx context.Context, id string) (*domain.User, error) {
	return f.findByIDFn(ctx, id)
}

func (f *fakeUserRepo) FindByIDs(ctx context.Context, ids []string) ([]*domain.User, error) {
	return f.findByIDsFn(ctx, ids)
}

func TestRegisterSuccess(t *testing.T) {
	repo := &fakeUserRepo{
		insertFn: func(ctx context.Context, name, email, passwordHash string) (*domain.User, error) {
			if passwordHash == "" {
				t.Fatalf("expected hashed password")
			}
			return &domain.User{
				ID:           "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
				Name:         name,
				Email:        email,
				PasswordHash: passwordHash,
			}, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	user, err := uc.Register(context.Background(), "Ahmad", "ahmad@example.com", "Secret123!")
	if err != nil {
		t.Fatalf("Register() error = %v", err)
	}
	if user.PasswordHash != "" {
		t.Fatalf("expected password hash to be cleared")
	}
}

func TestRegisterTrimsNameAndNormalizesEmail(t *testing.T) {
	repo := &fakeUserRepo{
		insertFn: func(ctx context.Context, name, email, passwordHash string) (*domain.User, error) {
			if name != "Ahmad" {
				t.Fatalf("expected trimmed name, got %q", name)
			}
			if email != "ahmad@example.com" {
				t.Fatalf("expected normalized email, got %q", email)
			}
			return &domain.User{
				ID:           "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
				Name:         name,
				Email:        email,
				PasswordHash: passwordHash,
			}, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, err := uc.Register(context.Background(), "  Ahmad  ", "  Ahmad@Example.COM  ", "Secret123!")
	if err != nil {
		t.Fatalf("Register() error = %v", err)
	}
}

func TestRegisterEmptyFields(t *testing.T) {
	repo := &fakeUserRepo{
		insertFn: func(ctx context.Context, name, email, passwordHash string) (*domain.User, error) {
			t.Fatalf("insert should not be called")
			return nil, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, err := uc.Register(context.Background(), "", "ahmad@example.com", "Secret123!")
	if !errors.Is(err, pkgerrors.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput, got %v", err)
	}
	assertValidationDetail(t, err, "name", "is required")
}

func TestRegisterInvalidEmail(t *testing.T) {
	repo := &fakeUserRepo{
		insertFn: func(ctx context.Context, name, email, passwordHash string) (*domain.User, error) {
			t.Fatalf("insert should not be called")
			return nil, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, err := uc.Register(context.Background(), "Ahmad", "not-an-email", "Secret123!")
	if !errors.Is(err, pkgerrors.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput, got %v", err)
	}
	assertValidationDetail(t, err, "email", "must be a valid email")
}

func TestRegisterNameTooLong(t *testing.T) {
	repo := &fakeUserRepo{
		insertFn: func(ctx context.Context, name, email, passwordHash string) (*domain.User, error) {
			t.Fatalf("insert should not be called")
			return nil, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, err := uc.Register(context.Background(), strings.Repeat("a", 121), "ahmad@example.com", "Secret123!")
	if !errors.Is(err, pkgerrors.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput, got %v", err)
	}
	assertValidationDetail(t, err, "name", "must be at most 120 characters")
}

func TestRegisterPasswordTooShort(t *testing.T) {
	repo := &fakeUserRepo{
		insertFn: func(ctx context.Context, name, email, passwordHash string) (*domain.User, error) {
			t.Fatalf("insert should not be called")
			return nil, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, err := uc.Register(context.Background(), "Ahmad", "ahmad@example.com", "short")
	if !errors.Is(err, pkgerrors.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput, got %v", err)
	}
	assertValidationDetail(t, err, "password", "must be at least 8 characters")
}

func TestRegisterPasswordTooLong(t *testing.T) {
	repo := &fakeUserRepo{
		insertFn: func(ctx context.Context, name, email, passwordHash string) (*domain.User, error) {
			t.Fatalf("insert should not be called")
			return nil, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, err := uc.Register(context.Background(), "Ahmad", "ahmad@example.com", string(make([]byte, 73)))
	if !errors.Is(err, pkgerrors.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput, got %v", err)
	}
	assertValidationDetail(t, err, "password", "must be at most 72 bytes for bcrypt compatibility")
}

func TestRegisterDuplicateEmail(t *testing.T) {
	repo := &fakeUserRepo{
		insertFn: func(ctx context.Context, name, email, passwordHash string) (*domain.User, error) {
			return nil, pkgerrors.ErrConflict
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, err := uc.Register(context.Background(), "Ahmad", "ahmad@example.com", "Secret123!")
	if !errors.Is(err, pkgerrors.ErrConflict) {
		t.Fatalf("expected ErrConflict, got %v", err)
	}
}

func TestLoginSuccess(t *testing.T) {
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte("Secret123!"), 10)
	if err != nil {
		t.Fatalf("setup hash failed: %v", err)
	}

	repo := &fakeUserRepo{
		findByEmailFn: func(ctx context.Context, email string) (*domain.User, error) {
			if email != "ahmad@example.com" {
				t.Fatalf("expected normalized email, got %q", email)
			}
			return &domain.User{
				ID:           "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
				Name:         "Ahmad",
				Email:        email,
				PasswordHash: string(hashedPassword),
			}, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	token, user, err := uc.Login(context.Background(), "  Ahmad@Example.COM  ", "Secret123!")
	if err != nil {
		t.Fatalf("Login() error = %v", err)
	}
	if token == "" {
		t.Fatalf("expected token")
	}
	if user == nil {
		t.Fatalf("expected user")
	}
}

func TestLoginUserNotFound(t *testing.T) {
	repo := &fakeUserRepo{
		findByEmailFn: func(ctx context.Context, email string) (*domain.User, error) {
			return nil, pkgerrors.ErrNotFound
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, _, err := uc.Login(context.Background(), "ahmad@example.com", "Secret123!")
	if !errors.Is(err, pkgerrors.ErrInvalidCredentials) {
		t.Fatalf("expected ErrInvalidCredentials, got %v", err)
	}
}

func TestLoginWrongPassword(t *testing.T) {
	repo := &fakeUserRepo{
		findByEmailFn: func(ctx context.Context, email string) (*domain.User, error) {
			return &domain.User{
				ID:           "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
				Email:        email,
				PasswordHash: "$2a$10$5L6Jnr.jf2Fc2nW2XW3rleGfN1iVw7zQ2x5sQZkW9k9R3qXg4nQx6",
			}, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, _, err := uc.Login(context.Background(), "ahmad@example.com", "wrongpass")
	if !errors.Is(err, pkgerrors.ErrInvalidCredentials) {
		t.Fatalf("expected ErrInvalidCredentials, got %v", err)
	}
}

func TestLoginInvalidEmail(t *testing.T) {
	repo := &fakeUserRepo{
		findByEmailFn: func(ctx context.Context, email string) (*domain.User, error) {
			t.Fatalf("FindByEmail should not be called")
			return nil, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, _, err := uc.Login(context.Background(), "not-an-email", "Secret123!")
	if !errors.Is(err, pkgerrors.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput, got %v", err)
	}
	assertValidationDetail(t, err, "email", "must be a valid email")
}

func TestLoginPasswordTooLong(t *testing.T) {
	repo := &fakeUserRepo{
		findByEmailFn: func(ctx context.Context, email string) (*domain.User, error) {
			t.Fatalf("FindByEmail should not be called")
			return nil, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, _, err := uc.Login(context.Background(), "ahmad@example.com", string(make([]byte, 73)))
	if !errors.Is(err, pkgerrors.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput, got %v", err)
	}
	assertValidationDetail(t, err, "password", "must be at most 72 bytes for bcrypt compatibility")
}

func TestLoginPasswordTooShort(t *testing.T) {
	repo := &fakeUserRepo{
		findByEmailFn: func(ctx context.Context, email string) (*domain.User, error) {
			t.Fatalf("FindByEmail should not be called")
			return nil, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, _, err := uc.Login(context.Background(), "ahmad@example.com", "short")
	if !errors.Is(err, pkgerrors.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput, got %v", err)
	}
	assertValidationDetail(t, err, "password", "must be at least 8 characters")
}

func TestLoginPasswordCompareInternalError(t *testing.T) {
	repo := &fakeUserRepo{
		findByEmailFn: func(ctx context.Context, email string) (*domain.User, error) {
			return &domain.User{
				ID:           "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
				Email:        email,
				PasswordHash: "invalid-hash",
			}, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, _, err := uc.Login(context.Background(), "ahmad@example.com", "Secret123!")
	if !errors.Is(err, pkgerrors.ErrInternal) {
		t.Fatalf("expected ErrInternal, got %v", err)
	}
}

func TestGetUserByIDSuccess(t *testing.T) {
	repo := &fakeUserRepo{
		findByIDFn: func(ctx context.Context, id string) (*domain.User, error) {
			return &domain.User{
				ID:           id,
				Name:         "Ahmad",
				Email:        "ahmad@example.com",
				PasswordHash: "hashed",
			}, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	user, err := uc.GetUserByID(context.Background(), "01968ad4-98b1-79c8-a6f0-ec21f8f434c6")
	if err != nil {
		t.Fatalf("GetUserByID() error = %v", err)
	}
	if user.PasswordHash != "" {
		t.Fatalf("expected password hash to be cleared")
	}
}

func TestGetUserByIDInvalidUUID(t *testing.T) {
	repo := &fakeUserRepo{}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, err := uc.GetUserByID(context.Background(), "invalid-id")
	if !errors.Is(err, pkgerrors.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput, got %v", err)
	}
	assertValidationDetail(t, err, "user_id", "must be a valid UUID")
}

func TestGetUserByIDNotFound(t *testing.T) {
	repo := &fakeUserRepo{
		findByIDFn: func(ctx context.Context, id string) (*domain.User, error) {
			return nil, pkgerrors.ErrNotFound
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, err := uc.GetUserByID(context.Background(), "01968ad4-98b1-79c8-a6f0-ec21f8f434c6")
	if !errors.Is(err, pkgerrors.ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestGetUsersByIDsSuccess(t *testing.T) {
	repo := &fakeUserRepo{
		findByIDsFn: func(ctx context.Context, ids []string) ([]*domain.User, error) {
			return []*domain.User{
				{
					ID:           ids[0],
					Name:         "Ahmad",
					Email:        "ahmad@example.com",
					PasswordHash: "hashed",
				},
			}, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	users, err := uc.GetUsersByIDs(context.Background(), []string{"01968ad4-98b1-79c8-a6f0-ec21f8f434c6"})
	if err != nil {
		t.Fatalf("GetUsersByIDs() error = %v", err)
	}
	if len(users) != 1 {
		t.Fatalf("expected 1 user, got %d", len(users))
	}
	if users[0].PasswordHash != "" {
		t.Fatalf("expected password hash to be cleared")
	}
}

func TestGetUsersByIDsInvalidUUID(t *testing.T) {
	repo := &fakeUserRepo{
		findByIDsFn: func(ctx context.Context, ids []string) ([]*domain.User, error) {
			t.Fatalf("FindByIDs should not be called")
			return nil, nil
		},
	}
	uc := NewAuthUsecase(repo, "secret", 24*time.Hour, 10)

	_, err := uc.GetUsersByIDs(context.Background(), []string{"invalid-id"})
	if !errors.Is(err, pkgerrors.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput, got %v", err)
	}
	assertValidationDetail(t, err, "user_ids", "must be a valid UUID")
}

func assertValidationDetail(t *testing.T, err error, wantField, wantMessage string) {
	t.Helper()

	var detailedErr interface{ PublicDetails() map[string]string }
	if !errors.As(err, &detailedErr) {
		t.Fatalf("expected error with validation details, got %v", err)
	}

	details := detailedErr.PublicDetails()
	if len(details) == 0 {
		t.Fatalf("expected validation details, got none")
	}

	if gotMessage, ok := details[wantField]; !ok {
		t.Fatalf("details = %#v, want field %q", details, wantField)
	} else if gotMessage != wantMessage {
		t.Fatalf("details[%q] = %q, want %q", wantField, gotMessage, wantMessage)
	}
}
