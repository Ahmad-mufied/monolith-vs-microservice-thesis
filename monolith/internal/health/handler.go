package health

import (
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
)

type Handler struct {
	serviceName string
	now         func() time.Time
}

func NewHandler(serviceName string) *Handler {
	return &Handler{serviceName: serviceName, now: time.Now}
}

func (h *Handler) Register(e *echo.Echo) {
	e.GET("/healthz", h.Check)
}

func (h *Handler) Check(c echo.Context) error {
	return c.JSON(http.StatusOK, map[string]any{
		"status":    "ok",
		"service":   h.serviceName,
		"timestamp": h.now().UTC().Format(time.RFC3339),
	})
}
