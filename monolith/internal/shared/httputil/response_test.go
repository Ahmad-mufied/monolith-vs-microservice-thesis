package httputil

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/labstack/echo/v4"
)

func TestError(t *testing.T) {
	tests := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{name: "app error", err: apperror.NotFound("item not found"), wantStatus: http.StatusNotFound, wantCode: "NOT_FOUND"},
		{name: "unknown error", err: errors.New("database failed"), wantStatus: http.StatusInternalServerError, wantCode: "INTERNAL_SERVER_ERROR"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := echo.New()
			rec := httptest.NewRecorder()
			c := e.NewContext(httptest.NewRequest(http.MethodGet, "/", nil), rec)

			if err := Error(c, tt.err); err != nil {
				t.Fatalf("Error() returned error: %v", err)
			}
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tt.wantStatus)
			}

			var got ErrorResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("unmarshal response: %v", err)
			}
			if got.Status != "error" {
				t.Fatalf("status body = %q, want error", got.Status)
			}
			if got.Error.Code != tt.wantCode {
				t.Fatalf("code = %q, want %q", got.Error.Code, tt.wantCode)
			}
		})
	}
}

func TestList(t *testing.T) {
	tests := []struct {
		name          string
		limit         int
		offset        int
		totalReturned int
	}{
		{name: "empty list meta", limit: 50, offset: 0, totalReturned: 0},
		{name: "non empty list meta", limit: 10, offset: 20, totalReturned: 3},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := echo.New()
			rec := httptest.NewRecorder()
			c := e.NewContext(httptest.NewRequest(http.MethodGet, "/", nil), rec)

			if err := List(c, http.StatusOK, []string{}, tt.limit, tt.offset, tt.totalReturned); err != nil {
				t.Fatalf("List() returned error: %v", err)
			}

			var got ListResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("unmarshal response: %v", err)
			}
			if got.Meta.Limit != tt.limit || got.Meta.Offset != tt.offset || got.Meta.TotalReturned != tt.totalReturned {
				t.Fatalf("meta = %+v, want limit=%d offset=%d total=%d", got.Meta, tt.limit, tt.offset, tt.totalReturned)
			}
		})
	}
}
