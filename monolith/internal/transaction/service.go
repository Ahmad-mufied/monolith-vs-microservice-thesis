package transaction

import (
	"context"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
	"github.com/google/uuid"
)

type Repository interface {
	Create(ctx context.Context, userID string, items []CreateItemRequest) (Transaction, error)
	ListOwn(ctx context.Context, userID string, limit, offset int) ([]Transaction, error)
	GetOwnByID(ctx context.Context, userID, transactionID string) (Transaction, error)
	ListEnriched(ctx context.Context, limit, offset int) ([]EnrichedTransaction, error)
}

type Service struct {
	repo Repository
}

func NewService(repo Repository) *Service {
	return &Service{repo: repo}
}

func (s *Service) Create(ctx context.Context, userID string, req CreateRequest) (Response, error) {
	if err := validateUUID(userID, "user_id"); err != nil {
		return Response{}, err
	}
	if err := validateCreateItems(req.Items); err != nil {
		return Response{}, err
	}
	tx, err := s.repo.Create(ctx, userID, req.Items)
	if err != nil {
		return Response{}, err
	}
	return toResponse(tx), nil
}

func (s *Service) ListOwn(ctx context.Context, userID string, page pagination.Page) ([]Response, error) {
	if err := validateUUID(userID, "user_id"); err != nil {
		return nil, err
	}
	transactions, err := s.repo.ListOwn(ctx, userID, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return toResponses(transactions), nil
}

func (s *Service) GetOwnByID(ctx context.Context, userID, transactionID string) (Response, error) {
	if err := validateUUID(userID, "user_id"); err != nil {
		return Response{}, err
	}
	if err := validateUUID(transactionID, "transaction_id"); err != nil {
		return Response{}, err
	}
	tx, err := s.repo.GetOwnByID(ctx, userID, transactionID)
	if err != nil {
		return Response{}, err
	}
	return toResponse(tx), nil
}

func (s *Service) ListEnriched(ctx context.Context, page pagination.Page) ([]EnrichedResponse, error) {
	transactions, err := s.repo.ListEnriched(ctx, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return toEnrichedResponses(transactions), nil
}

func validateCreateItems(items []CreateItemRequest) error {
	if len(items) == 0 {
		return apperror.BadRequest("invalid request payload", map[string]any{"items": "must contain at least one item"})
	}
	if len(items) > 20 {
		return apperror.BadRequest("invalid request payload", map[string]any{"items": "must contain at most 20 items"})
	}
	seen := make(map[string]struct{}, len(items))
	for _, item := range items {
		if err := validateUUID(item.ItemID, "item_id"); err != nil {
			return err
		}
		if item.Amount < 1 {
			return apperror.BadRequest("invalid request payload", map[string]any{"amount": "must be greater than 0"})
		}
		if _, ok := seen[item.ItemID]; ok {
			return apperror.BadRequest("invalid request payload", map[string]any{"item_id": "duplicate item in transaction"})
		}
		seen[item.ItemID] = struct{}{}
	}
	return nil
}

func validateUUID(value, field string) error {
	if _, err := uuid.Parse(value); err != nil {
		return apperror.BadRequest("invalid request payload", map[string]any{field: "must be a valid UUID"})
	}
	return nil
}
