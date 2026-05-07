package transaction

import (
	"context"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/validation"
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
	if err := validation.Struct(req); err != nil {
		return Response{}, err
	}
	items, err := validateAndNormalizeCreateItems(req.Items)
	if err != nil {
		return Response{}, err
	}
	tx, err := s.repo.Create(ctx, userID, items)
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

func validateAndNormalizeCreateItems(items []CreateItemRequest) ([]CreateItemRequest, error) {
	seen := make(map[string]struct{}, len(items))
	normalized := make([]CreateItemRequest, 0, len(items))
	for _, item := range items {
		itemUUID, err := uuid.Parse(item.ItemID)
		if err != nil {
			return nil, apperror.BadRequest("invalid request payload", map[string]any{"item_id": "must be a valid UUID"})
		}
		normalizedID := itemUUID.String()
		if _, ok := seen[normalizedID]; ok {
			return nil, apperror.BadRequest("invalid request payload", map[string]any{"item_id": "duplicate item in transaction"})
		}
		seen[normalizedID] = struct{}{}
		normalized = append(normalized, CreateItemRequest{
			ItemID: normalizedID,
			Amount: item.Amount,
		})
	}
	return normalized, nil
}

func validateUUID(value, field string) error {
	if _, err := uuid.Parse(value); err != nil {
		return apperror.BadRequest("invalid request payload", map[string]any{field: "must be a valid UUID"})
	}
	return nil
}
