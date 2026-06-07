package item

import (
	"context"
	"strings"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/validation"
	"github.com/google/uuid"
)

type Repository interface {
	SyncItems(ctx context.Context, items []SyncItem) error
	List(ctx context.Context, limit, offset int) ([]Item, error)
	GetByID(ctx context.Context, id string) (Item, error)
}

type Service struct {
	repo Repository
}

func NewService(repo Repository) *Service {
	return &Service{repo: repo}
}

func (s *Service) SyncItems(ctx context.Context, req SyncItemsRequest) error {
	if req.Items == nil {
		return apperror.BadRequest("invalid request payload", map[string]any{"items": "is required"})
	}
	if err := validation.Struct(req); err != nil {
		return err
	}
	items, err := apperror.CallIfActive(ctx, func() ([]SyncItem, error) {
		return normalizeSyncItems(req.Items)
	})
	if err != nil {
		return err
	}
	if err := s.repo.SyncItems(ctx, items); err != nil {
		return err
	}
	return nil
}

func (s *Service) List(ctx context.Context, page pagination.Page) ([]Response, error) {
	items, err := apperror.CallIfActive(ctx, func() ([]Item, error) {
		return s.repo.List(ctx, page.Limit, page.Offset)
	})
	if err != nil {
		return nil, err
	}
	return toResponses(items), nil
}

func (s *Service) GetByID(ctx context.Context, id string) (Response, error) {
	normalizedID, err := parseUUIDField(id, "item_id")
	if err != nil {
		return Response{}, err
	}
	item, err := apperror.CallIfActive(ctx, func() (Item, error) {
		return s.repo.GetByID(ctx, normalizedID)
	})
	if err != nil {
		return Response{}, err
	}
	return toResponse(item), nil
}

// normalizeSyncItems validates and normalizes the sync payload, returning
// deduplicated SyncItem values ready for the repository.
func normalizeSyncItems(inputs []SyncItemRequest) ([]SyncItem, error) {
	items := make([]SyncItem, 0, len(inputs))
	seenIDs := make(map[string]struct{}, len(inputs))
	seenNames := make(map[string]struct{}, len(inputs))

	for _, input := range inputs {
		name := strings.TrimSpace(input.Name)
		if name == "" {
			return nil, apperror.BadRequest("invalid request payload", map[string]any{"name": "is required"})
		}
		nameKey := strings.ToLower(name)
		if _, dup := seenNames[nameKey]; dup {
			return nil, apperror.BadRequest("invalid request payload", map[string]any{"name": "must not contain duplicate values"})
		}
		seenNames[nameKey] = struct{}{}

		item := SyncItem{
			Name:            name,
			AvailableAmount: *input.AvailableAmount,
		}

		if input.ID != nil {
			id, err := parseUUIDField(*input.ID, "id")
			if err != nil {
				return nil, err
			}
			if _, dup := seenIDs[id]; dup {
				return nil, apperror.BadRequest("invalid request payload", map[string]any{"id": "must not contain duplicate values"})
			}
			seenIDs[id] = struct{}{}
			item.ID = &id
		}

		items = append(items, item)
	}

	return items, nil
}

// parseUUIDField trims, validates, and canonicalizes a UUID string.
// Returns a BAD_REQUEST apperror if the value is not a valid UUID.
func parseUUIDField(value, field string) (string, error) {
	parsed, err := uuid.Parse(strings.TrimSpace(value))
	if err != nil {
		return "", apperror.BadRequest("invalid request payload", map[string]any{field: "must be a valid UUID"})
	}
	return parsed.String(), nil
}
