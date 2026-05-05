package auth

import (
	"context"
	"errors"
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
	hash       string
	hashErr    error
	compareErr error
}

func (f fakeHasher) Hash(string) (string, error) {
	if f.hashErr != nil {
		return "", f.hashErr
	}
	return f.hash, nil
}

func (f fakeHasher) Compare(string, string) error {
	return f.compareErr
}

type fakeSigner struct {
	token string
	err   error
}

func (f fakeSigner) Sign(string) (string, error) {
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
		{name: "invalid email", req: RegisterRequest{Name: "Ahmad", Email: "bad", Password: "secret123"}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "display name email rejected", req: RegisterRequest{Name: "Ahmad", Email: "Ahmad <mufied@example.com>", Password: "secret123"}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "short password", req: RegisterRequest{Name: "Ahmad", Email: "mufied@example.com", Password: "short"}, repo: &fakeRepo{}, hasher: fakeHasher{}, wantError: true, wantCode: apperror.CodeBadRequest},
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
			if got.Email != "mufied@example.com" || tt.repo.createdPassword != "hashed" {
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
		{name: "missing user", req: LoginRequest{Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{findErr: apperror.Unauthorized("invalid email or password")}, hasher: fakeHasher{}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeUnauthorized},
		{name: "bad password", req: LoginRequest{Email: "mufied@example.com", Password: "wrongpass"}, repo: &fakeRepo{findUser: user}, hasher: fakeHasher{compareErr: errors.New("bad password")}, signer: fakeSigner{}, wantError: true, wantCode: apperror.CodeUnauthorized},
		{name: "sign error", req: LoginRequest{Email: "mufied@example.com", Password: "secret123"}, repo: &fakeRepo{findUser: user}, hasher: fakeHasher{}, signer: fakeSigner{err: errors.New("sign failed")}, wantError: true, wantCode: apperror.CodeInternal},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			service := NewService(tt.repo, tt.hasher, tt.signer)
			got, err := service.Login(context.Background(), tt.req)
			assertAppError(t, err, tt.wantError, tt.wantCode)
			if tt.wantError {
				return
			}
			if got.Token != "token" || got.User.ID != user.ID || tt.repo.findEmailReceived != "mufied@example.com" {
				t.Fatalf("login response = %+v findEmail=%q", got, tt.repo.findEmailReceived)
			}
		})
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
