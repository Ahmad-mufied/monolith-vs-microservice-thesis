package auth

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
)

type fakeRepo struct {
	createUser        User
	createErr         error
	findUser          User
	findErr           error
	createdPassword   string
	findEmailReceived string
}

func (f *fakeRepo) CreateUser(_ context.Context, name, email, passwordHash string) (User, error) {
	f.createdPassword = passwordHash
	if f.createErr != nil {
		return User{}, f.createErr
	}
	f.createUser.Name = name
	f.createUser.Email = email
	return f.createUser, nil
}

func (f *fakeRepo) FindUserByEmail(_ context.Context, email string) (User, error) {
	f.findEmailReceived = email
	if f.findErr != nil {
		return User{}, f.findErr
	}
	return f.findUser, nil
}

type fakeHasher struct {
	hash            string
	hashErr         error
	compareErr      error
	compareHash     *string
	comparePassword *string
}

func (f fakeHasher) Hash(string) (string, error) {
	if f.hashErr != nil {
		return "", f.hashErr
	}
	return f.hash, nil
}

func (f fakeHasher) Compare(hash, password string) error {
	if f.compareHash != nil {
		*f.compareHash = hash
	}
	if f.comparePassword != nil {
		*f.comparePassword = password
	}
	return f.compareErr
}

type fakeSigner struct {
	token        string
	err          error
	signedUserID *string
}

func (f fakeSigner) Sign(userID string) (string, error) {
	if f.signedUserID != nil {
		*f.signedUserID = userID
	}
	if f.err != nil {
		return "", f.err
	}
	return f.token, nil
}

func TestServiceRegister(t *testing.T) {
	now := time.Date(2026, 5, 5, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name      string
		req       RegisterRequest
		repo      *fakeRepo
		hasher    fakeHasher
		wantError bool
		wantCode  apperror.Code
	}{
		{
			name:   "success",
			req:    RegisterRequest{Name: " Ahmad ", Email: "MUFIED@example.com", Password: "secret123"},
			repo:   &fakeRepo{createUser: User{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001", CreatedAt: now, UpdatedAt: now}},
			hasher: fakeHasher{hash: "hashed"},
		},
		{name: "missing name", req: RegisterRequest{Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "name too long", req: RegisterRequest{Name: strings.Repeat("a", 121), Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "invalid email", req: RegisterRequest{Name: "Ahmad", Email: "bad", Password: "secret123"}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "display name email rejected", req: RegisterRequest{Name: "Ahmad", Email: "Ahmad <mufied@example.com>", Password: "secret123"}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "short password", req: RegisterRequest{Name: "Ahmad", Email: "mufied@example.com", Password: "short"}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "password too long", req: RegisterRequest{Name: "Ahmad", Email: "mufied@example.com", Password: strings.Repeat("a", 73)}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "password too short by character count", req: RegisterRequest{Name: "Ahmad", Email: "mufied@example.com", Password: strings.Repeat("あ", 4)}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "password exceeds bcrypt byte limit", req: RegisterRequest{Name: "Ahmad", Email: "mufied@example.com", Password: strings.Repeat("あ", 40)}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "duplicate email", req: RegisterRequest{Name: "Ahmad", Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{createErr: apperror.Conflict("email already exists")}, hasher: fakeHasher{hash: "hashed"}, wantError: true, wantCode: apperror.CodeConflict},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			service := NewService(tt.repo, tt.hasher, fakeSigner{})
			got, err := service.Register(context.Background(), tt.req)
			assertAppError(t, err, tt.wantError, tt.wantCode)
			if tt.wantError {
				return
			}
			if got.Message != "User registered successfully" ||
				got.Data.User.Email != "mufied@example.com" ||
				tt.repo.createdPassword != "hashed" {
				t.Fatalf("response = %+v createdPassword=%q", got, tt.repo.createdPassword)
			}
		})
	}
}

func TestServiceLogin(t *testing.T) {
	now := time.Date(2026, 5, 5, 12, 0, 0, 0, time.UTC)
	user := User{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001", Name: "Ahmad", Email: "mufied@example.com", PasswordHash: "hashed", CreatedAt: now, UpdatedAt: now}
	tests := []struct {
		name      string
		req       LoginRequest
		repo      *fakeRepo
		hasher    fakeHasher
		signer    fakeSigner
		wantError bool
		wantCode  apperror.Code
	}{
		{name: "success", req: LoginRequest{Email: "MUFIED@example.com", Password: "secret123"}, repo: &fakeRepo{findUser: user}, hasher: fakeHasher{}, signer: fakeSigner{token: "token"}},
		{name: "invalid email", req: LoginRequest{Email: "bad", Password: "secret123"}, repo: &fakeRepo{}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "display name email rejected", req: LoginRequest{Email: "Ahmad <mufied@example.com>", Password: "secret123"}, repo: &fakeRepo{}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "short password", req: LoginRequest{Email: "mufied@example.com", Password: "short"}, repo: &fakeRepo{}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "password too long", req: LoginRequest{Email: "mufied@example.com", Password: strings.Repeat("a", 73)}, repo: &fakeRepo{}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "password too short by character count", req: LoginRequest{Email: "mufied@example.com", Password: strings.Repeat("あ", 4)}, repo: &fakeRepo{}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "password exceeds bcrypt byte limit", req: LoginRequest{Email: "mufied@example.com", Password: strings.Repeat("あ", 40)}, repo: &fakeRepo{}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "missing user normalized", req: LoginRequest{Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{findErr: apperror.NotFound("user not found")}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeUnauthorized},
		{name: "repo internal error", req: LoginRequest{Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{findErr: apperror.Internal("internal server error", errors.New("db timeout"))}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeInternal},
		{name: "repo deadline exceeded", req: LoginRequest{Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{findErr: apperror.DeadlineExceeded("request timeout", context.DeadlineExceeded)}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeGatewayTimeout},
		{name: "repo canceled", req: LoginRequest{Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{findErr: apperror.Canceled("request canceled", context.Canceled)}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeClientCanceled},
		{name: "repo unknown error", req: LoginRequest{Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{findErr: errors.New("driver error")}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeInternal},
		{name: "bad password", req: LoginRequest{Email: "mufied@example.com", Password: "wrongpass"}, repo: &fakeRepo{findUser: user}, hasher: fakeHasher{compareErr: ErrPasswordMismatch}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeUnauthorized},
		{name: "hasher internal error", req: LoginRequest{Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{findUser: user}, hasher: fakeHasher{compareErr: errors.New("hash parsing failed")}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeInternal},
		{name: "sign error", req: LoginRequest{Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{findUser: user}, hasher: fakeHasher{}, signer: fakeSigner{err: errors.New("sign failed")}, wantError: true, wantCode: apperror.CodeInternal},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var comparedHash, comparedPassword, signedUserID string
			tt.hasher.compareHash = &comparedHash
			tt.hasher.comparePassword = &comparedPassword
			tt.signer.signedUserID = &signedUserID

			service := NewService(tt.repo, tt.hasher, tt.signer)
			got, err := service.Login(context.Background(), tt.req)
			assertAppError(t, err, tt.wantError, tt.wantCode)
			if tt.wantError {
				return
			}
			if got.Message != "Login successful" ||
				got.Data.Token != "token" ||
				got.Data.User.ID != user.ID ||
				tt.repo.findEmailReceived != "mufied@example.com" ||
				comparedHash != user.PasswordHash ||
				comparedPassword != tt.req.Password ||
				signedUserID != user.ID {
				t.Fatalf(
					"login response = %+v findEmail=%q compareHash=%q comparePassword=%q signedUserID=%q",
					got,
					tt.repo.findEmailReceived,
					comparedHash,
					comparedPassword,
					signedUserID,
				)
			}
		})
	}
}

func TestServiceRegisterValidationDetails(t *testing.T) {
	service := NewService(&fakeRepo{}, fakeHasher{}, fakeSigner{})

	_, err := service.Register(context.Background(), RegisterRequest{
		Name:     "Ahmad",
		Email:    "Ahmad <mufied@example.com>",
		Password: "secret123",
	})
	assertValidationDetail(t, err, "email", "must be a valid email")

	_, err = service.Register(context.Background(), RegisterRequest{
		Name:     "Ahmad",
		Email:    "mufied@example.com",
		Password: strings.Repeat("あ", 40),
	})
	assertValidationDetail(t, err, "password", "must be at most 72 bytes for bcrypt compatibility")
}

func TestServiceLoginValidationDetails(t *testing.T) {
	service := NewService(&fakeRepo{}, fakeHasher{}, fakeSigner{})

	_, err := service.Login(context.Background(), LoginRequest{
		Email:    "Ahmad <mufied@example.com>",
		Password: "secret123",
	})
	assertValidationDetail(t, err, "email", "must be a valid email")

	_, err = service.Login(context.Background(), LoginRequest{
		Email:    "mufied@example.com",
		Password: strings.Repeat("あ", 40),
	})
	assertValidationDetail(t, err, "password", "must be at most 72 bytes for bcrypt compatibility")
}

func TestNewServiceDependencyValidation(t *testing.T) {
	t.Run("success", func(t *testing.T) {
		_ = NewService(&fakeRepo{}, fakeHasher{}, fakeSigner{})
	})

	tests := []struct {
		name string
		run  func()
	}{
		{
			name: "nil repo",
			run: func() {
				var repo *fakeRepo
				_ = NewService(repo, fakeHasher{}, fakeSigner{})
			},
		},
		{
			name: "nil hasher",
			run: func() {
				var hasher *fakeHasher
				_ = NewService(&fakeRepo{}, hasher, fakeSigner{})
			},
		},
		{
			name: "nil signer",
			run: func() {
				var signer *fakeSigner
				_ = NewService(&fakeRepo{}, fakeHasher{}, signer)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			defer func() {
				if recover() == nil {
					t.Fatal("expected panic, got nil")
				}
			}()
			tt.run()
		})
	}
}

func assertValidationDetail(t *testing.T, err error, wantField, wantMessage string) {
	t.Helper()
	var appErr *apperror.Error
	if !errors.As(err, &appErr) {
		t.Fatalf("error type = %T, want *apperror.Error", err)
	}

	gotMessage, ok := appErr.Details[wantField]
	if !ok {
		t.Fatalf("details = %#v, want field %q", appErr.Details, wantField)
	}
	if gotMessage != wantMessage {
		t.Fatalf("details[%q] = %v, want %q", wantField, gotMessage, wantMessage)
	}
}

func assertAppError(t *testing.T, err error, wantError bool, wantCode apperror.Code) {
	t.Helper()
	if wantError {
		if err == nil {
			t.Fatal("expected error, got nil")
		}
		var appErr *apperror.Error
		if !errors.As(err, &appErr) {
			t.Fatalf("error type = %T, want *apperror.Error", err)
		}
		if appErr.Code != wantCode {
			t.Fatalf("error code = %s, want %s", appErr.Code, wantCode)
		}
		return
	}
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}
