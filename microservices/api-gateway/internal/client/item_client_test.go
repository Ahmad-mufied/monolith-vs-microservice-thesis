package client

import (
	"context"
	"net/http"
	"testing"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type fakeItemServiceClient struct {
	syncItemsFn                func(ctx context.Context, in *itemv1.SyncItemsRequest, opts ...grpc.CallOption) (*itemv1.SyncItemsResponse, error)
	listItemsFn                func(ctx context.Context, in *itemv1.ListItemsRequest, opts ...grpc.CallOption) (*itemv1.ListItemsResponse, error)
	getItemByIdFn              func(ctx context.Context, in *itemv1.GetItemByIdRequest, opts ...grpc.CallOption) (*itemv1.GetItemByIdResponse, error)
	getItemSummariesByIdsFn    func(ctx context.Context, in *itemv1.GetItemSummariesByIdsRequest, opts ...grpc.CallOption) (*itemv1.GetItemSummariesByIdsResponse, error)
	validateTransactionItemsFn func(ctx context.Context, in *itemv1.ValidateTransactionItemsRequest, opts ...grpc.CallOption) (*itemv1.ValidateTransactionItemsResponse, error)
}

func (f *fakeItemServiceClient) SyncItems(ctx context.Context, in *itemv1.SyncItemsRequest, opts ...grpc.CallOption) (*itemv1.SyncItemsResponse, error) {
	return f.syncItemsFn(ctx, in, opts...)
}
func (f *fakeItemServiceClient) ListItems(ctx context.Context, in *itemv1.ListItemsRequest, opts ...grpc.CallOption) (*itemv1.ListItemsResponse, error) {
	return f.listItemsFn(ctx, in, opts...)
}
func (f *fakeItemServiceClient) GetItemById(ctx context.Context, in *itemv1.GetItemByIdRequest, opts ...grpc.CallOption) (*itemv1.GetItemByIdResponse, error) {
	return f.getItemByIdFn(ctx, in, opts...)
}
func (f *fakeItemServiceClient) GetItemSummariesByIds(ctx context.Context, in *itemv1.GetItemSummariesByIdsRequest, opts ...grpc.CallOption) (*itemv1.GetItemSummariesByIdsResponse, error) {
	return f.getItemSummariesByIdsFn(ctx, in, opts...)
}
func (f *fakeItemServiceClient) ValidateTransactionItems(ctx context.Context, in *itemv1.ValidateTransactionItemsRequest, opts ...grpc.CallOption) (*itemv1.ValidateTransactionItemsResponse, error) {
	return f.validateTransactionItemsFn(ctx, in, opts...)
}

func TestItemClient_SyncItems(t *testing.T) {
	tests := []struct {
		name       string
		grpcErr    error
		wantStatus int
	}{
		{name: "success", grpcErr: nil},
		{name: "AlreadyExists -> 409", grpcErr: status.Error(codes.AlreadyExists, "conflict"), wantStatus: http.StatusConflict},
		{name: "Unavailable -> 503", grpcErr: status.Error(codes.Unavailable, "down"), wantStatus: http.StatusServiceUnavailable},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeItemServiceClient{
				syncItemsFn: func(_ context.Context, _ *itemv1.SyncItemsRequest, _ ...grpc.CallOption) (*itemv1.SyncItemsResponse, error) {
					return &itemv1.SyncItemsResponse{}, tt.grpcErr
				},
			}
			c := NewItemClient(fake)
			err := c.SyncItems(context.Background(), nil)
			assertClientError(t, err, tt.wantStatus)
		})
	}
}

func TestItemClient_ListItems(t *testing.T) {
	tests := []struct {
		name       string
		grpcResp   *itemv1.ListItemsResponse
		grpcErr    error
		wantStatus int
		wantLen    int
	}{
		{
			name: "success maps items",
			grpcResp: &itemv1.ListItemsResponse{
				Items: []*itemv1.Item{
					{Id: "iid-1", Name: "Item A", AvailableAmount: 100, CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z"},
				},
				TotalReturned: 1,
			},
			wantLen: 1,
		},
		{name: "Unavailable -> 503", grpcErr: status.Error(codes.Unavailable, "down"), wantStatus: http.StatusServiceUnavailable},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeItemServiceClient{
				listItemsFn: func(_ context.Context, _ *itemv1.ListItemsRequest, _ ...grpc.CallOption) (*itemv1.ListItemsResponse, error) {
					return tt.grpcResp, tt.grpcErr
				},
			}
			c := NewItemClient(fake)
			items, err := c.ListItems(context.Background(), 50, 0)
			if tt.wantStatus != 0 {
				assertClientError(t, err, tt.wantStatus)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(items) != tt.wantLen {
				t.Errorf("len = %d, want %d", len(items), tt.wantLen)
			}
		})
	}
}

func TestItemClient_GetItemByID(t *testing.T) {
	tests := []struct {
		name       string
		grpcResp   *itemv1.GetItemByIdResponse
		grpcErr    error
		wantStatus int
		wantName   string
	}{
		{
			name:     "success",
			grpcResp: &itemv1.GetItemByIdResponse{Item: &itemv1.Item{Id: "iid-1", Name: "Item A", CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z"}},
			wantName: "Item A",
		},
		{name: "NotFound -> 404", grpcErr: status.Error(codes.NotFound, "not found"), wantStatus: http.StatusNotFound},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeItemServiceClient{
				getItemByIdFn: func(_ context.Context, _ *itemv1.GetItemByIdRequest, _ ...grpc.CallOption) (*itemv1.GetItemByIdResponse, error) {
					return tt.grpcResp, tt.grpcErr
				},
			}
			c := NewItemClient(fake)
			item, err := c.GetItemByID(context.Background(), "iid-1")
			if tt.wantStatus != 0 {
				assertClientError(t, err, tt.wantStatus)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if item.Name != tt.wantName {
				t.Errorf("Name = %q, want %q", item.Name, tt.wantName)
			}
		})
	}
}

func TestItemClient_GetItemSummariesByIDs(t *testing.T) {
	tests := []struct {
		name       string
		grpcResp   *itemv1.GetItemSummariesByIdsResponse
		grpcErr    error
		wantStatus int
		wantLen    int
	}{
		{
			name: "success includes deleted flag",
			grpcResp: &itemv1.GetItemSummariesByIdsResponse{
				Items: []*itemv1.ItemSummary{
					{Id: "iid-1", Name: "Item A", Deleted: false},
					{Id: "iid-2", Name: "Item B", Deleted: true},
				},
			},
			wantLen: 2,
		},
		{name: "Unavailable -> 503", grpcErr: status.Error(codes.Unavailable, "down"), wantStatus: http.StatusServiceUnavailable},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeItemServiceClient{
				getItemSummariesByIdsFn: func(_ context.Context, _ *itemv1.GetItemSummariesByIdsRequest, _ ...grpc.CallOption) (*itemv1.GetItemSummariesByIdsResponse, error) {
					return tt.grpcResp, tt.grpcErr
				},
			}
			c := NewItemClient(fake)
			items, err := c.GetItemSummariesByIDs(context.Background(), []string{"iid-1", "iid-2"})
			if tt.wantStatus != 0 {
				assertClientError(t, err, tt.wantStatus)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(items) != tt.wantLen {
				t.Errorf("len = %d, want %d", len(items), tt.wantLen)
			}
		})
	}
}

// assertClientError is a shared helper for client error assertions.
func assertClientError(t *testing.T, err error, wantStatus int) {
	t.Helper()
	if wantStatus == 0 {
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		return
	}
	if err == nil {
		t.Fatalf("expected error with status %d, got nil", wantStatus)
	}
	ae, ok := err.(*httputil.AppError)
	if !ok {
		t.Fatalf("error type = %T, want *httputil.AppError", err)
	}
	if ae.Status != wantStatus {
		t.Errorf("Status = %d, want %d", ae.Status, wantStatus)
	}
}
