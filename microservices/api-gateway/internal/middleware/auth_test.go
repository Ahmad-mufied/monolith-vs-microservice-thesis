package middleware

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	pkgjwt "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/jwt"
	"github.com/labstack/echo/v4"
)

const (
	testSecret = "test-secret-key"
	testUserID = "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"
)

func signToken(t *testing.T, userID string) string {
	t.Helper()
	tok, err := pkgjwt.Sign(userID, "user@example.com", testSecret, time.Hour)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return tok
}

func TestUserIDFromBearer(t *testing.T) {
	tests := []struct {
		name       string
		buildHdr   func(t *testing.T) string
		wantUserID string
		wantStatus int
	}{
		{
			name:       "valid bearer token",
			buildHdr:   func(t *testing.T) string { return "Bearer " + signToken(t, testUserID) },
			wantUserID: testUserID,
		},
		{
			name:       "missing header",
			buildHdr:   func(t *testing.T) string { return "" },
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "wrong scheme",
			buildHdr:   func(t *testing.T) string { return "Token abc" },
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "only scheme no token",
			buildHdr:   func(t *testing.T) string { return "Bearer" },
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "invalid token",
			buildHdr:   func(t *testing.T) string { return "Bearer invalid.token.here" },
			wantStatus: http.StatusUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			userID, err := UserIDFromBearer(tt.buildHdr(t), testSecret)

			if tt.wantStatus != 0 {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				var ae *httputil.AppError
				ok := errors.As(err, &ae)
				if !ok {
					t.Fatalf("error type = %T, want *httputil.AppError", err)
				}
				if ae.Status != tt.wantStatus {
					t.Errorf("status = %d, want %d", ae.Status, tt.wantStatus)
				}
				if ae.Code != "UNAUTHORIZED" {
					t.Errorf("code = %q, want UNAUTHORIZED", ae.Code)
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if userID != tt.wantUserID {
				t.Errorf("userID = %q, want %q", userID, tt.wantUserID)
			}
		})
	}
}

func TestUserIDFromContext(t *testing.T) {
	tests := []struct {
		name       string
		setup      func(c echo.Context)
		wantUserID string
		wantStatus int
	}{
		{
			name: "user_id set in context",
			setup: func(c echo.Context) {
				c.Set(userIDKey, testUserID)
			},
			wantUserID: testUserID,
		},
		{
			name:       "user_id not set",
			setup:      func(c echo.Context) {},
			wantStatus: http.StatusUnauthorized,
		},
		{
			name: "user_id empty string",
			setup: func(c echo.Context) {
				c.Set(userIDKey, "")
			},
			wantStatus: http.StatusUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := echo.New()
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			c := e.NewContext(req, httptest.NewRecorder())
			tt.setup(c)

			userID, err := UserIDFromContext(c)

			if tt.wantStatus != 0 {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				var ae *httputil.AppError
				ok := errors.As(err, &ae)
				if !ok {
					t.Fatalf("error type = %T, want *httputil.AppError", err)
				}
				if ae.Status != tt.wantStatus {
					t.Errorf("status = %d, want %d", ae.Status, tt.wantStatus)
				}
				if ae.Code != "UNAUTHORIZED" {
					t.Errorf("code = %q, want UNAUTHORIZED", ae.Code)
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if userID != tt.wantUserID {
				t.Errorf("userID = %q, want %q", userID, tt.wantUserID)
			}
		})
	}
}
