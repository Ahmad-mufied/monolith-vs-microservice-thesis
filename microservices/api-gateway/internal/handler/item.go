package handler

import (
	"context"
	"net/http"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/labstack/echo/v4"
)

type itemClient interface {
	SyncItems(ctx context.Context, items []dto.SyncItemInput) error
	ListItems(ctx context.Context, limit, offset int32) ([]dto.Item, error)
	GetItemByID(ctx context.Context, itemID string) (*dto.Item, error)
	GetItemSummariesByIDs(ctx context.Context, ids []string) ([]dto.ItemSummary, error)
}

type ItemHandler struct {
	client itemClient
}

func NewItemHandler(client itemClient) *ItemHandler {
	return &ItemHandler{client: client}
}

func (h *ItemHandler) ListItems(c echo.Context) error {
	limit, offset, err := httputil.ParsePage(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	items, err := h.client.ListItems(c.Request().Context(), limit, offset)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.List(c, http.StatusOK, items, limit, offset, len(items))
}

func (h *ItemHandler) SyncItems(c echo.Context) error {
	var req dto.SyncItemsRequest
	if err := c.Bind(&req); err != nil {
		return httputil.Error(c, &httputil.AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: "invalid request payload"})
	}
	if err := h.client.SyncItems(c.Request().Context(), req.Items); err != nil {
		return httputil.Error(c, err)
	}
	return httputil.Message(c, http.StatusOK, "Items synchronized successfully")
}

func (h *ItemHandler) GetItemByID(c echo.Context) error {
	item, err := h.client.GetItemByID(c.Request().Context(), c.Param("item_id"))
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.Success(c, http.StatusOK, item)
}
