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
