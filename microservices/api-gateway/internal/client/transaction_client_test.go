package client

import (
	"context"
	"math"
	"net/http"
	"testing"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	transactionv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/transaction/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type fakeTransactionServiceClient struct {
	createTransactionFn            func(ctx context.Context, in *transactionv1.CreateTransactionRequest, opts ...grpc.CallOption) (*transactionv1.CreateTransactionResponse, error)
	getOwnTransactionsFn           func(ctx context.Context, in *transactionv1.GetOwnTransactionsRequest, opts ...grpc.CallOption) (*transactionv1.GetOwnTransactionsResponse, error)
	getTransactionByIdFn           func(ctx context.Context, in *transactionv1.GetTransactionByIdRequest, opts ...grpc.CallOption) (*transactionv1.GetTransactionByIdResponse, error)
	getTransactionsForEnrichmentFn func(ctx context.Context, in *transactionv1.GetTransactionsForEnrichmentRequest, opts ...grpc.CallOption) (*transactionv1.GetTransactionsForEnrichmentResponse, error)
}

func (f *fakeTransactionServiceClient) CreateTransaction(ctx context.Context, in *transactionv1.CreateTransactionRequest, opts ...grpc.CallOption) (*transactionv1.CreateTransactionResponse, error) {
	return f.createTransactionFn(ctx, in, opts...)
}
func (f *fakeTransactionServiceClient) GetOwnTransactions(ctx context.Context, in *transactionv1.GetOwnTransactionsRequest, opts ...grpc.CallOption) (*transactionv1.GetOwnTransactionsResponse, error) {
	return f.getOwnTransactionsFn(ctx, in, opts...)
}
func (f *fakeTransactionServiceClient) GetTransactionById(ctx context.Context, in *transactionv1.GetTransactionByIdRequest, opts ...grpc.CallOption) (*transactionv1.GetTransactionByIdResponse, error) {
	return f.getTransactionByIdFn(ctx, in, opts...)
}
func (f *fakeTransactionServiceClient) GetTransactionsForEnrichment(ctx context.Context, in *transactionv1.GetTransactionsForEnrichmentRequest, opts ...grpc.CallOption) (*transactionv1.GetTransactionsForEnrichmentResponse, error) {
	return f.getTransactionsForEnrichmentFn(ctx, in, opts...)
}

func TestTransactionClient_CreateTransaction(t *testing.T) {
	tests := []struct {
		name       string
		items      []dto.CreateTransactionItemRequest
		grpcResp   *transactionv1.CreateTransactionResponse
		grpcErr    error
		wantStatus int
		wantID     string
	}{
		{
			name:     "success returns transaction id",
			items:    []dto.CreateTransactionItemRequest{{ItemID: "iid-1", Amount: 2}},
			grpcResp: &transactionv1.CreateTransactionResponse{TransactionId: "txid-1"},
			wantID:   "txid-1",
		},
		{name: "amount overflow -> 400", items: []dto.CreateTransactionItemRequest{{ItemID: "iid-1", Amount: math.MaxInt32 + 1}}, wantStatus: http.StatusBadRequest},
		{name: "FailedPrecondition -> 409", grpcErr: status.Error(codes.FailedPrecondition, "amount exceeded"), wantStatus: http.StatusConflict},
		{name: "NotFound -> 404", grpcErr: status.Error(codes.NotFound, "item not found"), wantStatus: http.StatusNotFound},
		{name: "Unavailable -> 503", grpcErr: status.Error(codes.Unavailable, "down"), wantStatus: http.StatusServiceUnavailable},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeTransactionServiceClient{
				createTransactionFn: func(_ context.Context, _ *transactionv1.CreateTransactionRequest, _ ...grpc.CallOption) (*transactionv1.CreateTransactionResponse, error) {
					return tt.grpcResp, tt.grpcErr
				},
			}
			c := NewTransactionClient(fake)
			id, err := c.CreateTransaction(context.Background(), "uid-1", tt.items)
			if tt.wantStatus != 0 {
				assertClientError(t, err, tt.wantStatus)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if id != tt.wantID {
				t.Errorf("id = %q, want %q", id, tt.wantID)
			}
		})
	}
}

func TestTransactionClient_GetOwnTransactions(t *testing.T) {
	tests := []struct {
		name       string
		grpcResp   *transactionv1.GetOwnTransactionsResponse
		grpcErr    error
		wantStatus int
		wantLen    int
	}{
		{
			name: "success maps transactions",
			grpcResp: &transactionv1.GetOwnTransactionsResponse{
				Transactions: []*transactionv1.Transaction{
					{Id: "txid-1", UserId: "uid-1", Items: []*transactionv1.TransactionItem{{ItemId: "iid-1", Amount: 2}}, CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z"},
				},
				TotalReturned: 1,
			},
			wantLen: 1,
		},
		{name: "Unavailable -> 503", grpcErr: status.Error(codes.Unavailable, "down"), wantStatus: http.StatusServiceUnavailable},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeTransactionServiceClient{
				getOwnTransactionsFn: func(_ context.Context, _ *transactionv1.GetOwnTransactionsRequest, _ ...grpc.CallOption) (*transactionv1.GetOwnTransactionsResponse, error) {
					return tt.grpcResp, tt.grpcErr
				},
			}
			c := NewTransactionClient(fake)
			txs, err := c.GetOwnTransactions(context.Background(), "uid-1", 50, 0)
			if tt.wantStatus != 0 {
				assertClientError(t, err, tt.wantStatus)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(txs) != tt.wantLen {
				t.Errorf("len = %d, want %d", len(txs), tt.wantLen)
			}
		})
	}
}

func TestTransactionClient_GetTransactionByID(t *testing.T) {
	tests := []struct {
		name       string
		grpcResp   *transactionv1.GetTransactionByIdResponse
		grpcErr    error
		wantStatus int
		wantID     string
	}{
		{
			name:     "success",
			grpcResp: &transactionv1.GetTransactionByIdResponse{Transaction: &transactionv1.Transaction{Id: "txid-1", UserId: "uid-1", CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z"}},
			wantID:   "txid-1",
		},
		{name: "NotFound -> 404", grpcErr: status.Error(codes.NotFound, "not found"), wantStatus: http.StatusNotFound},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeTransactionServiceClient{
				getTransactionByIdFn: func(_ context.Context, _ *transactionv1.GetTransactionByIdRequest, _ ...grpc.CallOption) (*transactionv1.GetTransactionByIdResponse, error) {
					return tt.grpcResp, tt.grpcErr
				},
			}
			c := NewTransactionClient(fake)
			tx, err := c.GetTransactionByID(context.Background(), "txid-1", "uid-1")
			if tt.wantStatus != 0 {
				assertClientError(t, err, tt.wantStatus)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tx.ID != tt.wantID {
				t.Errorf("ID = %q, want %q", tx.ID, tt.wantID)
			}
		})
	}
}

func TestTransactionClient_GetTransactionsForEnrichment(t *testing.T) {
	tests := []struct {
		name       string
		grpcResp   *transactionv1.GetTransactionsForEnrichmentResponse
		grpcErr    error
		wantStatus int
		wantLen    int
	}{
		{
			name: "success maps raw transactions",
			grpcResp: &transactionv1.GetTransactionsForEnrichmentResponse{
				Transactions: []*transactionv1.TransactionForEnrichment{
					{Id: "txid-1", UserId: "uid-1", Items: []*transactionv1.TransactionItem{{ItemId: "iid-1", Amount: 3}}, CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z"},
				},
				TotalReturned: 1,
			},
			wantLen: 1,
		},
		{name: "Unavailable -> 503", grpcErr: status.Error(codes.Unavailable, "down"), wantStatus: http.StatusServiceUnavailable},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeTransactionServiceClient{
				getTransactionsForEnrichmentFn: func(_ context.Context, _ *transactionv1.GetTransactionsForEnrichmentRequest, _ ...grpc.CallOption) (*transactionv1.GetTransactionsForEnrichmentResponse, error) {
					return tt.grpcResp, tt.grpcErr
				},
			}
			c := NewTransactionClient(fake)
			txs, err := c.GetTransactionsForEnrichment(context.Background(), 50, 0)
			if tt.wantStatus != 0 {
				assertClientError(t, err, tt.wantStatus)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(txs) != tt.wantLen {
				t.Errorf("len = %d, want %d", len(txs), tt.wantLen)
			}
		})
	}
}
