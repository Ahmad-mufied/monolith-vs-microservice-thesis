package usecase

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/domain"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
)

// --- fake repo ---

type fakeItemRepo struct {
	syncItemsFn                func(ctx context.Context, items []domain.SyncItemInput) error
	listItemsFn                func(ctx context.Context, limit, offset int32) ([]*domain.Item, error)
	getItemByIDFn              func(ctx context.Context, id string) (*domain.Item, error)
	getItemSummariesByIDsFn    func(ctx context.Context, ids []string) ([]*domain.ItemSummary, error)
	validateTransactionItemsFn func(ctx context.Context, items []domain.TransactionItemValidationInput) error
}

func (f *fakeItemRepo) SyncItems(ctx context.Context, items []domain.SyncItemInput) error {
	return f.syncItemsFn(ctx, items)
}
func (f *fakeItemRepo) ListItems(ctx context.Context, limit, offset int32) ([]*domain.Item, error) {
	return f.listItemsFn(ctx, limit, offset)
}
func (f *fakeItemRepo) GetItemByID(ctx context.Context, id string) (*domain.Item, error) {
	return f.getItemByIDFn(ctx, id)
}
func (f *fakeItemRepo) GetItemSummariesByIDs(ctx context.Context, ids []string) ([]*domain.ItemSummary, error) {
	return f.getItemSummariesByIDsFn(ctx, ids)
}
func (f *fakeItemRepo) ValidateTransactionItems(ctx context.Context, items []domain.TransactionItemValidationInput) error {
	return f.validateTransactionItemsFn(ctx, items)
}

// --- helpers ---

func assertValidationDetail(t *testing.T, err error, wantField, wantMessage string) {
	t.Helper()
	var detailedErr interface{ PublicDetails() map[string]string }
	if !errors.As(err, &detailedErr) {
		t.Fatalf("expected error with validation details, got %v", err)
	}
	details := detailedErr.PublicDetails()
	if gotMessage, ok := details[wantField]; !ok {
		t.Fatalf("details = %#v, want field %q", details, wantField)
	} else if gotMessage != wantMessage {
		t.Fatalf("details[%q] = %q, want %q", wantField, gotMessage, wantMessage)
	}
}

// --- TestSyncItems ---

func TestSyncItems(t *testing.T) {
	itemID := "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"
	upperItemID := "01968AD4-98B1-79C8-A6F0-EC21F8F434C6"

	tests := []struct {
		name        string
		input       []domain.SyncItemInput
		repoFn      func(ctx context.Context, items []domain.SyncItemInput) error
		wantErr     error
		wantField   string
		wantMessage string
	}{
		{
			name: "normalizes uuid and trims name",
			input: []domain.SyncItemInput{
				{ID: &upperItemID, Name: "  Laptop  ", AvailableAmount: 10},
				{Name: " Mouse ", AvailableAmount: 5},
			},
			repoFn: func(ctx context.Context, items []domain.SyncItemInput) error {
				if len(items) != 2 {
					t.Fatalf("len(items) = %d, want 2", len(items))
				}
				if items[0].ID == nil || *items[0].ID != itemID {
					t.Fatalf("items[0].ID = %v, want %q", items[0].ID, itemID)
				}
				if items[0].Name != "Laptop" {
					t.Fatalf("items[0].Name = %q, want Laptop", items[0].Name)
				}
				if items[1].ID != nil {
					t.Fatalf("items[1].ID = %v, want nil", items[1].ID)
				}
				return nil
			},
		},
		{
			name:   "empty snapshot calls repo with empty slice",
			input:  nil,
			repoFn: func(ctx context.Context, items []domain.SyncItemInput) error { return nil },
		},
		{
			name:        "rejects invalid uuid",
			input:       []domain.SyncItemInput{{ID: new("not-a-uuid"), Name: "Laptop", AvailableAmount: 10}},
			repoFn:      noCallSyncFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "id",
			wantMessage: "must be a valid UUID",
		},
		{
			name:        "rejects blank name",
			input:       []domain.SyncItemInput{{Name: "   ", AvailableAmount: 10}},
			repoFn:      noCallSyncFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "name",
			wantMessage: "is required",
		},
		{
			name:        "rejects name too long",
			input:       []domain.SyncItemInput{{Name: strings.Repeat("a", 161), AvailableAmount: 10}},
			repoFn:      noCallSyncFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "name",
			wantMessage: "must be at most 160 characters",
		},
		{
			name:        "rejects negative available_amount",
			input:       []domain.SyncItemInput{{Name: "Laptop", AvailableAmount: -1}},
			repoFn:      noCallSyncFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "available_amount",
			wantMessage: "must be greater than or equal to 0",
		},
		{
			name: "rejects duplicate ids",
			input: []domain.SyncItemInput{
				{ID: &itemID, Name: "Laptop", AvailableAmount: 10},
				{ID: &itemID, Name: "Mouse", AvailableAmount: 5},
			},
			repoFn:      noCallSyncFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "id",
			wantMessage: "must not contain duplicate values",
		},
		{
			name: "rejects duplicate names case-insensitive",
			input: []domain.SyncItemInput{
				{Name: "Laptop", AvailableAmount: 10},
				{Name: " laptop ", AvailableAmount: 5},
			},
			repoFn:      noCallSyncFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "name",
			wantMessage: "must not contain duplicate values",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uc := NewItemUsecase(&fakeItemRepo{syncItemsFn: tt.repoFn})
			err := uc.SyncItems(context.Background(), tt.input)

			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("error = %v, want %v", err, tt.wantErr)
				}
				assertValidationDetail(t, err, tt.wantField, tt.wantMessage)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

// --- TestListItems ---

func TestListItems(t *testing.T) {
	tests := []struct {
		name        string
		limit       int32
		offset      int32
		wantLimit   int32
		wantOffset  int32
		wantErr     error
		wantField   string
		wantMessage string
	}{
		{
			name:       "applies default limit when zero",
			limit:      0,
			offset:     5,
			wantLimit:  defaultListLimit,
			wantOffset: 5,
		},
		{
			name:       "passes explicit limit and offset",
			limit:      10,
			offset:     20,
			wantLimit:  10,
			wantOffset: 20,
		},
		{
			name:        "rejects negative limit",
			limit:       -1,
			offset:      0,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "limit",
			wantMessage: "must be greater than or equal to 0",
		},
		{
			name:        "rejects limit over 100",
			limit:       101,
			offset:      0,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "limit",
			wantMessage: "must be less than or equal to 100",
		},
		{
			name:        "rejects negative offset",
			limit:       10,
			offset:      -1,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "offset",
			wantMessage: "must be greater than or equal to 0",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := &fakeItemRepo{
				listItemsFn: func(ctx context.Context, limit, offset int32) ([]*domain.Item, error) {
					if limit != tt.wantLimit || offset != tt.wantOffset {
						t.Fatalf("limit=%d offset=%d, want limit=%d offset=%d", limit, offset, tt.wantLimit, tt.wantOffset)
					}
					return []*domain.Item{}, nil
				},
			}
			uc := NewItemUsecase(repo)
			_, err := uc.ListItems(context.Background(), tt.limit, tt.offset)

			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("error = %v, want %v", err, tt.wantErr)
				}
				assertValidationDetail(t, err, tt.wantField, tt.wantMessage)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

func TestListItemsContextCanceledBeforeRepository(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	uc := NewItemUsecase(&fakeItemRepo{
		listItemsFn: func(ctx context.Context, limit, offset int32) ([]*domain.Item, error) {
			t.Fatalf("ListItems should not be called")
			return nil, nil
		},
	})

	_, err := uc.ListItems(ctx, 10, 0)
	if !errors.Is(err, pkgerrors.ErrCanceled) {
		t.Fatalf("error = %v, want ErrCanceled", err)
	}
}

// --- TestGetItemByID ---

func TestGetItemByID(t *testing.T) {
	want := &domain.Item{
		ID:              "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
		Name:            "Laptop",
		AvailableAmount: 10,
		CreatedAt:       time.Now(),
		UpdatedAt:       time.Now(),
	}

	tests := []struct {
		name        string
		itemID      string
		repoFn      func(ctx context.Context, id string) (*domain.Item, error)
		wantErr     error
		wantField   string
		wantMessage string
	}{
		{
			name:   "normalizes uuid and returns item",
			itemID: "01968AD4-98B1-79C8-A6F0-EC21F8F434C6",
			repoFn: func(ctx context.Context, id string) (*domain.Item, error) {
				if id != want.ID {
					t.Fatalf("id = %q, want %q", id, want.ID)
				}
				return want, nil
			},
		},
		{
			name:        "rejects invalid uuid",
			itemID:      "bad-id",
			repoFn:      noCallGetItemFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "item_id",
			wantMessage: "must be a valid UUID",
		},
		{
			name:   "propagates not found",
			itemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
			repoFn: func(ctx context.Context, id string) (*domain.Item, error) {
				return nil, pkgerrors.NotFound("item not found")
			},
			wantErr: pkgerrors.ErrNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uc := NewItemUsecase(&fakeItemRepo{getItemByIDFn: tt.repoFn})
			_, err := uc.GetItemByID(context.Background(), tt.itemID)

			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("error = %v, want %v", err, tt.wantErr)
				}
				if tt.wantField != "" {
					assertValidationDetail(t, err, tt.wantField, tt.wantMessage)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

// --- TestGetItemSummariesByIDs ---

func TestGetItemSummariesByIDs(t *testing.T) {
	tests := []struct {
		name        string
		ids         []string
		repoFn      func(ctx context.Context, ids []string) ([]*domain.ItemSummary, error)
		wantErr     error
		wantField   string
		wantMessage string
		checkResult func(t *testing.T, items []*domain.ItemSummary)
	}{
		{
			name: "returns summaries including soft-deleted",
			ids: []string{
				"01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
				"01968ad4-98b1-79c8-a6f0-ec21f8f434c7",
			},
			repoFn: func(ctx context.Context, ids []string) ([]*domain.ItemSummary, error) {
				return []*domain.ItemSummary{
					{ID: ids[0], Name: "Laptop", Deleted: false},
					{ID: ids[1], Name: "Mouse", Deleted: true},
				}, nil
			},
			checkResult: func(t *testing.T, items []*domain.ItemSummary) {
				if len(items) != 2 || !items[1].Deleted {
					t.Fatalf("items = %#v, want deleted flag on second item", items)
				}
			},
		},
		{
			name: "normalizes uuid casing",
			ids:  []string{"01968AD4-98B1-79C8-A6F0-EC21F8F434C6"},
			repoFn: func(ctx context.Context, ids []string) ([]*domain.ItemSummary, error) {
				if ids[0] != "01968ad4-98b1-79c8-a6f0-ec21f8f434c6" {
					t.Fatalf("ids[0] = %q, want lowercase", ids[0])
				}
				return []*domain.ItemSummary{}, nil
			},
		},
		{
			name:        "rejects invalid uuid",
			ids:         []string{"bad-id"},
			repoFn:      noCallGetSummariesFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "item_ids",
			wantMessage: "must be a valid UUID",
		},
		{
			name: "rejects duplicate ids",
			ids: []string{
				"01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
				"01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
			},
			repoFn:      noCallGetSummariesFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "item_ids",
			wantMessage: "must not contain duplicate values",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uc := NewItemUsecase(&fakeItemRepo{getItemSummariesByIDsFn: tt.repoFn})
			items, err := uc.GetItemSummariesByIDs(context.Background(), tt.ids)

			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("error = %v, want %v", err, tt.wantErr)
				}
				assertValidationDetail(t, err, tt.wantField, tt.wantMessage)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.checkResult != nil {
				tt.checkResult(t, items)
			}
		})
	}
}

// --- TestValidateTransactionItems ---

func TestValidateTransactionItems(t *testing.T) {
	tests := []struct {
		name        string
		input       []domain.TransactionItemValidationInput
		repoFn      func(ctx context.Context, items []domain.TransactionItemValidationInput) error
		wantErr     error
		wantField   string
		wantMessage string
	}{
		{
			name: "normalizes uuid and passes to repo",
			input: []domain.TransactionItemValidationInput{
				{ItemID: "01968AD4-98B1-79C8-A6F0-EC21F8F434C6", Amount: 2},
				{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c7", Amount: 1},
			},
			repoFn: func(ctx context.Context, items []domain.TransactionItemValidationInput) error {
				if items[0].ItemID != "01968ad4-98b1-79c8-a6f0-ec21f8f434c6" {
					t.Fatalf("items[0].ItemID = %q, want lowercase", items[0].ItemID)
				}
				return nil
			},
		},
		{
			name:        "rejects invalid uuid",
			input:       []domain.TransactionItemValidationInput{{ItemID: "bad-id", Amount: 1}},
			repoFn:      noCallValidateFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "item_id",
			wantMessage: "must be a valid UUID",
		},
		{
			name:        "rejects zero amount",
			input:       []domain.TransactionItemValidationInput{{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6", Amount: 0}},
			repoFn:      noCallValidateFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "amount",
			wantMessage: "must be greater than 0",
		},
		{
			name: "rejects duplicate item ids",
			input: []domain.TransactionItemValidationInput{
				{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6", Amount: 1},
				{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6", Amount: 2},
			},
			repoFn:      noCallValidateFn(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "item_id",
			wantMessage: "must not contain duplicate values",
		},
		{
			name:  "propagates failed precondition from repo",
			input: []domain.TransactionItemValidationInput{{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6", Amount: 999}},
			repoFn: func(ctx context.Context, items []domain.TransactionItemValidationInput) error {
				return pkgerrors.FailedPrecondition("requested amount exceeds available amount")
			},
			wantErr: pkgerrors.ErrFailedPrecondition,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uc := NewItemUsecase(&fakeItemRepo{validateTransactionItemsFn: tt.repoFn})
			err := uc.ValidateTransactionItems(context.Background(), tt.input)

			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("error = %v, want %v", err, tt.wantErr)
				}
				if tt.wantField != "" {
					assertValidationDetail(t, err, tt.wantField, tt.wantMessage)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

// --- no-call helpers ---

func noCallSyncFn(t *testing.T) func(context.Context, []domain.SyncItemInput) error {
	t.Helper()
	return func(ctx context.Context, items []domain.SyncItemInput) error {
		t.Fatalf("SyncItems should not be called")
		return nil
	}
}

func noCallGetItemFn(t *testing.T) func(context.Context, string) (*domain.Item, error) {
	t.Helper()
	return func(ctx context.Context, id string) (*domain.Item, error) {
		t.Fatalf("GetItemByID should not be called")
		return nil, nil
	}
}

func noCallGetSummariesFn(t *testing.T) func(context.Context, []string) ([]*domain.ItemSummary, error) {
	t.Helper()
	return func(ctx context.Context, ids []string) ([]*domain.ItemSummary, error) {
		t.Fatalf("GetItemSummariesByIDs should not be called")
		return nil, nil
	}
}

func noCallValidateFn(t *testing.T) func(context.Context, []domain.TransactionItemValidationInput) error {
	t.Helper()
	return func(ctx context.Context, items []domain.TransactionItemValidationInput) error {
		t.Fatalf("ValidateTransactionItems should not be called")
		return nil
	}
}
