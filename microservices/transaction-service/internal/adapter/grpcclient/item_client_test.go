package grpcclient

import (
	"context"
	"log/slog"
	"sync"
	"testing"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/debuglog"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type fakeItemServiceClient struct {
	validateFn func(ctx context.Context, in *itemv1.ValidateTransactionItemsRequest, opts ...grpc.CallOption) (*itemv1.ValidateTransactionItemsResponse, error)
}

func (f *fakeItemServiceClient) SyncItems(context.Context, *itemv1.SyncItemsRequest, ...grpc.CallOption) (*itemv1.SyncItemsResponse, error) {
	return nil, status.Error(codes.Unimplemented, "not implemented")
}

func (f *fakeItemServiceClient) ListItems(context.Context, *itemv1.ListItemsRequest, ...grpc.CallOption) (*itemv1.ListItemsResponse, error) {
	return nil, status.Error(codes.Unimplemented, "not implemented")
}

func (f *fakeItemServiceClient) GetItemById(context.Context, *itemv1.GetItemByIdRequest, ...grpc.CallOption) (*itemv1.GetItemByIdResponse, error) {
	return nil, status.Error(codes.Unimplemented, "not implemented")
}

func (f *fakeItemServiceClient) GetItemSummariesByIds(context.Context, *itemv1.GetItemSummariesByIdsRequest, ...grpc.CallOption) (*itemv1.GetItemSummariesByIdsResponse, error) {
	return nil, status.Error(codes.Unimplemented, "not implemented")
}

func (f *fakeItemServiceClient) ValidateTransactionItems(ctx context.Context, in *itemv1.ValidateTransactionItemsRequest, opts ...grpc.CallOption) (*itemv1.ValidateTransactionItemsResponse, error) {
	return f.validateFn(ctx, in, opts...)
}

type transactionClientLogRecord struct {
	level slog.Level
	attrs map[string]any
}

type transactionClientCaptureHandler struct {
	mu      sync.Mutex
	records []transactionClientLogRecord
}

func (h *transactionClientCaptureHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *transactionClientCaptureHandler) WithAttrs([]slog.Attr) slog.Handler       { return h }
func (h *transactionClientCaptureHandler) WithGroup(string) slog.Handler            { return h }
func (h *transactionClientCaptureHandler) Handle(_ context.Context, record slog.Record) error {
	attrs := map[string]any{}
	record.Attrs(func(attr slog.Attr) bool {
		attrs[attr.Key] = attr.Value.Any()
		return true
	})

	h.mu.Lock()
	defer h.mu.Unlock()
	h.records = append(h.records, transactionClientLogRecord{level: record.Level, attrs: attrs})
	return nil
}

func TestItemClientValidateTransactionItemsDiagnosticLogging(t *testing.T) {
	tests := []struct {
		name           string
		grpcErr        error
		wantStatusCode string
		wantLevel      slog.Level
	}{
		{
			name:           "deadline exceeded logs warn",
			grpcErr:        status.Error(codes.DeadlineExceeded, "request timeout"),
			wantStatusCode: "DeadlineExceeded",
			wantLevel:      slog.LevelWarn,
		},
		{
			name:           "internal logs error",
			grpcErr:        status.Error(codes.Internal, "boom"),
			wantStatusCode: "Internal",
			wantLevel:      slog.LevelError,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("DIAGNOSTIC_LOGGING_ENABLED", "true")
			debuglog.ResetForTesting()

			handler := &transactionClientCaptureHandler{}
			previous := slog.Default()
			slog.SetDefault(slog.New(handler))
			t.Cleanup(func() {
				slog.SetDefault(previous)
				debuglog.ResetForTesting()
			})

			client := NewItemClient(&fakeItemServiceClient{
				validateFn: func(context.Context, *itemv1.ValidateTransactionItemsRequest, ...grpc.CallOption) (*itemv1.ValidateTransactionItemsResponse, error) {
					return nil, tt.grpcErr
				},
			})

			err := client.ValidateTransactionItems(context.Background(), []domain.TransactionItem{{ItemID: "item-1", Amount: 1}})
			if err == nil {
				t.Fatal("expected error, got nil")
			}

			if len(handler.records) != 1 {
				t.Fatalf("record count = %d, want 1", len(handler.records))
			}

			record := handler.records[0]
			if record.level != tt.wantLevel {
				t.Fatalf("level = %v, want %v", record.level, tt.wantLevel)
			}
			if record.attrs["event"] != "transaction_item_validate_rpc_failure" {
				t.Fatalf("event = %v, want transaction_item_validate_rpc_failure", record.attrs["event"])
			}
			if record.attrs["grpc_status_code"] != tt.wantStatusCode {
				t.Fatalf("grpc_status_code = %v, want %v", record.attrs["grpc_status_code"], tt.wantStatusCode)
			}
		})
	}
}
