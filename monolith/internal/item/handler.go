package item

import (
	"context"
	"net/http"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/httputil"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
	"github.com/labstack/echo/v4"
)

type HandlerService interface {
	SyncItems(ctx context.Context, req SyncItemsRequest) error
	List(ctx context.Context, page pagination.Page) ([]Response, error)
	GetByID(ctx context.Context, id string) (Response, error)
}

type Handler struct {
	service HandlerService
}

func NewHandler(service HandlerService) *Handler {
	return &Handler{service: service}
}

func (h *Handler) RegisterRoutes(group *echo.Group) {
	group.GET("/items", h.List)
	group.PUT("/items", h.SyncItems)
	group.GET("/items/:item_id", h.GetByID)
}

func (h *Handler) SyncItems(c echo.Context) error {
	var req SyncItemsRequest
	if err := c.Bind(&req); err != nil {
		return httputil.Error(c, apperror.BadRequest("invalid request payload", nil))
	}
	if err := h.service.SyncItems(c.Request().Context(), req); err != nil {
		return httputil.Error(c, err)
	}
	return httputil.Message(c, http.StatusOK, "Items synchronized successfully")
}

func (h *Handler) List(c echo.Context) error {
	page, err := pagination.FromContext(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	resp, err := h.service.List(c.Request().Context(), page)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.List(c, http.StatusOK, resp, page.Limit, page.Offset, len(resp))
}

func (h *Handler) GetByID(c echo.Context) error {
	resp, err := h.service.GetByID(c.Request().Context(), c.Param("item_id"))
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.Success(c, http.StatusOK, resp)
}
