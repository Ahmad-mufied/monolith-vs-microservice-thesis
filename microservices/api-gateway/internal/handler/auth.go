package handler

import (
	"context"
	"net/http"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/labstack/echo/v4"
)

type authClient interface {
	Register(ctx context.Context, name, email, password string) (*dto.UserSummary, error)
	Login(ctx context.Context, email, password string) (string, *dto.UserSummary, error)
	GetUsersByIDs(ctx context.Context, ids []string) ([]*dto.UserSummary, error)
}

type AuthHandler struct {
	client authClient
}

func NewAuthHandler(client authClient) *AuthHandler {
	return &AuthHandler{client: client}
}

func (h *AuthHandler) Register(c echo.Context) error {
	var req dto.RegisterRequest
	if err := c.Bind(&req); err != nil {
		return httputil.Error(c, &httputil.AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: "invalid request payload"})
	}
	user, err := h.client.Register(c.Request().Context(), req.Name, req.Email, req.Password)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.MessageData(c, http.StatusCreated, "User registered successfully", dto.RegisterDataResult{User: *user})
}

func (h *AuthHandler) Login(c echo.Context) error {
	var req dto.LoginRequest
	if err := c.Bind(&req); err != nil {
		return httputil.Error(c, &httputil.AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: "invalid request payload"})
	}
	token, user, err := h.client.Login(c.Request().Context(), req.Email, req.Password)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.MessageData(c, http.StatusOK, "Login successful", dto.LoginDataResult{Token: token, User: *user})
}
