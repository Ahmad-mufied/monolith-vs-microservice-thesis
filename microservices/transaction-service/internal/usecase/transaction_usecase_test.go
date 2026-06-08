package usecase

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/port"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
)

type fakeTransactionRepository struct {
	beginTxFn                 func(ctx context.Context) (port.TransactionWriteTx, error)
	listByUserIDFn            func(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error)
	getByIDAndUserIDFn        func(ctx context.Context, transactionID, userID string) (*domain.Transaction, error)
	listForEnrichmentFn       func(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error)
	listItemsByTransactionIDs func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error)
}

func (f *fakeTransactionRepository) BeginTx(ctx context.Context) (port.TransactionWriteTx, error) {
	return f.beginTxFn(ctx)
}

func (f *fakeTransactionRepository) ListByUserID(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
	return f.listByUserIDFn(ctx, userID, limit, offset)
}

func (f *fakeTransactionRepository) GetByIDAndUserID(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
	return f.getByIDAndUserIDFn(ctx, transactionID, userID)
}

func (f *fakeTransactionRepository) ListForEnrichment(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
	return f.listForEnrichmentFn(ctx, limit, offset)
}

func (f *fakeTransactionRepository) ListItemsByTransactionIDs(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
	return f.listItemsByTransactionIDs(ctx, transactionIDs)
}

type fakeTransactionWriteTx struct {
	insertTransactionFn      func(ctx context.Context, userID string) (string, error)
	insertTransactionItemsFn func(ctx context.Context, transactionID string, items []domain.TransactionItem) error
	commitFn                 func(ctx context.Context) error
	rollbackFn               func() error
}

func (f *fakeTransactionWriteTx) InsertTransaction(ctx context.Context, userID string) (string, error) {
	return f.insertTransactionFn(ctx, userID)
}

func (f *fakeTransactionWriteTx) InsertTransactionItems(ctx context.Context, transactionID string, items []domain.TransactionItem) error {
	return f.insertTransactionItemsFn(ctx, transactionID, items)
}

func (f *fakeTransactionWriteTx) Commit(ctx context.Context) error {
	return f.commitFn(ctx)
}

func (f *fakeTransactionWriteTx) Rollback() error {
	return f.rollbackFn()
}

type fakeItemService struct {
	validateTransactionItemsFn func(ctx context.Context, items []domain.TransactionItem) error
}

func (f *fakeItemService) ValidateTransactionItems(ctx context.Context, items []domain.TransactionItem) error {
	return f.validateTransactionItemsFn(ctx, items)
}

func TestTransactionUsecase_CreateTransaction(t *testing.T) {
	validUserID := "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"
	validItemID1 := "01968ad4-98b1-79c8-a6f0-ec21f8f434c7"
	validItemID2 := "01968ad4-98b1-79c8-a6f0-ec21f8f434c8"
	upperUserID := "01968AD4-98B1-79C8-A6F0-EC21F8F434C6"
	upperItemID := "01968AD4-98B1-79C8-A6F0-EC21F8F434C7"

	noCallRepo := &fakeTransactionRepository{
		beginTxFn: func(ctx context.Context) (port.TransactionWriteTx, error) {
			t.Fatalf("BeginTx should not be called")
			return nil, nil
		},
	}

	tests := []struct {
		name        string
		userID      string
		items       []domain.TransactionItem
		itemSvcFn   func(ctx context.Context, items []domain.TransactionItem) error
		repo        *fakeTransactionRepository
		wantErr     error
		wantField   string
		wantMessage string
		wantID      string
	}{
		{
			name:   "success",
			userID: validUserID,
			items: []domain.TransactionItem{
				{ItemID: validItemID1, Amount: 2},
				{ItemID: validItemID2, Amount: 1},
			},
			itemSvcFn: func(ctx context.Context, items []domain.TransactionItem) error { return nil },
			repo: &fakeTransactionRepository{
				beginTxFn: func(ctx context.Context) (port.TransactionWriteTx, error) {
					return &fakeTransactionWriteTx{
						insertTransactionFn: func(ctx context.Context, userID string) (string, error) {
							if userID != validUserID {
								t.Fatalf("userID = %q, want %q", userID, validUserID)
							}
							return "01968ad4-98b1-79c8-a6f0-ec21f8f434d0", nil
						},
						insertTransactionItemsFn: func(ctx context.Context, transactionID string, items []domain.TransactionItem) error {
							if transactionID == "" || len(items) != 2 {
								t.Fatalf("unexpected insert items input: %#v", items)
							}
							return nil
						},
						commitFn:   func(ctx context.Context) error { return nil },
						rollbackFn: func() error { return nil },
					}, nil
				},
			},
			wantID: "01968ad4-98b1-79c8-a6f0-ec21f8f434d0",
		},
		{
			name:   "normalize uppercase uuid",
			userID: upperUserID,
			items:  []domain.TransactionItem{{ItemID: upperItemID, Amount: 1}},
			itemSvcFn: func(ctx context.Context, items []domain.TransactionItem) error {
				if items[0].ItemID != validItemID1 {
					t.Fatalf("normalized item id = %q, want %q", items[0].ItemID, validItemID1)
				}
				if _, ok := ctx.Deadline(); !ok {
					t.Fatalf("expected deadline on upstream validation context")
				}
				return nil
			},
			repo: &fakeTransactionRepository{
				beginTxFn: func(ctx context.Context) (port.TransactionWriteTx, error) {
					return &fakeTransactionWriteTx{
						insertTransactionFn: func(ctx context.Context, userID string) (string, error) {
							if userID != validUserID {
								t.Fatalf("normalized userID = %q, want %q", userID, validUserID)
							}
							return "01968ad4-98b1-79c8-a6f0-ec21f8f434d1", nil
						},
						insertTransactionItemsFn: func(ctx context.Context, transactionID string, items []domain.TransactionItem) error {
							if items[0].ItemID != validItemID1 {
								t.Fatalf("normalized item id = %q, want %q", items[0].ItemID, validItemID1)
							}
							return nil
						},
						commitFn:   func(ctx context.Context) error { return nil },
						rollbackFn: func() error { return nil },
					}, nil
				},
			},
			wantID: "01968ad4-98b1-79c8-a6f0-ec21f8f434d1",
		},
		{
			name:        "invalid user_id",
			userID:      "bad-id",
			items:       []domain.TransactionItem{{ItemID: validItemID1, Amount: 1}},
			itemSvcFn:   noCallItemService(t),
			repo:        noCallRepo,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "user_id",
			wantMessage: "must be a valid UUID",
		},
		{
			name:        "empty items",
			userID:      validUserID,
			itemSvcFn:   noCallItemService(t),
			repo:        noCallRepo,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "items",
			wantMessage: "is required",
		},
		{
			name:        "item count over 20",
			userID:      validUserID,
			items:       repeatItems(validItemID1, 21),
			itemSvcFn:   noCallItemService(t),
			repo:        noCallRepo,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "items",
			wantMessage: "must contain at most 20 items",
		},
		{
			name:        "invalid item_id",
			userID:      validUserID,
			items:       []domain.TransactionItem{{ItemID: "bad-id", Amount: 1}},
			itemSvcFn:   noCallItemService(t),
			repo:        noCallRepo,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "item_id",
			wantMessage: "must be a valid UUID",
		},
		{
			name:        "amount zero",
			userID:      validUserID,
			items:       []domain.TransactionItem{{ItemID: validItemID1, Amount: 0}},
			itemSvcFn:   noCallItemService(t),
			repo:        noCallRepo,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "amount",
			wantMessage: "must be greater than 0",
		},
		{
			name:        "amount negative",
			userID:      validUserID,
			items:       []domain.TransactionItem{{ItemID: validItemID1, Amount: -1}},
			itemSvcFn:   noCallItemService(t),
			repo:        noCallRepo,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "amount",
			wantMessage: "must be greater than 0",
		},
		{
			name:   "duplicate item_id",
			userID: validUserID,
			items: []domain.TransactionItem{
				{ItemID: validItemID1, Amount: 1},
				{ItemID: validItemID1, Amount: 2},
			},
			itemSvcFn:   noCallItemService(t),
			repo:        noCallRepo,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "item_id",
			wantMessage: "must not contain duplicate values",
		},
		{
			name:   "duplicate item_id different case",
			userID: validUserID,
			items: []domain.TransactionItem{
				{ItemID: validItemID1, Amount: 1},
				{ItemID: upperItemID, Amount: 2},
			},
			itemSvcFn:   noCallItemService(t),
			repo:        noCallRepo,
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "item_id",
			wantMessage: "must not contain duplicate values",
		},
		{
			name:   "item service not found",
			userID: validUserID,
			items:  []domain.TransactionItem{{ItemID: validItemID1, Amount: 1}},
			itemSvcFn: func(ctx context.Context, items []domain.TransactionItem) error {
				return pkgerrors.NotFound("item not found")
			},
			repo:    noCallRepo,
			wantErr: pkgerrors.ErrNotFound,
		},
		{
			name:   "item service failed precondition",
			userID: validUserID,
			items:  []domain.TransactionItem{{ItemID: validItemID1, Amount: 1}},
			itemSvcFn: func(ctx context.Context, items []domain.TransactionItem) error {
				return pkgerrors.FailedPrecondition("requested amount exceeds available amount")
			},
			repo:    noCallRepo,
			wantErr: pkgerrors.ErrFailedPrecondition,
		},
		{
			name:   "item service unavailable",
			userID: validUserID,
			items:  []domain.TransactionItem{{ItemID: validItemID1, Amount: 1}},
			itemSvcFn: func(ctx context.Context, items []domain.TransactionItem) error {
				return pkgerrors.Unavailable("item service unavailable")
			},
			repo:    noCallRepo,
			wantErr: pkgerrors.ErrUnavailable,
		},
		{
			name:      "repo insert transaction fails",
			userID:    validUserID,
			items:     []domain.TransactionItem{{ItemID: validItemID1, Amount: 1}},
			itemSvcFn: func(ctx context.Context, items []domain.TransactionItem) error { return nil },
			repo: &fakeTransactionRepository{
				beginTxFn: func(ctx context.Context) (port.TransactionWriteTx, error) {
					return &fakeTransactionWriteTx{
						insertTransactionFn: func(ctx context.Context, userID string) (string, error) {
							return "", pkgerrors.Internal("internal server error", errors.New("insert transaction"))
						},
						insertTransactionItemsFn: func(ctx context.Context, transactionID string, items []domain.TransactionItem) error { return nil },
						commitFn:                 func(ctx context.Context) error { return nil },
						rollbackFn:               func() error { return nil },
					}, nil
				},
			},
			wantErr: pkgerrors.ErrInternal,
		},
		{
			name:      "repo insert item fails",
			userID:    validUserID,
			items:     []domain.TransactionItem{{ItemID: validItemID1, Amount: 1}},
			itemSvcFn: func(ctx context.Context, items []domain.TransactionItem) error { return nil },
			repo: &fakeTransactionRepository{
				beginTxFn: func(ctx context.Context) (port.TransactionWriteTx, error) {
					return &fakeTransactionWriteTx{
						insertTransactionFn: func(ctx context.Context, userID string) (string, error) {
							return "01968ad4-98b1-79c8-a6f0-ec21f8f434d2", nil
						},
						insertTransactionItemsFn: func(ctx context.Context, transactionID string, items []domain.TransactionItem) error {
							return pkgerrors.Internal("internal server error", errors.New("insert items"))
						},
						commitFn:   func(ctx context.Context) error { return nil },
						rollbackFn: func() error { return nil },
					}, nil
				},
			},
			wantErr: pkgerrors.ErrInternal,
		},
		{
			name:      "commit fails",
			userID:    validUserID,
			items:     []domain.TransactionItem{{ItemID: validItemID1, Amount: 1}},
			itemSvcFn: func(ctx context.Context, items []domain.TransactionItem) error { return nil },
			repo: &fakeTransactionRepository{
				beginTxFn: func(ctx context.Context) (port.TransactionWriteTx, error) {
					return &fakeTransactionWriteTx{
						insertTransactionFn: func(ctx context.Context, userID string) (string, error) {
							return "01968ad4-98b1-79c8-a6f0-ec21f8f434d3", nil
						},
						insertTransactionItemsFn: func(ctx context.Context, transactionID string, items []domain.TransactionItem) error { return nil },
						commitFn: func(ctx context.Context) error {
							return pkgerrors.Internal("internal server error", errors.New("commit"))
						},
						rollbackFn: func() error { return nil },
					}, nil
				},
			},
			wantErr: pkgerrors.ErrInternal,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uc := NewTransactionUsecase(tt.repo, &fakeItemService{validateTransactionItemsFn: tt.itemSvcFn}, 5*time.Second)
			gotID, err := uc.CreateTransaction(context.Background(), tt.userID, tt.items)

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
			if gotID != tt.wantID {
				t.Fatalf("transactionID = %q, want %q", gotID, tt.wantID)
			}
		})
	}
}

func TestTransactionUsecaseCreateContextCanceledBeforeItemService(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	uc := NewTransactionUsecase(noListRepo(t), &fakeItemService{
		validateTransactionItemsFn: noCallItemService(t),
	}, 5*time.Second)

	_, err := uc.CreateTransaction(ctx, "01968ad4-98b1-79c8-a6f0-ec21f8f434c6", []domain.TransactionItem{
		{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c7", Amount: 1},
	})
	if !errors.Is(err, pkgerrors.ErrCanceled) {
		t.Fatalf("error = %v, want ErrCanceled", err)
	}
}

func TestTransactionUsecase_GetOwnTransactions(t *testing.T) {
	validUserID := "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"
	transactionID := "01968ad4-98b1-79c8-a6f0-ec21f8f434d0"
	createdAt := time.Date(2026, 5, 11, 8, 0, 0, 0, time.UTC)

	tests := []struct {
		name        string
		userID      string
		limit       int32
		offset      int32
		repo        *fakeTransactionRepository
		wantErr     error
		wantField   string
		wantMessage string
		wantLen     int
	}{
		{
			name:   "success default pagination",
			userID: validUserID,
			repo: &fakeTransactionRepository{
				listByUserIDFn: func(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
					if userID != validUserID || limit != defaultListLimit || offset != 0 {
						t.Fatalf("unexpected pagination args: userID=%q limit=%d offset=%d", userID, limit, offset)
					}
					return []*domain.Transaction{{
						ID:        transactionID,
						UserID:    userID,
						CreatedAt: createdAt,
						UpdatedAt: createdAt,
					}}, nil
				},
				listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
					return map[string][]domain.TransactionItem{
						transactionID: {{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c7", Amount: 2}},
					}, nil
				},
			},
			wantLen: 1,
		},
		{
			name:        "invalid user_id",
			userID:      "bad-id",
			repo:        noListRepo(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "user_id",
			wantMessage: "must be a valid UUID",
		},
		{
			name:        "invalid limit",
			userID:      validUserID,
			limit:       101,
			repo:        noListRepo(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "limit",
			wantMessage: "must be less than or equal to 100",
		},
		{
			name:        "invalid offset",
			userID:      validUserID,
			limit:       10,
			offset:      -1,
			repo:        noListRepo(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "offset",
			wantMessage: "must be greater than or equal to 0",
		},
		{
			name:   "empty result",
			userID: validUserID,
			repo: &fakeTransactionRepository{
				listByUserIDFn: func(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
					return []*domain.Transaction{}, nil
				},
				listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
					t.Fatalf("ListItemsByTransactionIDs should not be called")
					return nil, nil
				},
			},
		},
		{
			name:   "repo error",
			userID: validUserID,
			repo: &fakeTransactionRepository{
				listByUserIDFn: func(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
					return nil, pkgerrors.Internal("internal server error", errors.New("list"))
				},
				listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
					return nil, nil
				},
			},
			wantErr: pkgerrors.ErrInternal,
		},
	}

	uc := NewTransactionUsecase(nil, nil, 5*time.Second)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uc.repo = tt.repo
			got, err := uc.GetOwnTransactions(context.Background(), tt.userID, tt.limit, tt.offset)
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
			if len(got) != tt.wantLen {
				t.Fatalf("len(transactions) = %d, want %d", len(got), tt.wantLen)
			}
		})
	}
}

func TestTransactionUsecase_GetTransactionByID(t *testing.T) {
	validUserID := "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"
	validTransactionID := "01968ad4-98b1-79c8-a6f0-ec21f8f434d0"

	tests := []struct {
		name          string
		transactionID string
		userID        string
		repo          *fakeTransactionRepository
		wantErr       error
		wantField     string
		wantMessage   string
		wantItemCount int
	}{
		{
			name:          "success",
			transactionID: validTransactionID,
			userID:        validUserID,
			repo: &fakeTransactionRepository{
				getByIDAndUserIDFn: func(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
					return &domain.Transaction{ID: transactionID, UserID: userID}, nil
				},
				listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
					return map[string][]domain.TransactionItem{
						validTransactionID: {{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c7", Amount: 2}},
					}, nil
				},
			},
			wantItemCount: 1,
		},
		{
			name:          "invalid user_id",
			transactionID: validTransactionID,
			userID:        "bad-id",
			repo:          noGetRepo(t),
			wantErr:       pkgerrors.ErrInvalidInput,
			wantField:     "user_id",
			wantMessage:   "must be a valid UUID",
		},
		{
			name:          "invalid transaction_id",
			transactionID: "bad-id",
			userID:        validUserID,
			repo:          noGetRepo(t),
			wantErr:       pkgerrors.ErrInvalidInput,
			wantField:     "transaction_id",
			wantMessage:   "must be a valid UUID",
		},
		{
			name:          "not found",
			transactionID: validTransactionID,
			userID:        validUserID,
			repo: &fakeTransactionRepository{
				getByIDAndUserIDFn: func(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
					return nil, pkgerrors.NotFound("transaction not found")
				},
				listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
					return nil, nil
				},
			},
			wantErr: pkgerrors.ErrNotFound,
		},
		{
			name:          "repo error",
			transactionID: validTransactionID,
			userID:        validUserID,
			repo: &fakeTransactionRepository{
				getByIDAndUserIDFn: func(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
					return nil, pkgerrors.Internal("internal server error", errors.New("get"))
				},
				listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
					return nil, nil
				},
			},
			wantErr: pkgerrors.ErrInternal,
		},
	}

	uc := NewTransactionUsecase(nil, nil, 5*time.Second)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uc.repo = tt.repo
			got, err := uc.GetTransactionByID(context.Background(), tt.transactionID, tt.userID)
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
			if len(got.Items) != tt.wantItemCount {
				t.Fatalf("len(items) = %d, want %d", len(got.Items), tt.wantItemCount)
			}
		})
	}
}

func TestTransactionUsecase_GetTransactionsForEnrichment(t *testing.T) {
	transactionID := "01968ad4-98b1-79c8-a6f0-ec21f8f434d0"

	tests := []struct {
		name        string
		limit       int32
		offset      int32
		repo        *fakeTransactionRepository
		wantErr     error
		wantField   string
		wantMessage string
		wantLen     int
	}{
		{
			name: "success",
			repo: &fakeTransactionRepository{
				listForEnrichmentFn: func(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
					if limit != defaultListLimit || offset != 0 {
						t.Fatalf("limit=%d offset=%d, want %d/%d", limit, offset, defaultListLimit, 0)
					}
					return []*domain.Transaction{{ID: transactionID, UserID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"}}, nil
				},
				listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
					return map[string][]domain.TransactionItem{
						transactionID: {{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c7", Amount: 1}},
					}, nil
				},
			},
			wantLen: 1,
		},
		{
			name:        "invalid limit",
			limit:       101,
			repo:        noEnrichmentRepo(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "limit",
			wantMessage: "must be less than or equal to 100",
		},
		{
			name:        "invalid offset",
			limit:       10,
			offset:      -1,
			repo:        noEnrichmentRepo(t),
			wantErr:     pkgerrors.ErrInvalidInput,
			wantField:   "offset",
			wantMessage: "must be greater than or equal to 0",
		},
		{
			name: "empty result",
			repo: &fakeTransactionRepository{
				listForEnrichmentFn: func(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
					return []*domain.Transaction{}, nil
				},
				listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
					t.Fatalf("ListItemsByTransactionIDs should not be called")
					return nil, nil
				},
			},
		},
		{
			name: "repo error",
			repo: &fakeTransactionRepository{
				listForEnrichmentFn: func(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
					return nil, pkgerrors.Internal("internal server error", errors.New("list"))
				},
				listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
					return nil, nil
				},
			},
			wantErr: pkgerrors.ErrInternal,
		},
	}

	uc := NewTransactionUsecase(nil, nil, 5*time.Second)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uc.repo = tt.repo
			got, err := uc.GetTransactionsForEnrichment(context.Background(), tt.limit, tt.offset)
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
			if len(got) != tt.wantLen {
				t.Fatalf("len(transactions) = %d, want %d", len(got), tt.wantLen)
			}
		})
	}
}

func assertValidationDetail(t *testing.T, err error, wantField, wantMessage string) {
	t.Helper()
	var detailedErr interface{ PublicDetails() map[string]string }
	if !errors.As(err, &detailedErr) {
		t.Fatalf("expected validation detail error, got %v", err)
	}
	details := detailedErr.PublicDetails()
	if gotMessage := details[wantField]; gotMessage != wantMessage {
		t.Fatalf("details[%q] = %q, want %q", wantField, gotMessage, wantMessage)
	}
}

func noCallItemService(t *testing.T) func(ctx context.Context, items []domain.TransactionItem) error {
	t.Helper()
	return func(ctx context.Context, items []domain.TransactionItem) error {
		t.Fatalf("item service should not be called")
		return nil
	}
}

func noListRepo(t *testing.T) *fakeTransactionRepository {
	t.Helper()
	return &fakeTransactionRepository{
		listByUserIDFn: func(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
			t.Fatalf("ListByUserID should not be called")
			return nil, nil
		},
		listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
			t.Fatalf("ListItemsByTransactionIDs should not be called")
			return nil, nil
		},
	}
}

func noGetRepo(t *testing.T) *fakeTransactionRepository {
	t.Helper()
	return &fakeTransactionRepository{
		getByIDAndUserIDFn: func(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
			t.Fatalf("GetByIDAndUserID should not be called")
			return nil, nil
		},
		listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
			t.Fatalf("ListItemsByTransactionIDs should not be called")
			return nil, nil
		},
	}
}

func noEnrichmentRepo(t *testing.T) *fakeTransactionRepository {
	t.Helper()
	return &fakeTransactionRepository{
		listForEnrichmentFn: func(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
			t.Fatalf("ListForEnrichment should not be called")
			return nil, nil
		},
		listItemsByTransactionIDs: func(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
			t.Fatalf("ListItemsByTransactionIDs should not be called")
			return nil, nil
		},
	}
}

func repeatItems(itemID string, count int) []domain.TransactionItem {
	items := make([]domain.TransactionItem, 0, count)
	for range count {
		items = append(items, domain.TransactionItem{
			ItemID: itemID,
			Amount: 1,
		})
	}
	return items
}
