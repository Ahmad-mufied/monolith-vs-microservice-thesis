package pagination

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/labstack/echo/v4"
)

func TestFromContext(t *testing.T) {
	tests := []struct {
		name      string
		target    string
		want      Page
		wantError bool
		wantField string
		wantMsg   string
	}{
		{name: "defaults", target: "/", want: Page{Limit: 50, Offset: 0}},
		{name: "explicit values", target: "/?limit=10&offset=20", want: Page{Limit: 10, Offset: 20}},
		{name: "limit too high", target: "/?limit=101", wantError: true, wantField: "limit", wantMsg: "must be between 1 and 100"},
		{name: "limit invalid", target: "/?limit=x", wantError: true, wantField: "limit", wantMsg: "must be between 1 and 100"},
		{name: "offset negative", target: "/?offset=-1", wantError: true, wantField: "offset", wantMsg: "must be greater than or equal to 0"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := echo.New()
			c := e.NewContext(httptest.NewRequest(http.MethodGet, tt.target, nil), httptest.NewRecorder())

			got, err := FromContext(c)
			if tt.wantError {
				assertValidationError(t, err, tt.wantField, tt.wantMsg)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Fatalf("page = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func assertValidationError(t *testing.T, err error, wantField, wantMessage string) {
	t.Helper()
	if err == nil {
		t.Fatal("expected error, got nil")
	}

	appErr, ok := errors.AsType[*apperror.Error](err)
	if !ok {
		t.Fatalf("error type = %T, want *apperror.Error", err)
	}
	if appErr.Message != "invalid request payload" {
		t.Fatalf("message = %q, want %q", appErr.Message, "invalid request payload")
	}

	gotMessage, ok := appErr.Details[wantField]
	if !ok {
		t.Fatalf("details = %#v, want field %q", appErr.Details, wantField)
	}
	if gotMessage != wantMessage {
		t.Fatalf("details[%q] = %v, want %q", wantField, gotMessage, wantMessage)
	}
}
