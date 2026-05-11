package port

import (
	"context"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
)

type ItemService interface {
	ValidateTransactionItems(ctx context.Context, items []domain.TransactionItem) error
}
