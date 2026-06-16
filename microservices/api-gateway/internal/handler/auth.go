package handler

import (
	"context"
	"net/http"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/debuglog"
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
	if err := httputil.Bind(c, &req); err != nil {
		return httputil.Error(c, err)
	}
	user, err := h.client.Register(c.Request().Context(), req.Name, req.Email, req.Password)
	if err != nil {
		return httputil.Error(c, err)
	}
	if user == nil {
		return httputil.Error(c, &httputil.AppError{Status: http.StatusInternalServerError, Code: "INTERNAL_SERVER_ERROR", Message: "invalid auth service response"})
	}
	return httputil.MessageData(c, http.StatusCreated, "User registered successfully", dto.RegisterDataResult{User: *user})
}

func (h *AuthHandler) Login(c echo.Context) error {
	var req dto.LoginRequest
	if err := httputil.Bind(c, &req); err != nil {
		return httputil.Error(c, err)
	}
	token, user, err := h.client.Login(c.Request().Context(), req.Email, req.Password)
	if err != nil {
		if appErr, ok := err.(*httputil.AppError); ok {
			debuglog.HTTP(context.Background(), "api-gateway auth login http failed", "gateway_auth_login_http_failure", appErr.Status, appErr.Code, appErr.Message)
		}
		return httputil.Error(c, err)
	}
	if user == nil {
		return httputil.Error(c, &httputil.AppError{Status: http.StatusInternalServerError, Code: "INTERNAL_SERVER_ERROR", Message: "invalid auth service response"})
	}
	return httputil.MessageData(c, http.StatusOK, "Login successful", dto.LoginDataResult{Token: token, User: *user})
}
