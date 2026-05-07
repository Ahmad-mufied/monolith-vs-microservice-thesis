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
	BulkSave(ctx context.Context, req BulkSaveRequest) error
	List(ctx context.Context, page pagination.Page) ([]Response, error)
	GetByID(ctx context.Context, id string) (Response, error)
	Delete(ctx context.Context, id string) error
}

type Handler struct {
	service HandlerService
}

func NewHandler(service HandlerService) *Handler {
	return &Handler{service: service}
}

func (h *Handler) RegisterRoutes(group *echo.Group) {
	group.GET("/items", h.List)
	group.PUT("/items", h.BulkSave)
	group.GET("/items/:item_id", h.GetByID)
	group.DELETE("/items/:item_id", h.Delete)
}

func (h *Handler) BulkSave(c echo.Context) error {
	var req BulkSaveRequest
	if err := c.Bind(&req); err != nil {
		return httputil.Error(c, apperror.BadRequest("invalid request payload", nil))
	}
	if err := h.service.BulkSave(c.Request().Context(), req); err != nil {
		return httputil.Error(c, err)
	}
	return httputil.Message(c, http.StatusOK, "Items saved successfully")
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

func (h *Handler) Delete(c echo.Context) error {
	if err := h.service.Delete(c.Request().Context(), c.Param("item_id")); err != nil {
		return httputil.Error(c, err)
	}
	return httputil.Message(c, http.StatusOK, "Item deleted successfully")
}
