package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/debuglog"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/labstack/echo/v4"
)

type monolithHandlerLogRecord struct {
	level slog.Level
	attrs map[string]any
}

type monolithHandlerCaptureHandler struct {
	mu      sync.Mutex
	records []monolithHandlerLogRecord
}

func (h *monolithHandlerCaptureHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *monolithHandlerCaptureHandler) WithAttrs([]slog.Attr) slog.Handler       { return h }
func (h *monolithHandlerCaptureHandler) WithGroup(string) slog.Handler            { return h }
func (h *monolithHandlerCaptureHandler) Handle(_ context.Context, record slog.Record) error {
	attrs := map[string]any{}
	record.Attrs(func(attr slog.Attr) bool {
		attrs[attr.Key] = attr.Value.Any()
		return true
	})

	h.mu.Lock()
	defer h.mu.Unlock()
	h.records = append(h.records, monolithHandlerLogRecord{level: record.Level, attrs: attrs})
	return nil
}

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

func TestHandlerLoginDiagnosticLogging(t *testing.T) {
	tests := []struct {
		name           string
		service        fakeAuthService
		wantStatusCode int
		wantLevel      slog.Level
	}{
		{
			name:           "service unavailable logs warn",
			service:        fakeAuthService{loginErr: apperror.ServiceUnavailable("request timeout", context.DeadlineExceeded)},
			wantStatusCode: http.StatusServiceUnavailable,
			wantLevel:      slog.LevelWarn,
		},
		{
			name:           "internal logs error",
			service:        fakeAuthService{loginErr: apperror.Internal("internal server error", context.DeadlineExceeded)},
			wantStatusCode: http.StatusInternalServerError,
			wantLevel:      slog.LevelError,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("DIAGNOSTIC_LOGGING_ENABLED", "true")
			debuglog.ResetForTesting()

			handler := &monolithHandlerCaptureHandler{}
			previous := slog.Default()
			slog.SetDefault(slog.New(handler))
			t.Cleanup(func() {
				slog.SetDefault(previous)
				debuglog.ResetForTesting()
			})

			rec := executeAuthHandler(`{"email":"mufied@example.com","password":"secret123"}`, NewHandler(tt.service).Login)
			if rec.Code != tt.wantStatusCode {
				t.Fatalf("status = %d, want %d", rec.Code, tt.wantStatusCode)
			}

			if len(handler.records) != 1 {
				t.Fatalf("record count = %d, want 1", len(handler.records))
			}

			record := handler.records[0]
			if record.level != tt.wantLevel {
				t.Fatalf("level = %v, want %v", record.level, tt.wantLevel)
			}
			if record.attrs["event"] != "monolith_auth_login_http_failure" {
				t.Fatalf("event = %v, want monolith_auth_login_http_failure", record.attrs["event"])
			}
			if record.attrs["http_status"] != int64(tt.wantStatusCode) && record.attrs["http_status"] != tt.wantStatusCode {
				t.Fatalf("http_status = %v, want %d", record.attrs["http_status"], tt.wantStatusCode)
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
	if err := handler(c); err != nil {
		e.HTTPErrorHandler(err, c)
	}
	return rec
}
