package apperror

import (
	"context"
	"errors"
	"net/http"
	"testing"
)

func TestErrorConstructors(t *testing.T) {
	tests := []struct {
		name       string
		err        *Error
		wantCode   Code
		wantStatus int
	}{
		{name: "bad request", err: BadRequest("invalid request", map[string]any{"field": "email"}), wantCode: CodeBadRequest, wantStatus: http.StatusBadRequest},
		{name: "unauthorized", err: Unauthorized("invalid token"), wantCode: CodeUnauthorized, wantStatus: http.StatusUnauthorized},
		{name: "not found", err: NotFound("item not found"), wantCode: CodeNotFound, wantStatus: http.StatusNotFound},
		{name: "conflict", err: Conflict("email already exists"), wantCode: CodeConflict, wantStatus: http.StatusConflict},
		{name: "deadline exceeded", err: DeadlineExceeded("request timeout", context.DeadlineExceeded), wantCode: CodeGatewayTimeout, wantStatus: http.StatusGatewayTimeout},
		{name: "canceled", err: Canceled("request canceled", context.Canceled), wantCode: CodeClientCanceled, wantStatus: 499},
		{name: "internal", err: Internal("internal server error", errors.New("db failed")), wantCode: CodeInternal, wantStatus: http.StatusInternalServerError},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.err.Code != tt.wantCode {
				t.Fatalf("code = %s, want %s", tt.err.Code, tt.wantCode)
			}
			if tt.err.Status != tt.wantStatus {
				t.Fatalf("status = %d, want %d", tt.err.Status, tt.wantStatus)
			}
			if tt.err.Error() == "" {
				t.Fatal("error string is empty")
			}
		})
	}
}

func TestFromContext(t *testing.T) {
	tests := []struct {
		name       string
		err        error
		wantCode   Code
		wantStatus int
	}{
		{name: "deadline exceeded", err: context.DeadlineExceeded, wantCode: CodeGatewayTimeout, wantStatus: http.StatusGatewayTimeout},
		{name: "canceled", err: context.Canceled, wantCode: CodeClientCanceled, wantStatus: 499},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := FromContext(tt.err, "request timeout", "request canceled")
			if got == nil {
				t.Fatal("FromContext() = nil")
			}
			if got.Code != tt.wantCode {
				t.Fatalf("code = %s, want %s", got.Code, tt.wantCode)
			}
			if got.Status != tt.wantStatus {
				t.Fatalf("status = %d, want %d", got.Status, tt.wantStatus)
			}
			if !errors.Is(got, tt.err) {
				t.Fatalf("FromContext() should preserve cause %v, got %v", tt.err, got)
			}
		})
	}
}

func TestContextError(t *testing.T) {
	if got := ContextError(context.Background()); got != nil {
		t.Fatalf("ContextError(active) = %v, want nil", got)
	}

	canceledCtx, cancel := context.WithCancel(context.Background())
	cancel()

	got := ContextError(canceledCtx)
	if got == nil {
		t.Fatal("ContextError(canceled) = nil")
	}
	if got.Code != CodeClientCanceled {
		t.Fatalf("code = %s, want %s", got.Code, CodeClientCanceled)
	}
	if !errors.Is(got, context.Canceled) {
		t.Fatalf("ContextError(canceled) should preserve context.Canceled, got %v", got)
	}
}

func TestContextAwareHelpers(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	called := false
	if err := DoIfActive(ctx, func() error {
		called = true
		return nil
	}); !IsContext(err) {
		t.Fatalf("DoIfActive(canceled) = %v, want context error", err)
	}
	if called {
		t.Fatal("DoIfActive should not call fn for canceled context")
	}

	got, err := CallIfActive(context.Background(), func() (string, error) {
		return "ok", nil
	})
	if err != nil || got != "ok" {
		t.Fatalf("CallIfActive(active) = %q, %v; want ok, nil", got, err)
	}

	_, err = CallIfActive(ctx, func() (string, error) {
		t.Fatal("CallIfActive should not call fn for canceled context")
		return "", nil
	})
	if !IsContext(err) {
		t.Fatalf("CallIfActive(canceled) = %v, want context error", err)
	}

	driverErr := errors.New("driver error")
	activeCtx, activeCancel := context.WithCancel(context.Background())
	if err := DoIfActive(activeCtx, func() error {
		activeCancel()
		return driverErr
	}); !IsContext(err) {
		t.Fatalf("DoIfActive(error after cancel) = %v, want context error", err)
	}

	activeCtx, activeCancel = context.WithCancel(context.Background())
	_, err = CallIfActive(activeCtx, func() (string, error) {
		activeCancel()
		return "", driverErr
	})
	if !IsContext(err) {
		t.Fatalf("CallIfActive(error after cancel) = %v, want context error", err)
	}
}

func TestInternalFromContext(t *testing.T) {
	tests := []struct {
		name       string
		err        error
		wantCode   Code
		wantStatus int
	}{
		{name: "deadline exceeded", err: context.DeadlineExceeded, wantCode: CodeGatewayTimeout, wantStatus: http.StatusGatewayTimeout},
		{name: "canceled", err: context.Canceled, wantCode: CodeClientCanceled, wantStatus: 499},
		{name: "other", err: errors.New("driver error"), wantCode: CodeInternal, wantStatus: http.StatusInternalServerError},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := InternalFromContext("query users", tt.err)
			if got.Code != tt.wantCode {
				t.Fatalf("code = %s, want %s", got.Code, tt.wantCode)
			}
			if got.Status != tt.wantStatus {
				t.Fatalf("status = %d, want %d", got.Status, tt.wantStatus)
			}
			if !errors.Is(got, tt.err) {
				t.Fatalf("InternalFromContext() should preserve cause %v, got %v", tt.err, got)
			}
		})
	}
}
