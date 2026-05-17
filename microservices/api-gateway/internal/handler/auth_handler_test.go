package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/labstack/echo/v4"
)

// --- helpers ---

func newEchoCtx(method, target, body string) (echo.Context, *httptest.ResponseRecorder) {
	e := echo.New()
	var req *http.Request
	if body != "" {
		req = httptest.NewRequest(method, target, bytes.NewBufferString(body))
		req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	} else {
		req = httptest.NewRequest(method, target, nil)
	}
	rec := httptest.NewRecorder()
	return e.NewContext(req, rec), rec
}

func runHandler(h echo.HandlerFunc, c echo.Context) *httptest.ResponseRecorder {
	rec := c.Response().Writer.(*httptest.ResponseRecorder)
	if err := h(c); err != nil {
		httputil.HTTPErrorHandler(err, c)
	}
	return rec
}

// --- fakes ---

type fakeAuthClient struct {
	registerFn    func(ctx context.Context, name, email, password string) (*dto.UserSummary, error)
	loginFn       func(ctx context.Context, email, password string) (string, *dto.UserSummary, error)
	getUsersByIDs func(ctx context.Context, ids []string) ([]*dto.UserSummary, error)
}

func (f *fakeAuthClient) Register(ctx context.Context, name, email, password string) (*dto.UserSummary, error) {
	return f.registerFn(ctx, name, email, password)
}
func (f *fakeAuthClient) Login(ctx context.Context, email, password string) (string, *dto.UserSummary, error) {
	return f.loginFn(ctx, email, password)
}
func (f *fakeAuthClient) GetUsersByIDs(ctx context.Context, ids []string) ([]*dto.UserSummary, error) {
	return f.getUsersByIDs(ctx, ids)
}

// --- TestHealthHandler ---

func TestHealthHandler_Handle(t *testing.T) {
	tests := []struct {
		name       string
		wantStatus int
		wantMsg    string
		wantSvc    string
	}{
		{
			name:       "returns 200 with service name",
			wantStatus: http.StatusOK,
			wantMsg:    "ok",
			wantSvc:    "api-gateway",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, rec := newEchoCtx(http.MethodGet, "/healthz", "")
			h := NewHealthHandler()
			runHandler(h.Handle, c)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tt.wantStatus)
			}
			var body map[string]any
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if body["message"] != tt.wantMsg {
				t.Errorf("message = %q, want %q", body["message"], tt.wantMsg)
			}
			if body["service"] != tt.wantSvc {
				t.Errorf("service = %q, want %q", body["service"], tt.wantSvc)
			}
		})
	}
}

// --- TestAuthHandler_Register ---

func TestAuthHandler_Register(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		clientFn   func(ctx context.Context, name, email, password string) (*dto.UserSummary, error)
		wantStatus int
		wantMsg    string
	}{
		{
			name: "success returns 201 with user summary",
			body: `{"name":"Ahmad","email":"a@b.com","password":"pass1234"}`,
			clientFn: func(_ context.Context, name, email, _ string) (*dto.UserSummary, error) {
				return &dto.UserSummary{ID: "uid-1", Name: name, Email: email}, nil
			},
			wantStatus: http.StatusCreated,
			wantMsg:    "User registered successfully",
		},
		{
			name:       "invalid json returns 400",
			body:       `{`,
			clientFn:   nil,
			wantStatus: http.StatusBadRequest,
		},
		{
			name: "conflict returns 409",
			body: `{"name":"Ahmad","email":"a@b.com","password":"pass1234"}`,
			clientFn: func(_ context.Context, _, _, _ string) (*dto.UserSummary, error) {
				return nil, &httputil.AppError{Status: http.StatusConflict, Code: "CONFLICT", Message: "email taken"}
			},
			wantStatus: http.StatusConflict,
		},
		{
			name: "internal error returns 500",
			body: `{"name":"Ahmad","email":"a@b.com","password":"pass1234"}`,
			clientFn: func(_ context.Context, _, _, _ string) (*dto.UserSummary, error) {
				return nil, &httputil.AppError{Status: http.StatusInternalServerError, Code: "INTERNAL_SERVER_ERROR", Message: "internal"}
			},
			wantStatus: http.StatusInternalServerError,
		},
		{
			name: "nil user with no error returns 500",
			body: `{"name":"Ahmad","email":"a@b.com","password":"pass1234"}`,
			clientFn: func(_ context.Context, _, _, _ string) (*dto.UserSummary, error) {
				return nil, nil
			},
			wantStatus: http.StatusInternalServerError,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeAuthClient{}
			if tt.clientFn != nil {
				fake.registerFn = tt.clientFn
			}
			h := NewAuthHandler(fake)
			c, rec := newEchoCtx(http.MethodPost, "/api/v1/auth/register", tt.body)
			runHandler(h.Register, c)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantMsg != "" {
				var body map[string]any
				if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
					t.Fatalf("unmarshal: %v", err)
				}
				if body["message"] != tt.wantMsg {
					t.Errorf("message = %q, want %q", body["message"], tt.wantMsg)
				}
			}
		})
	}
}

func TestAuthHandler_Register_UnsupportedMediaType(t *testing.T) {
	fake := &fakeAuthClient{}
	h := NewAuthHandler(fake)

	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/register", bytes.NewBufferString(`{"name":"Ahmad"}`))
	req.Header.Set(echo.HeaderContentType, echo.MIMETextPlain)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	runHandler(h.Register, c)

	if rec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, want %d; body=%s", rec.Code, http.StatusUnsupportedMediaType, rec.Body.String())
	}

	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	errBody, _ := body["error"].(map[string]any)
	if errBody["code"] != "UNSUPPORTED_MEDIA_TYPE" {
		t.Fatalf("error.code = %v, want %q", errBody["code"], "UNSUPPORTED_MEDIA_TYPE")
	}
}

// --- TestAuthHandler_Login ---

func TestAuthHandler_Login(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		clientFn   func(ctx context.Context, email, password string) (string, *dto.UserSummary, error)
		wantStatus int
		wantToken  string
	}{
		{
			name: "success returns 200 with token and user",
			body: `{"email":"a@b.com","password":"pass1234"}`,
			clientFn: func(_ context.Context, _, _ string) (string, *dto.UserSummary, error) {
				return "tok123", &dto.UserSummary{ID: "uid-1", Name: "Ahmad", Email: "a@b.com"}, nil
			},
			wantStatus: http.StatusOK,
			wantToken:  "tok123",
		},
		{
			name:       "invalid json returns 400",
			body:       `{`,
			wantStatus: http.StatusBadRequest,
		},
		{
			name: "unauthorized returns 401",
			body: `{"email":"a@b.com","password":"wrong"}`,
			clientFn: func(_ context.Context, _, _ string) (string, *dto.UserSummary, error) {
				return "", nil, &httputil.AppError{Status: http.StatusUnauthorized, Code: "UNAUTHORIZED", Message: "invalid credentials"}
			},
			wantStatus: http.StatusUnauthorized,
		},
		{
			name: "internal error returns 500",
			body: `{"email":"a@b.com","password":"pass1234"}`,
			clientFn: func(_ context.Context, _, _ string) (string, *dto.UserSummary, error) {
				return "", nil, &httputil.AppError{Status: http.StatusInternalServerError, Code: "INTERNAL_SERVER_ERROR", Message: "internal"}
			},
			wantStatus: http.StatusInternalServerError,
		},
		{
			name: "nil user with no error returns 500",
			body: `{"email":"a@b.com","password":"pass1234"}`,
			clientFn: func(_ context.Context, _, _ string) (string, *dto.UserSummary, error) {
				return "tok", nil, nil
			},
			wantStatus: http.StatusInternalServerError,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeAuthClient{}
			if tt.clientFn != nil {
				fake.loginFn = tt.clientFn
			}
			h := NewAuthHandler(fake)
			c, rec := newEchoCtx(http.MethodPost, "/api/v1/auth/login", tt.body)
			runHandler(h.Login, c)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantToken != "" {
				var body map[string]any
				if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
					t.Fatalf("unmarshal: %v", err)
				}
				data, _ := body["data"].(map[string]any)
				if data["token"] != tt.wantToken {
					t.Errorf("token = %q, want %q", data["token"], tt.wantToken)
				}
			}
		})
	}
}
