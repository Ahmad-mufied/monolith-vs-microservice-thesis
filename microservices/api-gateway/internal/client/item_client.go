package client

import (
	"context"
	"net/http"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/numconv"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
)

// ItemClient wraps the generated gRPC ItemServiceClient.
type ItemClient struct {
	grpc itemv1.ItemServiceClient
}

func NewItemClient(grpc itemv1.ItemServiceClient) *ItemClient {
	return &ItemClient{grpc: grpc}
}

func (c *ItemClient) SyncItems(ctx context.Context, items []dto.SyncItemInput) error {
	reqItems := make([]*itemv1.SyncItemInput, 0, len(items))
	for _, item := range items {
		availableAmount, err := numconv.IntToInt32(item.AvailableAmount, "available_amount")
		if err != nil {
			return &httputil.AppError{
				Status:  http.StatusBadRequest,
				Code:    "BAD_REQUEST",
				Message: err.Error(),
			}
		}

		in := &itemv1.SyncItemInput{Name: item.Name, AvailableAmount: availableAmount}
		if item.ID != nil {
			in.Id = *item.ID
		}
		reqItems = append(reqItems, in)
	}
	_, err := c.grpc.SyncItems(ctx, &itemv1.SyncItemsRequest{Items: reqItems})
	if err != nil {
		return httputil.FromGRPCError(err)
	}
	return nil
}

func (c *ItemClient) ListItems(ctx context.Context, limit, offset int32) ([]dto.Item, error) {
	resp, err := c.grpc.ListItems(ctx, &itemv1.ListItemsRequest{Limit: limit, Offset: offset})
	if err != nil {
		return nil, httputil.FromGRPCError(err)
	}
	items := make([]dto.Item, 0, len(resp.GetItems()))
	for _, it := range resp.GetItems() {
		items = append(items, protoItemToDTO(it))
	}
	return items, nil
}

func (c *ItemClient) GetItemByID(ctx context.Context, itemID string) (*dto.Item, error) {
	resp, err := c.grpc.GetItemById(ctx, &itemv1.GetItemByIdRequest{ItemId: itemID})
	if err != nil {
		return nil, httputil.FromGRPCError(err)
	}
	if resp.GetItem() == nil {
		return nil, &httputil.AppError{Status: http.StatusInternalServerError, Code: "INTERNAL_SERVER_ERROR", Message: "invalid item service response"}
	}
	item := protoItemToDTO(resp.GetItem())
	return &item, nil
}

func (c *ItemClient) GetItemSummariesByIDs(ctx context.Context, ids []string) ([]dto.ItemSummary, error) {
	resp, err := c.grpc.GetItemSummariesByIds(ctx, &itemv1.GetItemSummariesByIdsRequest{ItemIds: ids})
	if err != nil {
		return nil, httputil.FromGRPCError(err)
	}
	items := make([]dto.ItemSummary, 0, len(resp.GetItems()))
	for _, it := range resp.GetItems() {
		items = append(items, dto.ItemSummary{ID: it.GetId(), Name: it.GetName(), Deleted: it.GetDeleted()})
	}
	return items, nil
}

func protoItemToDTO(it *itemv1.Item) dto.Item {
	if it == nil {
		return dto.Item{}
	}
	return dto.Item{
		ID:              it.GetId(),
		Name:            it.GetName(),
		AvailableAmount: int(it.GetAvailableAmount()),
		CreatedAt:       it.GetCreatedAt(),
		UpdatedAt:       it.GetUpdatedAt(),
	}
}
