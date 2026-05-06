package item

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
)

type fakeRepo struct {
	item         Item
	items        []Item
	err          error
	deletedID    string
	updateName   *string
	updateAmount *int
}

func (f *fakeRepo) Create(context.Context, string, int) (Item, error) {
	if f.err != nil {
		return Item{}, f.err
	}
	return f.item, nil
}

func (f *fakeRepo) List(context.Context, int, int) ([]Item, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.items, nil
}

func (f *fakeRepo) GetByID(context.Context, string) (Item, error) {
	if f.err != nil {
		return Item{}, f.err
	}
	return f.item, nil
}

func (f *fakeRepo) Update(_ context.Context, _ string, name *string, amount *int) (Item, error) {
	f.updateName = name
	f.updateAmount = amount
	if f.err != nil {
		return Item{}, f.err
	}
	return f.item, nil
}

func (f *fakeRepo) Delete(_ context.Context, id string) error {
	f.deletedID = id
	return f.err
}

func TestServiceCreate(t *testing.T) {
	now := time.Date(2026, 5, 5, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name      string
		req       CreateRequest
		repo      *fakeRepo
		wantError bool
		wantCode  apperror.Code
	}{
		{name: "success", req: CreateRequest{Name: " Item A ", AvailableAmount: intPtr(10)}, repo: &fakeRepo{item: Item{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", Name: "Item A", AvailableAmount: 10, CreatedAt: now, UpdatedAt: now}}},
		{name: "missing name", req: CreateRequest{AvailableAmount: intPtr(10)}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "missing available amount", req: CreateRequest{Name: "Item A"}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "negative amount", req: CreateRequest{Name: "Item A", AvailableAmount: intPtr(-1)}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "repo error", req: CreateRequest{Name: "Item A", AvailableAmount: intPtr(10)}, repo: &fakeRepo{err: apperror.Internal("internal server error", errors.New("db"))}, wantError: true, wantCode: apperror.CodeInternal},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NewService(tt.repo).Create(context.Background(), tt.req)
			assertAppError(t, err, tt.wantError, tt.wantCode)
			if !tt.wantError && got.ID == "" {
				t.Fatal("expected created item ID")
			}
		})
	}
}

func TestServiceList(t *testing.T) {
	tests := []struct {
		name      string
		repo      *fakeRepo
		wantCount int
		wantError bool
		wantCode  apperror.Code
	}{
		{name: "success", repo: &fakeRepo{items: []Item{{ID: "item-1"}, {ID: "item-2"}}}, wantCount: 2},
		{name: "repo error", repo: &fakeRepo{err: apperror.Internal("internal server error", errors.New("db"))}, wantError: true, wantCode: apperror.CodeInternal},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NewService(tt.repo).List(context.Background(), pagination.Page{Limit: 50, Offset: 0})
			assertAppError(t, err, tt.wantError, tt.wantCode)
			if !tt.wantError && len(got) != tt.wantCount {
				t.Fatalf("count = %d, want %d", len(got), tt.wantCount)
			}
		})
	}
}

func TestServiceUpdate(t *testing.T) {
	name := "Updated"
	blank := " "
	amount := 0
	negative := -1
	tests := []struct {
		name      string
		id        string
		req       UpdateRequest
		repo      *fakeRepo
		wantError bool
		wantCode  apperror.Code
	}{
		{name: "success", id: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", req: UpdateRequest{Name: &name, AvailableAmount: &amount}, repo: &fakeRepo{item: Item{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001"}}},
		{name: "invalid id", id: "bad", req: UpdateRequest{Name: &name}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "empty body", id: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", req: UpdateRequest{}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "blank name", id: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", req: UpdateRequest{Name: &blank}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "negative amount", id: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", req: UpdateRequest{AvailableAmount: &negative}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := NewService(tt.repo).Update(context.Background(), tt.id, tt.req)
			assertAppError(t, err, tt.wantError, tt.wantCode)
		})
	}
}

func TestServiceDelete(t *testing.T) {
	tests := []struct {
		name      string
		id        string
		repo      *fakeRepo
		wantError bool
		wantCode  apperror.Code
	}{
		{name: "success", id: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", repo: &fakeRepo{}},
		{name: "invalid id", id: "bad", repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "not found", id: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", repo: &fakeRepo{err: apperror.NotFound("item not found")}, wantError: true, wantCode: apperror.CodeNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := NewService(tt.repo).Delete(context.Background(), tt.id)
			assertAppError(t, err, tt.wantError, tt.wantCode)
		})
	}
}

func assertAppError(t *testing.T, err error, wantError bool, wantCode apperror.Code) {
	t.Helper()
	if wantError {
		if err == nil {
			t.Fatal("expected error, got nil")
		}
		var appErr *apperror.Error
		if !errors.As(err, &appErr) {
			t.Fatalf("error type = %T, want *apperror.Error", err)
		}
		if appErr.Code != wantCode {
			t.Fatalf("code = %s, want %s", appErr.Code, wantCode)
		}
		return
	}
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func intPtr(v int) *int {
	return &v
}
