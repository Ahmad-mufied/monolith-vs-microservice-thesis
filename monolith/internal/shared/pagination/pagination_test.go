package pagination

import (
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
	}{
		{name: "defaults", target: "/", want: Page{Limit: 50, Offset: 0}},
		{name: "explicit values", target: "/?limit=10&offset=20", want: Page{Limit: 10, Offset: 20}},
		{name: "limit too high", target: "/?limit=101", wantError: true},
		{name: "limit invalid", target: "/?limit=x", wantError: true},
		{name: "offset negative", target: "/?offset=-1", wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := echo.New()
			c := e.NewContext(httptest.NewRequest(http.MethodGet, tt.target, nil), httptest.NewRecorder())

			got, err := FromContext(c)
			if tt.wantError {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				if _, ok := err.(*apperror.Error); !ok {
					t.Fatalf("error type = %T, want *apperror.Error", err)
				}
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
