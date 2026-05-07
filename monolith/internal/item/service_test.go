package item

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
)

type fakeRepo struct {
	items         []Item
	item          Item
	err           error
	deletedID     string
	bulkSaved     []BulkSaveItem
	bulkSaveCalls int
}

func (f *fakeRepo) BulkSave(_ context.Context, items []BulkSaveItem) error {
	f.bulkSaveCalls++
	f.bulkSaved = items
	return f.err
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

func (f *fakeRepo) Delete(_ context.Context, id string) error {
	f.deletedID = id
	return f.err
}

func TestServiceBulkSave(t *testing.T) {
	amount10 := 10
	amount20 := 20
	amount0 := 0
	negativeOne := -1
	existingID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001"
	newID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2002"

	tests := []struct {
		name           string
		req            BulkSaveRequest
		repo           *fakeRepo
		wantError      bool
		wantCode       apperror.Code
		wantRepoCalls  int
		wantSavedCount int
	}{
		{
			name: "mixed insert update payload",
			req: BulkSaveRequest{Items: []BulkSaveItemRequest{
				{ID: &existingID, Name: " Existing Item ", AvailableAmount: &amount10},
				{Name: " New Item ", AvailableAmount: &amount20},
			}},
			repo:           &fakeRepo{},
			wantRepoCalls:  1,
			wantSavedCount: 2,
		},
		{
			name: "insert with provided uuid",
			req: BulkSaveRequest{Items: []BulkSaveItemRequest{
				{ID: &newID, Name: "Provided ID Item", AvailableAmount: &amount10},
			}},
			repo:           &fakeRepo{},
			wantRepoCalls:  1,
			wantSavedCount: 1,
		},
		{
			name: "insert with generated uuid",
			req: BulkSaveRequest{Items: []BulkSaveItemRequest{
				{Name: "Generated ID Item", AvailableAmount: &amount10},
			}},
			repo:           &fakeRepo{},
			wantRepoCalls:  1,
			wantSavedCount: 1,
		},
		{
			name:      "invalid uuid",
			req:       BulkSaveRequest{Items: []BulkSaveItemRequest{{ID: new("bad"), Name: "Item", AvailableAmount: &amount10}}},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:      "blank name causes full rollback before repo call",
			req:       BulkSaveRequest{Items: []BulkSaveItemRequest{{Name: " ", AvailableAmount: &amount10}, {Name: "Still Valid", AvailableAmount: &amount20}}},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:      "missing amount",
			req:       BulkSaveRequest{Items: []BulkSaveItemRequest{{Name: "Item"}}},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:      "negative amount",
			req:       BulkSaveRequest{Items: []BulkSaveItemRequest{{Name: "Item", AvailableAmount: &negativeOne}}},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:           "zero amount allowed",
			req:            BulkSaveRequest{Items: []BulkSaveItemRequest{{Name: "Item", AvailableAmount: &amount0}}},
			repo:           &fakeRepo{},
			wantError:      false,
			wantRepoCalls:  1,
			wantSavedCount: 1,
		},
		{
			name:          "conflict bubbles up",
			req:           BulkSaveRequest{Items: []BulkSaveItemRequest{{Name: "Item", AvailableAmount: &amount10}}},
			repo:          &fakeRepo{err: apperror.Conflict("item name already exists")},
			wantError:     true,
			wantCode:      apperror.CodeConflict,
			wantRepoCalls: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := NewService(tt.repo).BulkSave(context.Background(), tt.req)
			assertAppError(t, err, tt.wantError, tt.wantCode)
			if tt.repo.bulkSaveCalls != tt.wantRepoCalls {
				t.Fatalf("repo bulk save calls = %d, want %d", tt.repo.bulkSaveCalls, tt.wantRepoCalls)
			}
			if tt.wantSavedCount > 0 && len(tt.repo.bulkSaved) != tt.wantSavedCount {
				t.Fatalf("saved items = %+v", tt.repo.bulkSaved)
			}
			if tt.name == "mixed insert update payload" {
				if tt.repo.bulkSaved[0].ID == nil || *tt.repo.bulkSaved[0].ID != existingID {
					t.Fatalf("first id = %+v, want %s", tt.repo.bulkSaved[0].ID, existingID)
				}
				if tt.repo.bulkSaved[0].Name != "Existing Item" || tt.repo.bulkSaved[1].Name != "New Item" {
					t.Fatalf("saved items = %+v", tt.repo.bulkSaved)
				}
				if tt.repo.bulkSaved[1].ID != nil {
					t.Fatalf("expected generated-id item to keep nil ID, got %+v", tt.repo.bulkSaved[1].ID)
				}
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

func TestServiceGetByID(t *testing.T) {
	now := time.Date(2026, 5, 5, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name      string
		id        string
		repo      *fakeRepo
		wantError bool
		wantCode  apperror.Code
	}{
		{name: "success", id: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", repo: &fakeRepo{item: Item{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", CreatedAt: now, UpdatedAt: now}}},
		{name: "invalid id", id: "bad", repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "not found", id: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", repo: &fakeRepo{err: apperror.NotFound("item not found")}, wantError: true, wantCode: apperror.CodeNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NewService(tt.repo).GetByID(context.Background(), tt.id)
			assertAppError(t, err, tt.wantError, tt.wantCode)
			if !tt.wantError && got.ID == "" {
				t.Fatal("expected item ID")
			}
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

func TestServiceBulkSaveValidationDetails(t *testing.T) {
	service := NewService(&fakeRepo{})
	amount := 10

	err := service.BulkSave(context.Background(), BulkSaveRequest{
		Items: []BulkSaveItemRequest{{Name: " ", AvailableAmount: &amount}},
	})
	assertValidationDetail(t, err, "name", "must not be empty")

	err = service.BulkSave(context.Background(), BulkSaveRequest{
		Items: []BulkSaveItemRequest{{ID: new("bad"), Name: "Item", AvailableAmount: &amount}},
	})
	assertValidationDetail(t, err, "id", "must be a valid UUID")

	err = service.BulkSave(context.Background(), BulkSaveRequest{
		Items: []BulkSaveItemRequest{{Name: strings.Repeat("a", 161), AvailableAmount: &amount}},
	})
	assertValidationDetail(t, err, "name", "must be at most 160 characters")
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

func assertValidationDetail(t *testing.T, err error, wantField, wantMessage string) {
	t.Helper()
	var appErr *apperror.Error
	if !errors.As(err, &appErr) {
		t.Fatalf("error type = %T, want *apperror.Error", err)
	}

	gotMessage, ok := appErr.Details[wantField]
	if !ok {
		t.Fatalf("details = %#v, want field %q", appErr.Details, wantField)
	}
	if gotMessage != wantMessage {
		t.Fatalf("details[%q] = %v, want %q", wantField, gotMessage, wantMessage)
	}
}
