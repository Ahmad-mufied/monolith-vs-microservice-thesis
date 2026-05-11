package port

import (
	"context"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
)

type TransactionRepository interface {
	BeginTx(ctx context.Context) (TransactionWriteTx, error)
	ListByUserID(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error)
	GetByIDAndUserID(ctx context.Context, transactionID, userID string) (*domain.Transaction, error)
	ListForEnrichment(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error)
	ListItemsByTransactionIDs(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error)
}

type TransactionWriteTx interface {
	InsertTransaction(ctx context.Context, userID string) (string, error)
	InsertTransactionItems(ctx context.Context, transactionID string, items []domain.TransactionItem) error
	Commit(ctx context.Context) error
	Rollback() error
}
