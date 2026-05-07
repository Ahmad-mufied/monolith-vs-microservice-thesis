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
	BulkSave(ctx context.Context, items []BulkSaveItem) error
	List(ctx context.Context, limit, offset int) ([]Item, error)
	GetByID(ctx context.Context, id string) (Item, error)
	Delete(ctx context.Context, id string) error
}

type Service struct {
	repo Repository
}

func NewService(repo Repository) *Service {
	return &Service{repo: repo}
}

func (s *Service) BulkSave(ctx context.Context, req BulkSaveRequest) error {
	if err := validation.Struct(req); err != nil {
		return err
	}

	items := make([]BulkSaveItem, 0, len(req.Items))
	for _, input := range req.Items {
		name := strings.TrimSpace(input.Name)
		if name == "" {
			return apperror.BadRequest("invalid request payload", map[string]any{"name": "must not be empty"})
		}

		var id *string
		if input.ID != nil {
			normalizedID := strings.TrimSpace(*input.ID)
			if err := validateUUID(normalizedID, "id"); err != nil {
				return err
			}
			id = &normalizedID
		}

		items = append(items, BulkSaveItem{
			ID:              id,
			Name:            name,
			AvailableAmount: *input.AvailableAmount,
		})
	}
	return s.repo.BulkSave(ctx, items)
}

func (s *Service) List(ctx context.Context, page pagination.Page) ([]Response, error) {
	items, err := s.repo.List(ctx, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return toResponses(items), nil
}

func (s *Service) GetByID(ctx context.Context, id string) (Response, error) {
	if err := validateUUID(id, "item_id"); err != nil {
		return Response{}, err
	}
	item, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return Response{}, err
	}
	return toResponse(item), nil
}

func (s *Service) Delete(ctx context.Context, id string) error {
	if err := validateUUID(id, "item_id"); err != nil {
		return err
	}
	return s.repo.Delete(ctx, id)
}

func validateUUID(value, field string) error {
	if _, err := uuid.Parse(value); err != nil {
		return apperror.BadRequest("invalid request payload", map[string]any{field: "must be a valid UUID"})
	}
	return nil
}
