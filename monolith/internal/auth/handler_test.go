package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/labstack/echo/v4"
)

type fakeAuthService struct {
	registerResp RegisterResponse
	registerErr  error
	loginResp    LoginResponse
	loginErr     error
}

func (f fakeAuthService) Register(context.Context, RegisterRequest) (RegisterResponse, error) {
	return f.registerResp, f.registerErr
}

func (f fakeAuthService) Login(context.Context, LoginRequest) (LoginResponse, error) {
	return f.loginResp, f.loginErr
}

func TestHandlerRegister(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		service    fakeAuthService
		wantStatus int
	}{
		{
			name:       "success",
			body:       `{"name":"Ahmad","email":"mufied@example.com","password":"secret123"}`,
			service:    fakeAuthService{registerResp: RegisterResponse{Message: "User registered successfully", Data: RegisterResponseData{User: UserSummary{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001", Name: "Ahmad", Email: "mufied@example.com"}}}},
			wantStatus: http.StatusCreated,
		},
		{name: "invalid json", body: `{`, service: fakeAuthService{}, wantStatus: http.StatusBadRequest},
		{name: "service error", body: `{}`, service: fakeAuthService{registerErr: apperror.Conflict("email already exists")}, wantStatus: http.StatusConflict},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := executeAuthHandler(tt.body, NewHandler(tt.service).Register)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantStatus == http.StatusCreated {
				var got RegisterResponse
				if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
					t.Fatalf("unmarshal response: %v", err)
				}
				if got.Message != "User registered successfully" {
					t.Fatalf("message = %q", got.Message)
				}
				if bytes.Contains(rec.Body.Bytes(), []byte("password")) {
					t.Fatalf("response exposes password fields: %s", rec.Body.String())
				}
			}
		})
	}
}

func TestHandlerLogin(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		service    fakeAuthService
		wantStatus int
	}{
		{
			name:       "success",
			body:       `{"email":"mufied@example.com","password":"secret123"}`,
			service:    fakeAuthService{loginResp: LoginResponse{Message: "Login successful", Data: LoginResponseData{Token: "token", User: UserSummary{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001", Name: "Ahmad", Email: "mufied@example.com"}}}},
			wantStatus: http.StatusOK,
		},
		{name: "invalid json", body: `{`, service: fakeAuthService{}, wantStatus: http.StatusBadRequest},
		{name: "unauthorized", body: `{}`, service: fakeAuthService{loginErr: apperror.Unauthorized("invalid email or password")}, wantStatus: http.StatusUnauthorized},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := executeAuthHandler(tt.body, NewHandler(tt.service).Login)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantStatus == http.StatusOK {
				var got LoginResponse
				if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
					t.Fatalf("unmarshal response: %v", err)
				}
				if got.Message != "Login successful" || got.Data.Token != "token" {
					t.Fatalf("response = %+v", got)
				}
			}
		})
	}
}

func executeAuthHandler(body string, handler echo.HandlerFunc) *httptest.ResponseRecorder {
	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth", bytes.NewBufferString(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	_ = handler(c)
	return rec
}
