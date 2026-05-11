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
	items       []Item
	item        Item
	err         error
	synced      []SyncItem
	syncCalls   int
	requestedID string
}

func (f *fakeRepo) SyncItems(_ context.Context, items []SyncItem) error {
	f.syncCalls++
	f.synced = items
	return f.err
}

func (f *fakeRepo) List(context.Context, int, int) ([]Item, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.items, nil
}

func (f *fakeRepo) GetByID(_ context.Context, id string) (Item, error) {
	f.requestedID = id
	if f.err != nil {
		return Item{}, f.err
	}
	return f.item, nil
}

func TestServiceSyncItems(t *testing.T) {
	amount10 := 10
	amount20 := 20
	amount0 := 0
	negativeOne := -1
	itemID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001"
	upperItemID := "018F5F60-7C35-7CCF-9C3C-0A5E6F6F2001"

	tests := []struct {
		name            string
		req             SyncItemsRequest
		repo            *fakeRepo
		wantError       bool
		wantCode        apperror.Code
		wantRepoCalls   int
		wantSyncedCount int
	}{
		{
			name: "mixed update and insert payload",
			req: SyncItemsRequest{Items: []SyncItemRequest{
				{ID: new(upperItemID), Name: " Existing Item ", AvailableAmount: &amount10},
				{Name: " New Item ", AvailableAmount: &amount20},
			}},
			repo:            &fakeRepo{},
			wantRepoCalls:   1,
			wantSyncedCount: 2,
		},
		{
			name:            "empty snapshot is allowed",
			req:             SyncItemsRequest{Items: []SyncItemRequest{}},
			repo:            &fakeRepo{},
			wantRepoCalls:   1,
			wantSyncedCount: 0,
		},
		{
			name:      "nil items is rejected",
			req:       SyncItemsRequest{Items: nil},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:      "invalid uuid",
			req:       SyncItemsRequest{Items: []SyncItemRequest{{ID: new("bad"), Name: "Item", AvailableAmount: &amount10}}},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:      "blank name",
			req:       SyncItemsRequest{Items: []SyncItemRequest{{Name: "   ", AvailableAmount: &amount10}}},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:      "duplicate ids are rejected",
			req:       SyncItemsRequest{Items: []SyncItemRequest{{ID: new(itemID), Name: "Item A", AvailableAmount: &amount10}, {ID: new(upperItemID), Name: "Item B", AvailableAmount: &amount20}}},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:      "duplicate names are rejected case-insensitive",
			req:       SyncItemsRequest{Items: []SyncItemRequest{{Name: "Laptop", AvailableAmount: &amount10}, {Name: " laptop ", AvailableAmount: &amount20}}},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:      "missing amount",
			req:       SyncItemsRequest{Items: []SyncItemRequest{{Name: "Item"}}},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:      "negative amount",
			req:       SyncItemsRequest{Items: []SyncItemRequest{{Name: "Item", AvailableAmount: &negativeOne}}},
			repo:      &fakeRepo{},
			wantError: true,
			wantCode:  apperror.CodeBadRequest,
		},
		{
			name:            "zero amount is allowed",
			req:             SyncItemsRequest{Items: []SyncItemRequest{{Name: "Item", AvailableAmount: &amount0}}},
			repo:            &fakeRepo{},
			wantRepoCalls:   1,
			wantSyncedCount: 1,
		},
		{
			name:          "conflict bubbles up",
			req:           SyncItemsRequest{Items: []SyncItemRequest{{Name: "Item", AvailableAmount: &amount10}}},
			repo:          &fakeRepo{err: apperror.Conflict("item name already exists")},
			wantError:     true,
			wantCode:      apperror.CodeConflict,
			wantRepoCalls: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := NewService(tt.repo).SyncItems(context.Background(), tt.req)
			assertAppError(t, err, tt.wantError, tt.wantCode)
			if tt.repo.syncCalls != tt.wantRepoCalls {
				t.Fatalf("repo sync calls = %d, want %d", tt.repo.syncCalls, tt.wantRepoCalls)
			}
			if tt.wantSyncedCount > 0 && len(tt.repo.synced) != tt.wantSyncedCount {
				t.Fatalf("synced items = %+v", tt.repo.synced)
			}
			if tt.name == "mixed update and insert payload" {
				if tt.repo.synced[0].ID == nil || *tt.repo.synced[0].ID != itemID {
					t.Fatalf("first id = %+v, want %s", tt.repo.synced[0].ID, itemID)
				}
				if tt.repo.synced[0].Name != "Existing Item" || tt.repo.synced[1].Name != "New Item" {
					t.Fatalf("synced items = %+v", tt.repo.synced)
				}
				if tt.repo.synced[1].ID != nil {
					t.Fatalf("expected generated-id item to keep nil ID, got %+v", tt.repo.synced[1].ID)
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
	itemID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001"
	upperItemID := "018F5F60-7C35-7CCF-9C3C-0A5E6F6F2001"
	tests := []struct {
		name            string
		id              string
		repo            *fakeRepo
		wantError       bool
		wantCode        apperror.Code
		wantRequestedID string
	}{
		{name: "success", id: upperItemID, repo: &fakeRepo{item: Item{ID: itemID, CreatedAt: now, UpdatedAt: now}}, wantRequestedID: itemID},
		{name: "invalid id", id: "bad", repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "not found", id: itemID, repo: &fakeRepo{err: apperror.NotFound("item not found")}, wantError: true, wantCode: apperror.CodeNotFound, wantRequestedID: itemID},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NewService(tt.repo).GetByID(context.Background(), tt.id)
			assertAppError(t, err, tt.wantError, tt.wantCode)
			if tt.wantRequestedID != "" && tt.repo.requestedID != tt.wantRequestedID {
				t.Fatalf("requested id = %q, want %q", tt.repo.requestedID, tt.wantRequestedID)
			}
			if !tt.wantError && got.ID == "" {
				t.Fatal("expected item ID")
			}
		})
	}
}

func TestServiceSyncItemsValidationDetails(t *testing.T) {
	service := NewService(&fakeRepo{})
	amount := 10
	itemID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001"

	err := service.SyncItems(context.Background(), SyncItemsRequest{
		Items: []SyncItemRequest{{Name: " ", AvailableAmount: &amount}},
	})
	assertValidationDetail(t, err, "name", "is required")

	err = service.SyncItems(context.Background(), SyncItemsRequest{
		Items: []SyncItemRequest{{ID: new("bad"), Name: "Item", AvailableAmount: &amount}},
	})
	assertValidationDetail(t, err, "id", "must be a valid UUID")

	err = service.SyncItems(context.Background(), SyncItemsRequest{
		Items: []SyncItemRequest{
			{ID: new(itemID), Name: "Item A", AvailableAmount: &amount},
			{ID: new(strings.ToUpper(itemID)), Name: "Item B", AvailableAmount: &amount},
		},
	})
	assertValidationDetail(t, err, "id", "must not contain duplicate values")

	err = service.SyncItems(context.Background(), SyncItemsRequest{
		Items: []SyncItemRequest{{Name: strings.Repeat("a", 161), AvailableAmount: &amount}},
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
