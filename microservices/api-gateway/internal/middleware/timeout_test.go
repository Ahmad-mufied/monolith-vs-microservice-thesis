package middleware

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/labstack/echo/v4"
	echomw "github.com/labstack/echo/v4/middleware"
)

func TestContextTimeoutErrorHandler(t *testing.T) {
	tests := []struct {
		name       string
		setupCtx   func() echo.Context
		err        error
		wantErr    bool
		wantStatus int
		wantCode   string
	}{
		{
			name: "deadline exceeded returns 503",
			setupCtx: func() echo.Context {
				e := echo.New()
				req := httptest.NewRequest(http.MethodGet, "/", nil)
				rec := httptest.NewRecorder()
				return e.NewContext(req, rec)
			},
			err:        context.DeadlineExceeded,
			wantErr:    true,
			wantStatus: http.StatusServiceUnavailable,
			wantCode:   "SERVICE_UNAVAILABLE",
		},
		{
			name: "client canceled returns 499",
			setupCtx: func() echo.Context {
				e := echo.New()
				canceledCtx, cancel := context.WithCancel(context.Background())
				cancel()
				req := httptest.NewRequest(http.MethodGet, "/", nil).WithContext(canceledCtx)
				rec := httptest.NewRecorder()
				return e.NewContext(req, rec)
			},
			err:        context.Canceled,
			wantErr:    true,
			wantStatus: 499,
			wantCode:   "CLIENT_CANCELED",
		},
		{
			name: "non-context error passes through",
			setupCtx: func() echo.Context {
				e := echo.New()
				req := httptest.NewRequest(http.MethodGet, "/", nil)
				rec := httptest.NewRecorder()
				return e.NewContext(req, rec)
			},
			err:        echo.NewHTTPError(http.StatusBadRequest, "bad request"),
			wantErr:    true,
			wantStatus: http.StatusBadRequest,
			wantCode:   "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := tt.setupCtx()
			err := ContextTimeoutErrorHandler(tt.err, c)

			if !tt.wantErr {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}

			if err == nil {
				t.Fatal("expected error, got nil")
			}

			// For non-context errors, check if it's an echo.HTTPError
			if tt.wantCode == "" {
				httpErr, ok := err.(*echo.HTTPError)
				if !ok {
					t.Fatalf("expected *echo.HTTPError, got %T", err)
				}
				if httpErr.Code != tt.wantStatus {
					t.Errorf("status = %d, want %d", httpErr.Code, tt.wantStatus)
				}
				return
			}

			// For context errors, check AppError
			appErr, ok := err.(*httputil.AppError)
			if !ok {
				t.Fatalf("expected *httputil.AppError, got %T", err)
			}
			if appErr.Code != tt.wantCode {
				t.Errorf("code = %s, want %s", appErr.Code, tt.wantCode)
			}
			if appErr.Status != tt.wantStatus {
				t.Errorf("status = %d, want %d", appErr.Status, tt.wantStatus)
			}
		})
	}
}

func TestContextTimeoutErrorHandler_Integration(t *testing.T) {
	tests := []struct {
		name       string
		timeout    time.Duration
		handlerFn  func(echo.Context) error
		wantStatus int
		wantCode   string
	}{
		{
			name:    "slow handler triggers deadline exceeded",
			timeout: 1 * time.Millisecond,
			handlerFn: func(c echo.Context) error {
				select {
				case <-c.Request().Context().Done():
					return c.Request().Context().Err()
				case <-time.After(200 * time.Millisecond):
					return nil
				}
			},
			wantStatus: http.StatusServiceUnavailable,
			wantCode:   "SERVICE_UNAVAILABLE",
		},
		{
			name:    "fast handler completes within timeout",
			timeout: 5 * time.Second,
			handlerFn: func(c echo.Context) error {
				return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
			},
			wantStatus: http.StatusOK,
			wantCode:   "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := echo.New()
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			rec := httptest.NewRecorder()
			c := e.NewContext(req, rec)

			timeoutMW := echomw.ContextTimeoutWithConfig(echomw.ContextTimeoutConfig{
				Timeout:      tt.timeout,
				ErrorHandler: ContextTimeoutErrorHandler,
			})

			handler := timeoutMW(tt.handlerFn)
			err := handler(c)

			// For fast handler, no error expected
			if tt.wantCode == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				if rec.Code != tt.wantStatus {
					t.Errorf("response status = %d, want %d", rec.Code, tt.wantStatus)
				}
				return
			}

			// For slow handler, expect timeout error
			if err == nil {
				t.Fatal("expected error from deadline exceeded, got nil")
			}

			appErr, ok := err.(*httputil.AppError)
			if !ok {
				t.Fatalf("expected *httputil.AppError, got %T", err)
			}
			if appErr.Code != tt.wantCode {
				t.Errorf("code = %s, want %s", appErr.Code, tt.wantCode)
			}
			if appErr.Status != tt.wantStatus {
				t.Errorf("status = %d, want %d", appErr.Status, tt.wantStatus)
			}
		})
	}
}
