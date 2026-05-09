package port

import (
	"context"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/domain"
)

type ItemRepository interface {
	SyncItems(ctx context.Context, items []domain.SyncItemInput) error
	ListItems(ctx context.Context, limit, offset int32) ([]*domain.Item, error)
	GetItemByID(ctx context.Context, id string) (*domain.Item, error)
	GetItemSummariesByIDs(ctx context.Context, ids []string) ([]*domain.ItemSummary, error)
	ValidateTransactionItems(ctx context.Context, items []domain.TransactionItemValidationInput) error
}
