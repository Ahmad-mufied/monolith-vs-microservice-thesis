package transaction

import (
	"context"
	"net/http"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/httputil"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/middleware"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
	"github.com/labstack/echo/v4"
)

type HandlerService interface {
	Create(ctx context.Context, userID string, req CreateRequest) (string, error)
	ListOwn(ctx context.Context, userID string, page pagination.Page) ([]Response, error)
	GetOwnByID(ctx context.Context, userID, transactionID string) (Response, error)
	ListEnriched(ctx context.Context, page pagination.Page) ([]EnrichedResponse, error)
}

type Handler struct {
	service HandlerService
}

func NewHandler(service HandlerService) *Handler {
	return &Handler{service: service}
}

func (h *Handler) RegisterRoutes(api *echo.Group) {
	api.POST("/transactions", h.Create)
	api.GET("/transactions", h.ListOwn)
	api.GET("/transactions/:transaction_id", h.GetOwnByID)
	api.GET("/admin/transactions", h.ListEnriched)
}

func (h *Handler) Create(c echo.Context) error {
	userID, err := middleware.UserID(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	var req CreateRequest
	if err := c.Bind(&req); err != nil {
		return httputil.Error(c, apperror.BadRequest("invalid request payload", nil))
	}
	transactionID, err := h.service.Create(c.Request().Context(), userID, req)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.ID(c, http.StatusCreated, "Transaction created successfully", transactionID)
}

func (h *Handler) ListOwn(c echo.Context) error {
	userID, err := middleware.UserID(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	page, err := pagination.FromContext(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	resp, err := h.service.ListOwn(c.Request().Context(), userID, page)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.List(c, http.StatusOK, resp, page.Limit, page.Offset, len(resp))
}

func (h *Handler) GetOwnByID(c echo.Context) error {
	userID, err := middleware.UserID(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	resp, err := h.service.GetOwnByID(c.Request().Context(), userID, c.Param("transaction_id"))
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.Success(c, http.StatusOK, resp)
}

func (h *Handler) ListEnriched(c echo.Context) error {
	page, err := pagination.FromContext(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	resp, err := h.service.ListEnriched(c.Request().Context(), page)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.List(c, http.StatusOK, resp, page.Limit, page.Offset, len(resp))
}
