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
	Create(ctx context.Context, name string, availableAmount int) (Item, error)
	List(ctx context.Context, limit, offset int) ([]Item, error)
	GetByID(ctx context.Context, id string) (Item, error)
	Update(ctx context.Context, id string, name *string, availableAmount *int) (Item, error)
	Delete(ctx context.Context, id string) error
}

type Service struct {
	repo Repository
}

func NewService(repo Repository) *Service {
	return &Service{repo: repo}
}

func (s *Service) Create(ctx context.Context, req CreateRequest) (Response, error) {
	name := strings.TrimSpace(req.Name)
	normalizedReq := CreateRequest{Name: name, AvailableAmount: req.AvailableAmount}
	if err := validation.Struct(normalizedReq); err != nil {
		return Response{}, err
	}
	item, err := s.repo.Create(ctx, name, *req.AvailableAmount)
	if err != nil {
		return Response{}, err
	}
	return toResponse(item), nil
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

func (s *Service) Update(ctx context.Context, id string, req UpdateRequest) (Response, error) {
	if err := validateUUID(id, "item_id"); err != nil {
		return Response{}, err
	}
	if req.Name == nil && req.AvailableAmount == nil {
		return Response{}, apperror.BadRequest("invalid request payload", map[string]any{"body": "at least one field is required"})
	}
	if req.Name != nil {
		name := strings.TrimSpace(*req.Name)
		if name == "" {
			return Response{}, apperror.BadRequest("invalid request payload", map[string]any{"name": "must not be empty"})
		}
		req.Name = &name
	}
	if err := validation.Struct(req); err != nil {
		return Response{}, err
	}
	item, err := s.repo.Update(ctx, id, req.Name, req.AvailableAmount)
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
