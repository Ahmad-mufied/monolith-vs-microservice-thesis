package grpcserver

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/domain"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/debuglog"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type itemLogRecord struct {
	level slog.Level
	attrs map[string]any
}

type itemCaptureHandler struct {
	mu      sync.Mutex
	records []itemLogRecord
}

func (h *itemCaptureHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *itemCaptureHandler) WithAttrs([]slog.Attr) slog.Handler       { return h }
func (h *itemCaptureHandler) WithGroup(string) slog.Handler            { return h }
func (h *itemCaptureHandler) Handle(_ context.Context, record slog.Record) error {
	attrs := map[string]any{}
	record.Attrs(func(attr slog.Attr) bool {
		attrs[attr.Key] = attr.Value.Any()
		return true
	})

	h.mu.Lock()
	defer h.mu.Unlock()
	h.records = append(h.records, itemLogRecord{level: record.Level, attrs: attrs})
	return nil
}

// --- fake usecase ---

type fakeItemUsecase struct {
	syncItemsFn                func(ctx context.Context, items []domain.SyncItemInput) error
	listItemsFn                func(ctx context.Context, limit, offset int32) ([]*domain.Item, error)
	getItemByIDFn              func(ctx context.Context, itemID string) (*domain.Item, error)
	getItemSummariesByIDsFn    func(ctx context.Context, itemIDs []string) ([]*domain.ItemSummary, error)
	validateTransactionItemsFn func(ctx context.Context, items []domain.TransactionItemValidationInput) error
}

func (f *fakeItemUsecase) SyncItems(ctx context.Context, items []domain.SyncItemInput) error {
	return f.syncItemsFn(ctx, items)
}
func (f *fakeItemUsecase) ListItems(ctx context.Context, limit, offset int32) ([]*domain.Item, error) {
	return f.listItemsFn(ctx, limit, offset)
}
func (f *fakeItemUsecase) GetItemByID(ctx context.Context, itemID string) (*domain.Item, error) {
	return f.getItemByIDFn(ctx, itemID)
}
func (f *fakeItemUsecase) GetItemSummariesByIDs(ctx context.Context, itemIDs []string) ([]*domain.ItemSummary, error) {
	return f.getItemSummariesByIDsFn(ctx, itemIDs)
}
func (f *fakeItemUsecase) ValidateTransactionItems(ctx context.Context, items []domain.TransactionItemValidationInput) error {
	return f.validateTransactionItemsFn(ctx, items)
}

// --- TestSyncItems ---

func TestSyncItems(t *testing.T) {
	tests := []struct {
		name     string
		req      *itemv1.SyncItemsRequest
		ucFn     func(ctx context.Context, items []domain.SyncItemInput) error
		wantCode codes.Code
		wantResp bool
	}{
		{
			name: "maps id and nil id correctly",
			req: &itemv1.SyncItemsRequest{
				Items: []*itemv1.SyncItemInput{
					{Id: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6", Name: "Laptop", AvailableAmount: 10},
					{Name: "Mouse", AvailableAmount: 5},
				},
			},
			ucFn: func(ctx context.Context, items []domain.SyncItemInput) error {
				if len(items) != 2 {
					t.Fatalf("len(items) = %d, want 2", len(items))
				}
				if items[0].ID == nil || *items[0].ID != "01968ad4-98b1-79c8-a6f0-ec21f8f434c6" {
					t.Fatalf("items[0].ID = %v", items[0].ID)
				}
				if items[1].ID != nil {
					t.Fatalf("items[1].ID = %v, want nil", items[1].ID)
				}
				return nil
			},
			wantResp: true,
		},
		{
			name: "maps invalid argument error",
			req:  &itemv1.SyncItemsRequest{},
			ucFn: func(ctx context.Context, items []domain.SyncItemInput) error {
				return pkgerrors.InvalidInput("invalid request payload")
			},
			wantCode: codes.InvalidArgument,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := &ItemServer{uc: &fakeItemUsecase{syncItemsFn: tt.ucFn}}
			resp, err := srv.SyncItems(context.Background(), tt.req)
			if tt.wantCode != codes.OK {
				if status.Code(err) != tt.wantCode {
					t.Fatalf("code = %v, want %v", status.Code(err), tt.wantCode)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.wantResp && resp == nil {
				t.Fatalf("expected non-nil response")
			}
		})
	}
}

// --- TestListItems ---

func TestListItems(t *testing.T) {
	createdAt := time.Date(2026, 5, 10, 9, 0, 0, 0, time.UTC)
	updatedAt := createdAt.Add(2 * time.Hour)

	tests := []struct {
		name          string
		req           *itemv1.ListItemsRequest
		ucFn          func(ctx context.Context, limit, offset int32) ([]*domain.Item, error)
		wantCode      codes.Code
		wantTotal     int32
		wantCreatedAt string
	}{
		{
			name: "maps items and pagination correctly",
			req:  &itemv1.ListItemsRequest{Limit: 10, Offset: 2},
			ucFn: func(ctx context.Context, limit, offset int32) ([]*domain.Item, error) {
				if limit != 10 || offset != 2 {
					t.Fatalf("limit=%d offset=%d, want 10/2", limit, offset)
				}
				return []*domain.Item{{
					ID:              "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
					Name:            "Laptop",
					AvailableAmount: 10,
					CreatedAt:       createdAt,
					UpdatedAt:       updatedAt,
				}}, nil
			},
			wantTotal:     1,
			wantCreatedAt: createdAt.Format(time.RFC3339),
		},
		{
			name: "maps invalid argument error",
			req:  &itemv1.ListItemsRequest{},
			ucFn: func(ctx context.Context, limit, offset int32) ([]*domain.Item, error) {
				return nil, pkgerrors.InvalidInput("invalid request payload")
			},
			wantCode: codes.InvalidArgument,
		},
		{
			name: "maps nil item to internal error",
			req:  &itemv1.ListItemsRequest{Limit: 10, Offset: 0},
			ucFn: func(ctx context.Context, limit, offset int32) ([]*domain.Item, error) {
				return []*domain.Item{nil}, nil
			},
			wantCode: codes.Internal,
		},
	}

	if strconv.IntSize > 32 {
		tests = append(tests, struct {
			name          string
			req           *itemv1.ListItemsRequest
			ucFn          func(ctx context.Context, limit, offset int32) ([]*domain.Item, error)
			wantCode      codes.Code
			wantTotal     int32
			wantCreatedAt string
		}{
			name: "maps overflow to internal error",
			req:  &itemv1.ListItemsRequest{Limit: 10, Offset: 0},
			ucFn: func(ctx context.Context, limit, offset int32) ([]*domain.Item, error) {
				return []*domain.Item{{
					ID:              "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
					Name:            "Laptop",
					AvailableAmount: math.MaxInt32 + 1,
					CreatedAt:       createdAt,
					UpdatedAt:       updatedAt,
				}}, nil
			},
			wantCode: codes.Internal,
		})
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := &ItemServer{uc: &fakeItemUsecase{listItemsFn: tt.ucFn}}
			resp, err := srv.ListItems(context.Background(), tt.req)
			if tt.wantCode != codes.OK {
				if status.Code(err) != tt.wantCode {
					t.Fatalf("code = %v, want %v", status.Code(err), tt.wantCode)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if resp.GetTotalReturned() != tt.wantTotal {
				t.Fatalf("TotalReturned = %d, want %d", resp.GetTotalReturned(), tt.wantTotal)
			}
			if tt.wantCreatedAt != "" && resp.GetItems()[0].GetCreatedAt() != tt.wantCreatedAt {
				t.Fatalf("CreatedAt = %q, want %q", resp.GetItems()[0].GetCreatedAt(), tt.wantCreatedAt)
			}
		})
	}
}

func TestValidateTransactionItemsDiagnosticLogging(t *testing.T) {
	tests := []struct {
		name           string
		ucErr          error
		wantStatusCode string
		wantLevel      slog.Level
	}{
		{
			name:           "resource exhausted logs warn",
			ucErr:          pkgerrors.ResourceExhausted("item service overloaded"),
			wantStatusCode: "ResourceExhausted",
			wantLevel:      slog.LevelWarn,
		},
		{
			name:           "internal logs error",
			ucErr:          pkgerrors.Internal("internal server error", errors.New("boom")),
			wantStatusCode: "Internal",
			wantLevel:      slog.LevelError,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("DIAGNOSTIC_LOGGING_ENABLED", "true")
			debuglog.ResetForTesting()

			handler := &itemCaptureHandler{}
			previous := slog.Default()
			slog.SetDefault(slog.New(handler))
			t.Cleanup(func() {
				slog.SetDefault(previous)
				debuglog.ResetForTesting()
			})

			srv := &ItemServer{
				uc: &fakeItemUsecase{
					validateTransactionItemsFn: func(context.Context, []domain.TransactionItemValidationInput) error {
						return tt.ucErr
					},
				},
			}

			_, err := srv.ValidateTransactionItems(context.Background(), &itemv1.ValidateTransactionItemsRequest{
				Items: []*itemv1.TransactionItemValidationInput{{ItemId: "item-1", Amount: 1}},
			})
			if status.Code(err) == codes.OK {
				t.Fatal("expected error, got nil")
			}

			if len(handler.records) != 1 {
				t.Fatalf("record count = %d, want 1", len(handler.records))
			}

			record := handler.records[0]
			if record.level != tt.wantLevel {
				t.Fatalf("level = %v, want %v", record.level, tt.wantLevel)
			}
			if record.attrs["event"] != "item_validate_transaction_items_grpc_failure" {
				t.Fatalf("event = %v, want item_validate_transaction_items_grpc_failure", record.attrs["event"])
			}
			if record.attrs["grpc_status_code"] != tt.wantStatusCode {
				t.Fatalf("grpc_status_code = %v, want %v", record.attrs["grpc_status_code"], tt.wantStatusCode)
			}
		})
	}
}

// --- TestGetItemById ---

func TestGetItemById(t *testing.T) {
	tests := []struct {
		name     string
		req      *itemv1.GetItemByIdRequest
		ucFn     func(ctx context.Context, itemID string) (*domain.Item, error)
		wantCode codes.Code
		wantName string
	}{
		{
			name: "returns item",
			req:  &itemv1.GetItemByIdRequest{ItemId: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"},
			ucFn: func(ctx context.Context, itemID string) (*domain.Item, error) {
				return &domain.Item{
					ID:        itemID,
					Name:      "Laptop",
					CreatedAt: time.Now(),
					UpdatedAt: time.Now(),
				}, nil
			},
			wantName: "Laptop",
		},
		{
			name: "maps not found error",
			req:  &itemv1.GetItemByIdRequest{ItemId: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"},
			ucFn: func(ctx context.Context, itemID string) (*domain.Item, error) {
				return nil, pkgerrors.NotFound("item not found")
			},
			wantCode: codes.NotFound,
		},
		{
			name: "maps nil item to internal error",
			req:  &itemv1.GetItemByIdRequest{ItemId: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"},
			ucFn: func(ctx context.Context, itemID string) (*domain.Item, error) {
				return nil, nil
			},
			wantCode: codes.Internal,
		},
	}

	if strconv.IntSize > 32 {
		tests = append(tests, struct {
			name     string
			req      *itemv1.GetItemByIdRequest
			ucFn     func(ctx context.Context, itemID string) (*domain.Item, error)
			wantCode codes.Code
			wantName string
		}{
			name: "maps overflow to internal error",
			req:  &itemv1.GetItemByIdRequest{ItemId: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"},
			ucFn: func(ctx context.Context, itemID string) (*domain.Item, error) {
				return &domain.Item{
					ID:              itemID,
					Name:            "Laptop",
					AvailableAmount: math.MaxInt32 + 1,
					CreatedAt:       time.Now(),
					UpdatedAt:       time.Now(),
				}, nil
			},
			wantCode: codes.Internal,
		})
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := &ItemServer{uc: &fakeItemUsecase{getItemByIDFn: tt.ucFn}}
			resp, err := srv.GetItemById(context.Background(), tt.req)
			if tt.wantCode != codes.OK {
				if status.Code(err) != tt.wantCode {
					t.Fatalf("code = %v, want %v", status.Code(err), tt.wantCode)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if resp.GetItem().GetName() != tt.wantName {
				t.Fatalf("Name = %q, want %q", resp.GetItem().GetName(), tt.wantName)
			}
		})
	}
}

// --- TestGetItemSummariesByIds ---

func TestGetItemSummariesByIds(t *testing.T) {
	tests := []struct {
		name        string
		req         *itemv1.GetItemSummariesByIdsRequest
		ucFn        func(ctx context.Context, itemIDs []string) ([]*domain.ItemSummary, error)
		wantCode    codes.Code
		checkResult func(t *testing.T, resp *itemv1.GetItemSummariesByIdsResponse)
	}{
		{
			name: "maps deleted flag correctly",
			req: &itemv1.GetItemSummariesByIdsRequest{
				ItemIds: []string{
					"01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
					"01968ad4-98b1-79c8-a6f0-ec21f8f434c7",
				},
			},
			ucFn: func(ctx context.Context, itemIDs []string) ([]*domain.ItemSummary, error) {
				return []*domain.ItemSummary{
					{ID: itemIDs[0], Name: "Laptop", Deleted: false},
					{ID: itemIDs[1], Name: "Mouse", Deleted: true},
				}, nil
			},
			checkResult: func(t *testing.T, resp *itemv1.GetItemSummariesByIdsResponse) {
				if len(resp.GetItems()) != 2 || !resp.GetItems()[1].GetDeleted() {
					t.Fatalf("resp.Items = %#v, want deleted=true on second item", resp.GetItems())
				}
			},
		},
		{
			name: "maps invalid argument error",
			req:  &itemv1.GetItemSummariesByIdsRequest{ItemIds: []string{"bad-id"}},
			ucFn: func(ctx context.Context, itemIDs []string) ([]*domain.ItemSummary, error) {
				return nil, pkgerrors.InvalidInput("invalid request payload")
			},
			wantCode: codes.InvalidArgument,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := &ItemServer{uc: &fakeItemUsecase{getItemSummariesByIDsFn: tt.ucFn}}
			resp, err := srv.GetItemSummariesByIds(context.Background(), tt.req)
			if tt.wantCode != codes.OK {
				if status.Code(err) != tt.wantCode {
					t.Fatalf("code = %v, want %v", status.Code(err), tt.wantCode)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.checkResult != nil {
				tt.checkResult(t, resp)
			}
		})
	}
}

// --- TestValidateTransactionItems ---

func TestValidateTransactionItems(t *testing.T) {
	tests := []struct {
		name     string
		req      *itemv1.ValidateTransactionItemsRequest
		ucFn     func(ctx context.Context, items []domain.TransactionItemValidationInput) error
		wantCode codes.Code
	}{
		{
			name: "maps request and returns success",
			req: &itemv1.ValidateTransactionItemsRequest{
				Items: []*itemv1.TransactionItemValidationInput{
					{ItemId: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6", Amount: 2},
				},
			},
			ucFn: func(ctx context.Context, items []domain.TransactionItemValidationInput) error {
				if len(items) != 1 || items[0].ItemID != "01968ad4-98b1-79c8-a6f0-ec21f8f434c6" || items[0].Amount != 2 {
					t.Fatalf("items = %#v", items)
				}
				return nil
			},
		},
		{
			name: "maps failed precondition error",
			req:  &itemv1.ValidateTransactionItemsRequest{},
			ucFn: func(ctx context.Context, items []domain.TransactionItemValidationInput) error {
				return pkgerrors.FailedPrecondition("requested amount exceeds available amount")
			},
			wantCode: codes.FailedPrecondition,
		},
		{
			name: "maps not found error",
			req:  &itemv1.ValidateTransactionItemsRequest{},
			ucFn: func(ctx context.Context, items []domain.TransactionItemValidationInput) error {
				return pkgerrors.NotFound("item not found")
			},
			wantCode: codes.NotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := &ItemServer{uc: &fakeItemUsecase{validateTransactionItemsFn: tt.ucFn}}
			resp, err := srv.ValidateTransactionItems(context.Background(), tt.req)
			if tt.wantCode != codes.OK {
				if status.Code(err) != tt.wantCode {
					t.Fatalf("code = %v, want %v", status.Code(err), tt.wantCode)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if resp == nil {
				t.Fatalf("expected non-nil response")
			}
		})
	}
}
