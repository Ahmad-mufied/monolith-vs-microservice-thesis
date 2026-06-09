package middleware

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/labstack/echo/v4"
	echomw "github.com/labstack/echo/v4/middleware"
)

func TestContextTimeoutErrorHandler_DeadlineExceeded(t *testing.T) {
	e := echo.New()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	timeoutMW := echomw.ContextTimeoutWithConfig(echomw.ContextTimeoutConfig{
		Timeout:      1 * time.Millisecond,
		ErrorHandler: ContextTimeoutErrorHandler,
	})
	handler := timeoutMW(func(c echo.Context) error {
		select {
		case <-c.Request().Context().Done():
			return c.Request().Context().Err()
		case <-time.After(200 * time.Millisecond):
			return nil
		}
	})

	err := handler(c)
	if err == nil {
		t.Fatal("expected error from deadline exceeded, got nil")
	}

	appErr, ok := err.(*apperror.Error)
	if !ok {
		t.Fatalf("expected *apperror.Error, got %T", err)
	}
	if appErr.Code != apperror.CodeServiceUnavailable {
		t.Fatalf("code = %s, want %s", appErr.Code, apperror.CodeServiceUnavailable)
	}
	if appErr.Status != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", appErr.Status, http.StatusServiceUnavailable)
	}
}

func TestContextTimeoutErrorHandler_ClientCanceled(t *testing.T) {
	e := echo.New()
	canceledCtx, cancel := context.WithCancel(context.Background())
	cancel()

	req := httptest.NewRequest(http.MethodGet, "/", nil).WithContext(canceledCtx)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	err := ContextTimeoutErrorHandler(c.Request().Context().Err(), c)
	if err == nil {
		t.Fatal("expected canceled error, got nil")
	}

	appErr, ok := err.(*apperror.Error)
	if !ok {
		t.Fatalf("expected *apperror.Error, got %T", err)
	}
	if appErr.Code != apperror.CodeClientCanceled {
		t.Fatalf("code = %s, want %s", appErr.Code, apperror.CodeClientCanceled)
	}
	if appErr.Status != 499 {
		t.Fatalf("status = %d, want 499", appErr.Status)
	}
}

func TestContextTimeoutErrorHandler_PassThrough(t *testing.T) {
	e := echo.New()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	err := ContextTimeoutErrorHandler(echo.NewHTTPError(http.StatusBadRequest, "bad request"), c)
	httpErr, ok := err.(*echo.HTTPError)
	if !ok {
		t.Fatalf("expected *echo.HTTPError, got %T", err)
	}
	if httpErr.Code != http.StatusBadRequest {
		t.Fatalf("code = %d, want %d", httpErr.Code, http.StatusBadRequest)
	}
}
