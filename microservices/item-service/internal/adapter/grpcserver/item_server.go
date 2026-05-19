package grpcserver

import (
	"context"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/domain"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/usecase"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/numconv"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
)

type itemUsecase interface {
	SyncItems(ctx context.Context, items []domain.SyncItemInput) error
	ListItems(ctx context.Context, limit, offset int32) ([]*domain.Item, error)
	GetItemByID(ctx context.Context, itemID string) (*domain.Item, error)
	GetItemSummariesByIDs(ctx context.Context, itemIDs []string) ([]*domain.ItemSummary, error)
	ValidateTransactionItems(ctx context.Context, items []domain.TransactionItemValidationInput) error
}

type ItemServer struct {
	itemv1.UnimplementedItemServiceServer
	uc itemUsecase
}

func NewItemServer(uc *usecase.ItemUsecase) *ItemServer {
	return &ItemServer{uc: uc}
}

func (s *ItemServer) SyncItems(ctx context.Context, req *itemv1.SyncItemsRequest) (*itemv1.SyncItemsResponse, error) {
	items := make([]domain.SyncItemInput, 0, len(req.GetItems()))
	for _, item := range req.GetItems() {
		input := domain.SyncItemInput{
			Name:            item.GetName(),
			AvailableAmount: int(item.GetAvailableAmount()),
		}
		if item.GetId() != "" {
			itemID := item.GetId()
			input.ID = &itemID
		}
		items = append(items, input)
	}

	if err := s.uc.SyncItems(ctx, items); err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	return &itemv1.SyncItemsResponse{}, nil
}

func (s *ItemServer) ListItems(ctx context.Context, req *itemv1.ListItemsRequest) (*itemv1.ListItemsResponse, error) {
	items, err := s.uc.ListItems(ctx, req.GetLimit(), req.GetOffset())
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	var totalReturned int32
	respItems := make([]*itemv1.Item, 0, len(items))
	for _, item := range items {
		protoItem, err := domainItemToProto(item)
		if err != nil {
			return nil, pkgerrors.ToGRPCStatus(pkgerrors.Internal("internal server error", err))
		}
		respItems = append(respItems, protoItem)
		totalReturned++
	}

	return &itemv1.ListItemsResponse{
		Items:         respItems,
		TotalReturned: totalReturned,
	}, nil
}

func (s *ItemServer) GetItemById(ctx context.Context, req *itemv1.GetItemByIdRequest) (*itemv1.GetItemByIdResponse, error) {
	item, err := s.uc.GetItemByID(ctx, req.GetItemId())
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	protoItem, err := domainItemToProto(item)
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(pkgerrors.Internal("internal server error", err))
	}

	return &itemv1.GetItemByIdResponse{
		Item: protoItem,
	}, nil
}

func (s *ItemServer) GetItemSummariesByIds(ctx context.Context, req *itemv1.GetItemSummariesByIdsRequest) (*itemv1.GetItemSummariesByIdsResponse, error) {
	items, err := s.uc.GetItemSummariesByIDs(ctx, req.GetItemIds())
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	respItems := make([]*itemv1.ItemSummary, 0, len(items))
	for _, item := range items {
		respItems = append(respItems, &itemv1.ItemSummary{
			Id:      item.ID,
			Name:    item.Name,
			Deleted: item.Deleted,
		})
	}

	return &itemv1.GetItemSummariesByIdsResponse{
		Items: respItems,
	}, nil
}

func (s *ItemServer) ValidateTransactionItems(ctx context.Context, req *itemv1.ValidateTransactionItemsRequest) (*itemv1.ValidateTransactionItemsResponse, error) {
	items := make([]domain.TransactionItemValidationInput, 0, len(req.GetItems()))
	for _, item := range req.GetItems() {
		items = append(items, domain.TransactionItemValidationInput{
			ItemID: item.GetItemId(),
			Amount: int(item.GetAmount()),
		})
	}

	if err := s.uc.ValidateTransactionItems(ctx, items); err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	return &itemv1.ValidateTransactionItemsResponse{}, nil
}

func domainItemToProto(item *domain.Item) (*itemv1.Item, error) {
	if item == nil {
		return nil, nil
	}

	availableAmount, err := numconv.IntToInt32(item.AvailableAmount, "available_amount")
	if err != nil {
		return nil, err
	}

	return &itemv1.Item{
		Id:              item.ID,
		Name:            item.Name,
		AvailableAmount: availableAmount,
		CreatedAt:       item.CreatedAt.UTC().Format(time.RFC3339),
		UpdatedAt:       item.UpdatedAt.UTC().Format(time.RFC3339),
	}, nil
}
