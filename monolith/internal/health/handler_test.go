package health

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/labstack/echo/v4"
)

func TestHandlerCheck(t *testing.T) {
	tests := []struct {
		name        string
		serviceName string
		now         time.Time
	}{
		{name: "returns health response", serviceName: "monolith", now: time.Date(2026, 5, 5, 12, 0, 0, 0, time.UTC)},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := echo.New()
			h := NewHandler(tt.serviceName)
			h.now = func() time.Time { return tt.now }
			rec := httptest.NewRecorder()
			c := e.NewContext(httptest.NewRequest(http.MethodGet, "/healthz", nil), rec)

			if err := h.Check(c); err != nil {
				t.Fatalf("Check() error: %v", err)
			}
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
			}

			var got map[string]string
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("unmarshal response: %v", err)
			}
			if got["status"] != "ok" || got["service"] != tt.serviceName || got["timestamp"] != "2026-05-05T12:00:00Z" {
				t.Fatalf("response = %+v", got)
			}
		})
	}
}
