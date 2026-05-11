package handler

import (
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
)

type HealthHandler struct{}

func NewHealthHandler() *HealthHandler { return &HealthHandler{} }

func (h *HealthHandler) Handle(c echo.Context) error {
	return c.JSON(http.StatusOK, map[string]any{
		"message":   "ok",
		"service":   "api-gateway",
		"timestamp": time.Now().UTC().Format(time.RFC3339),
	})
}
