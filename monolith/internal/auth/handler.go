package auth

import (
	"context"
	"net/http"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/httputil"
	"github.com/labstack/echo/v4"
)

type HandlerService interface {
	Register(ctx context.Context, req RegisterRequest) (UserResponse, error)
	Login(ctx context.Context, req LoginRequest) (LoginResponse, error)
}

type Handler struct {
	service HandlerService
}

func NewHandler(service HandlerService) *Handler {
	return &Handler{service: service}
}

func (h *Handler) RegisterRoutes(e *echo.Echo) {
	group := e.Group("/api/v1/auth")
	group.POST("/register", h.Register)
	group.POST("/login", h.Login)
}

func (h *Handler) Register(c echo.Context) error {
	var req RegisterRequest
	if err := c.Bind(&req); err != nil {
		return httputil.Error(c, apperror.BadRequest("invalid request payload", nil))
	}
	user, err := h.service.Register(c.Request().Context(), req)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.Success(c, http.StatusCreated, user)
}

func (h *Handler) Login(c echo.Context) error {
	var req LoginRequest
	if err := c.Bind(&req); err != nil {
		return httputil.Error(c, apperror.BadRequest("invalid request payload", nil))
	}
	resp, err := h.service.Login(c.Request().Context(), req)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.Success(c, http.StatusOK, resp)
}
