package apperror

import (
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
