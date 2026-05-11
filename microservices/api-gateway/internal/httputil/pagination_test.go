package httputil

import (
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
)

func TestParsePage(t *testing.T) {
	tests := []struct {
		name        string
		query       string
		wantLimit   int32
		wantOffset  int32
		wantErrCode string
	}{
		{
			name:       "defaults when empty",
			query:      "",
			wantLimit:  50,
			wantOffset: 0,
		},
		{
			name:       "explicit valid values",
			query:      "limit=10&offset=20",
			wantLimit:  10,
			wantOffset: 20,
		},
		{
			name:       "limit at max boundary",
			query:      "limit=100",
			wantLimit:  100,
			wantOffset: 0,
		},
		{
			name:        "limit exceeds max",
			query:       "limit=101",
			wantErrCode: "BAD_REQUEST",
		},
		{
			name:        "limit zero",
			query:       "limit=0",
			wantErrCode: "BAD_REQUEST",
		},
		{
			name:        "limit negative",
			query:       "limit=-1",
			wantErrCode: "BAD_REQUEST",
		},
		{
			name:        "offset negative",
			query:       "offset=-1",
			wantErrCode: "BAD_REQUEST",
		},
		{
			name:        "limit non-numeric",
			query:       "limit=abc",
			wantErrCode: "BAD_REQUEST",
		},
		{
			name:        "offset non-numeric",
			query:       "offset=abc",
			wantErrCode: "BAD_REQUEST",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := echo.New()
			req := httptest.NewRequest("GET", "/?"+tt.query, nil)
			c := e.NewContext(req, httptest.NewRecorder())

			limit, offset, err := ParsePage(c)

			if tt.wantErrCode != "" {
				if err == nil {
					t.Fatalf("ParsePage() error = nil, want error with code %q", tt.wantErrCode)
				}
				appErr, ok := err.(*AppError)
				if !ok {
					t.Fatalf("error type = %T, want *AppError", err)
				}
				if appErr.Code != tt.wantErrCode {
					t.Errorf("Code = %q, want %q", appErr.Code, tt.wantErrCode)
				}
				return
			}

			if err != nil {
				t.Fatalf("ParsePage() unexpected error: %v", err)
			}
			if limit != tt.wantLimit {
				t.Errorf("limit = %d, want %d", limit, tt.wantLimit)
			}
			if offset != tt.wantOffset {
				t.Errorf("offset = %d, want %d", offset, tt.wantOffset)
			}
		})
	}
}
