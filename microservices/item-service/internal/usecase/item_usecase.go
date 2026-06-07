package usecase

import (
	"context"
	"strings"
	"unicode/utf8"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/domain"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/port"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	pkgvalidator "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/validator"
	"github.com/google/uuid"
)

const (
	defaultListLimit = int32(50)
	maxListLimit     = int32(100)
	maxItemNameChars = 160
)

type ItemUsecase struct {
	repo port.ItemRepository
}

func NewItemUsecase(repo port.ItemRepository) *ItemUsecase {
	return &ItemUsecase{repo: repo}
}

func (u *ItemUsecase) SyncItems(ctx context.Context, items []domain.SyncItemInput) error {
	normalized, err := pkgerrors.CallIfActive(ctx, func() ([]domain.SyncItemInput, error) {
		return normalizeSyncItems(items)
	})
	if err != nil {
		return err
	}

	if err := pkgerrors.DoIfActive(ctx, func() error {
		return u.repo.SyncItems(ctx, normalized)
	}); err != nil {
		return err
	}
	return nil
}

func (u *ItemUsecase) ListItems(ctx context.Context, limit, offset int32) ([]*domain.Item, error) {
	if limit == 0 {
		limit = defaultListLimit
	}
	if limit < 0 {
		return nil, invalidInputDetail("limit", "must be greater than or equal to 0")
	}
	if limit > maxListLimit {
		return nil, invalidInputDetail("limit", "must be less than or equal to 100")
	}
	if offset < 0 {
		return nil, invalidInputDetail("offset", "must be greater than or equal to 0")
	}

	return pkgerrors.CallIfActive(ctx, func() ([]*domain.Item, error) {
		return u.repo.ListItems(ctx, limit, offset)
	})
}

func (u *ItemUsecase) GetItemByID(ctx context.Context, itemID string) (*domain.Item, error) {
	if err := pkgvalidator.ValidateUUIDField(itemID, "item_id"); err != nil {
		return nil, err
	}

	normalizedID := normalizeUUID(itemID)
	return pkgerrors.CallIfActive(ctx, func() (*domain.Item, error) {
		return u.repo.GetItemByID(ctx, normalizedID)
	})
}

func (u *ItemUsecase) GetItemSummariesByIDs(ctx context.Context, itemIDs []string) ([]*domain.ItemSummary, error) {
	normalized := make([]string, 0, len(itemIDs))
	seen := make(map[string]struct{}, len(itemIDs))

	for _, itemID := range itemIDs {
		if err := pkgvalidator.ValidateUUIDField(itemID, "item_ids"); err != nil {
			return nil, err
		}

		normalizedID := normalizeUUID(itemID)
		if _, exists := seen[normalizedID]; exists {
			return nil, invalidInputDetail("item_ids", "must not contain duplicate values")
		}
		seen[normalizedID] = struct{}{}
		normalized = append(normalized, normalizedID)
	}

	return pkgerrors.CallIfActive(ctx, func() ([]*domain.ItemSummary, error) {
		return u.repo.GetItemSummariesByIDs(ctx, normalized)
	})
}

func (u *ItemUsecase) ValidateTransactionItems(ctx context.Context, items []domain.TransactionItemValidationInput) error {
	normalized := make([]domain.TransactionItemValidationInput, 0, len(items))
	seen := make(map[string]struct{}, len(items))

	for _, item := range items {
		if err := pkgvalidator.ValidateUUIDField(item.ItemID, "item_id"); err != nil {
			return err
		}
		if item.Amount <= 0 {
			return invalidInputDetail("amount", "must be greater than 0")
		}

		normalizedID := normalizeUUID(item.ItemID)
		if _, exists := seen[normalizedID]; exists {
			return invalidInputDetail("item_id", "must not contain duplicate values")
		}
		seen[normalizedID] = struct{}{}

		normalized = append(normalized, domain.TransactionItemValidationInput{
			ItemID: normalizedID,
			Amount: item.Amount,
		})
	}

	return pkgerrors.DoIfActive(ctx, func() error {
		return u.repo.ValidateTransactionItems(ctx, normalized)
	})
}

func normalizeSyncItems(items []domain.SyncItemInput) ([]domain.SyncItemInput, error) {
	normalized := make([]domain.SyncItemInput, 0, len(items))
	seenIDs := make(map[string]struct{}, len(items))
	seenNames := make(map[string]struct{}, len(items))

	for _, item := range items {
		name := strings.TrimSpace(item.Name)
		if name == "" {
			return nil, invalidInputDetail("name", "is required")
		}
		if utf8.RuneCountInString(name) > maxItemNameChars {
			return nil, invalidInputDetail("name", "must be at most 160 characters")
		}
		if item.AvailableAmount < 0 {
			return nil, invalidInputDetail("available_amount", "must be greater than or equal to 0")
		}

		nameKey := strings.ToLower(name)
		if _, exists := seenNames[nameKey]; exists {
			return nil, invalidInputDetail("name", "must not contain duplicate values")
		}
		seenNames[nameKey] = struct{}{}

		normalizedItem := domain.SyncItemInput{
			Name:            name,
			AvailableAmount: item.AvailableAmount,
		}

		if item.ID != nil {
			if err := pkgvalidator.ValidateUUIDField(*item.ID, "id"); err != nil {
				return nil, err
			}

			normalizedID := normalizeUUID(*item.ID)
			if _, exists := seenIDs[normalizedID]; exists {
				return nil, invalidInputDetail("id", "must not contain duplicate values")
			}
			seenIDs[normalizedID] = struct{}{}
			normalizedItem.ID = &normalizedID
		}

		normalized = append(normalized, normalizedItem)
	}

	return normalized, nil
}

func normalizeUUID(value string) string {
	return uuid.MustParse(value).String()
}

func invalidInputDetail(field, description string) error {
	return pkgerrors.InvalidInputDetails("invalid request payload", map[string]string{
		field: description,
	})
}
