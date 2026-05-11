package usecase

import (
	"context"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/port"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	pkgvalidator "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/validator"
	"github.com/google/uuid"
)

const (
	defaultListLimit      = int32(50)
	maxListLimit          = int32(100)
	maxCreateItems        = 20
	itemValidationTimeout = 5 * time.Second
)

type TransactionUsecase struct {
	repo        port.TransactionRepository
	itemService port.ItemService
}

func NewTransactionUsecase(repo port.TransactionRepository, itemService port.ItemService) *TransactionUsecase {
	return &TransactionUsecase{
		repo:        repo,
		itemService: itemService,
	}
}

func (u *TransactionUsecase) CreateTransaction(ctx context.Context, userID string, items []domain.TransactionItem) (string, error) {
	normalizedUserID, normalizedItems, err := normalizeCreateTransactionInput(userID, items)
	if err != nil {
		return "", err
	}

	validateCtx, cancel := context.WithTimeout(ctx, itemValidationTimeout)
	defer cancel()

	if err := u.itemService.ValidateTransactionItems(validateCtx, normalizedItems); err != nil {
		return "", err
	}

	tx, err := u.repo.BeginTx(ctx)
	if err != nil {
		return "", err
	}

	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	transactionID, err := tx.InsertTransaction(ctx, normalizedUserID)
	if err != nil {
		return "", err
	}

	if err := tx.InsertTransactionItems(ctx, transactionID, normalizedItems); err != nil {
		return "", err
	}

	if err := tx.Commit(ctx); err != nil {
		return "", err
	}

	committed = true
	return transactionID, nil
}

func (u *TransactionUsecase) GetOwnTransactions(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
	normalizedUserID, err := normalizeUUIDField(userID, "user_id")
	if err != nil {
		return nil, err
	}

	limit, offset, err = normalizePagination(limit, offset)
	if err != nil {
		return nil, err
	}

	transactions, err := u.repo.ListByUserID(ctx, normalizedUserID, limit, offset)
	if err != nil {
		return nil, err
	}

	return u.attachItems(ctx, transactions)
}

func (u *TransactionUsecase) GetTransactionByID(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
	normalizedTransactionID, err := normalizeUUIDField(transactionID, "transaction_id")
	if err != nil {
		return nil, err
	}
	normalizedUserID, err := normalizeUUIDField(userID, "user_id")
	if err != nil {
		return nil, err
	}

	transaction, err := u.repo.GetByIDAndUserID(ctx, normalizedTransactionID, normalizedUserID)
	if err != nil {
		return nil, err
	}

	transactions, err := u.attachItems(ctx, []*domain.Transaction{transaction})
	if err != nil {
		return nil, err
	}
	if len(transactions) == 0 {
		return nil, pkgerrors.NotFound("transaction not found")
	}

	return transactions[0], nil
}

func (u *TransactionUsecase) GetTransactionsForEnrichment(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
	limit, offset, err := normalizePagination(limit, offset)
	if err != nil {
		return nil, err
	}

	transactions, err := u.repo.ListForEnrichment(ctx, limit, offset)
	if err != nil {
		return nil, err
	}

	return u.attachItems(ctx, transactions)
}

func (u *TransactionUsecase) attachItems(ctx context.Context, transactions []*domain.Transaction) ([]*domain.Transaction, error) {
	if len(transactions) == 0 {
		return []*domain.Transaction{}, nil
	}

	transactionIDs := make([]string, 0, len(transactions))
	for _, transaction := range transactions {
		transactionIDs = append(transactionIDs, transaction.ID)
	}

	itemsByTransactionID, err := u.repo.ListItemsByTransactionIDs(ctx, transactionIDs)
	if err != nil {
		return nil, err
	}

	for _, transaction := range transactions {
		transaction.Items = append([]domain.TransactionItem(nil), itemsByTransactionID[transaction.ID]...)
	}

	return transactions, nil
}

func normalizeCreateTransactionInput(userID string, items []domain.TransactionItem) (string, []domain.TransactionItem, error) {
	normalizedUserID, err := normalizeUUIDField(userID, "user_id")
	if err != nil {
		return "", nil, err
	}

	if len(items) == 0 {
		return "", nil, invalidInputDetail("items", "is required")
	}
	if len(items) > maxCreateItems {
		return "", nil, invalidInputDetail("items", "must contain at most 20 items")
	}

	normalizedItems := make([]domain.TransactionItem, 0, len(items))
	seen := make(map[string]struct{}, len(items))
	for _, item := range items {
		normalizedItemID, err := normalizeUUIDField(item.ItemID, "item_id")
		if err != nil {
			return "", nil, err
		}
		if item.Amount <= 0 {
			return "", nil, invalidInputDetail("amount", "must be greater than 0")
		}
		if _, exists := seen[normalizedItemID]; exists {
			return "", nil, invalidInputDetail("item_id", "must not contain duplicate values")
		}
		seen[normalizedItemID] = struct{}{}

		normalizedItems = append(normalizedItems, domain.TransactionItem{
			ItemID: normalizedItemID,
			Amount: item.Amount,
		})
	}

	return normalizedUserID, normalizedItems, nil
}

func normalizePagination(limit, offset int32) (int32, int32, error) {
	if limit == 0 {
		limit = defaultListLimit
	}
	if limit < 0 {
		return 0, 0, invalidInputDetail("limit", "must be greater than or equal to 0")
	}
	if limit > maxListLimit {
		return 0, 0, invalidInputDetail("limit", "must be less than or equal to 100")
	}
	if offset < 0 {
		return 0, 0, invalidInputDetail("offset", "must be greater than or equal to 0")
	}
	return limit, offset, nil
}

func normalizeUUIDField(value, field string) (string, error) {
	if err := pkgvalidator.ValidateUUIDField(value, field); err != nil {
		return "", err
	}
	return uuid.MustParse(value).String(), nil
}

func invalidInputDetail(field, description string) error {
	return pkgerrors.InvalidInputDetails("invalid request payload", map[string]string{
		field: description,
	})
}
