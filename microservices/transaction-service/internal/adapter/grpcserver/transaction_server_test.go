package grpcserver

import (
	"context"
	"testing"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	transactionv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/transaction/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type fakeTransactionUsecase struct {
	createTransactionFn            func(ctx context.Context, userID string, items []domain.TransactionItem) (string, error)
	getOwnTransactionsFn           func(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error)
	getTransactionByIDFn           func(ctx context.Context, transactionID, userID string) (*domain.Transaction, error)
	getTransactionsForEnrichmentFn func(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error)
}

func (f *fakeTransactionUsecase) CreateTransaction(ctx context.Context, userID string, items []domain.TransactionItem) (string, error) {
	return f.createTransactionFn(ctx, userID, items)
}

func (f *fakeTransactionUsecase) GetOwnTransactions(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
	return f.getOwnTransactionsFn(ctx, userID, limit, offset)
}

func (f *fakeTransactionUsecase) GetTransactionByID(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
	return f.getTransactionByIDFn(ctx, transactionID, userID)
}

func (f *fakeTransactionUsecase) GetTransactionsForEnrichment(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
	return f.getTransactionsForEnrichmentFn(ctx, limit, offset)
}

func TestTransactionServer_CreateTransaction(t *testing.T) {
	tests := []struct {
		name       string
		req        *transactionv1.CreateTransactionRequest
		ucFn       func(ctx context.Context, userID string, items []domain.TransactionItem) (string, error)
		wantCode   codes.Code
		wantID     string
		wantItemID string
		wantAmount int64
	}{
		{
			name: "success request mapped correctly",
			req: &transactionv1.CreateTransactionRequest{
				UserId: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
				Items: []*transactionv1.TransactionItemInput{
					{ItemId: "01968ad4-98b1-79c8-a6f0-ec21f8f434c7", Amount: 2},
				},
			},
			ucFn: func(ctx context.Context, userID string, items []domain.TransactionItem) (string, error) {
				if userID != "01968ad4-98b1-79c8-a6f0-ec21f8f434c6" || len(items) != 1 {
					t.Fatalf("unexpected create input: userID=%q items=%#v", userID, items)
				}
				return "01968ad4-98b1-79c8-a6f0-ec21f8f434d0", nil
			},
			wantID: "01968ad4-98b1-79c8-a6f0-ec21f8f434d0",
		},
		{
			name: "invalid request propagated as invalid argument",
			req:  &transactionv1.CreateTransactionRequest{},
			ucFn: func(ctx context.Context, userID string, items []domain.TransactionItem) (string, error) {
				return "", pkgerrors.InvalidInput("invalid request payload")
			},
			wantCode: codes.InvalidArgument,
		},
		{
			name: "usecase not found",
			req:  &transactionv1.CreateTransactionRequest{},
			ucFn: func(ctx context.Context, userID string, items []domain.TransactionItem) (string, error) {
				return "", pkgerrors.NotFound("item not found")
			},
			wantCode: codes.NotFound,
		},
		{
			name: "usecase failed precondition",
			req:  &transactionv1.CreateTransactionRequest{},
			ucFn: func(ctx context.Context, userID string, items []domain.TransactionItem) (string, error) {
				return "", pkgerrors.FailedPrecondition("requested amount exceeds available amount")
			},
			wantCode: codes.FailedPrecondition,
		},
		{
			name: "usecase unavailable",
			req:  &transactionv1.CreateTransactionRequest{},
			ucFn: func(ctx context.Context, userID string, items []domain.TransactionItem) (string, error) {
				return "", pkgerrors.Unavailable("item service unavailable")
			},
			wantCode: codes.Unavailable,
		},
		{
			name: "usecase internal",
			req:  &transactionv1.CreateTransactionRequest{},
			ucFn: func(ctx context.Context, userID string, items []domain.TransactionItem) (string, error) {
				return "", pkgerrors.Internal("internal server error", nil)
			},
			wantCode: codes.Internal,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := NewTransactionServer(&fakeTransactionUsecase{createTransactionFn: tt.ucFn})
			resp, err := srv.CreateTransaction(context.Background(), tt.req)
			if tt.wantCode != codes.OK {
				if status.Code(err) != tt.wantCode {
					t.Fatalf("code = %v, want %v", status.Code(err), tt.wantCode)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if resp.GetTransactionId() != tt.wantID {
				t.Fatalf("TransactionId = %q, want %q", resp.GetTransactionId(), tt.wantID)
			}
		})
	}
}

func TestTransactionServer_GetOwnTransactions(t *testing.T) {
	createdAt := time.Date(2026, 5, 11, 8, 0, 0, 0, time.UTC)

	tests := []struct {
		name      string
		req       *transactionv1.GetOwnTransactionsRequest
		ucFn      func(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error)
		wantCode  codes.Code
		wantTotal int32
	}{
		{
			name: "success response mapping",
			req:  &transactionv1.GetOwnTransactionsRequest{UserId: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6", Limit: 10, Offset: 5},
			ucFn: func(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
				return []*domain.Transaction{{
					ID:        "01968ad4-98b1-79c8-a6f0-ec21f8f434d0",
					UserID:    userID,
					Items:     []domain.TransactionItem{{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c7", Amount: 2}},
					CreatedAt: createdAt,
					UpdatedAt: createdAt,
				}}, nil
			},
			wantTotal: 1,
		},
		{
			name: "invalid input mapping",
			req:  &transactionv1.GetOwnTransactionsRequest{},
			ucFn: func(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
				return nil, pkgerrors.InvalidInput("invalid request payload")
			},
			wantCode: codes.InvalidArgument,
		},
		{
			name: "internal error mapping",
			req:  &transactionv1.GetOwnTransactionsRequest{},
			ucFn: func(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
				return nil, pkgerrors.Internal("internal server error", nil)
			},
			wantCode: codes.Internal,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := NewTransactionServer(&fakeTransactionUsecase{getOwnTransactionsFn: tt.ucFn})
			resp, err := srv.GetOwnTransactions(context.Background(), tt.req)
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
		})
	}
}

func TestTransactionServer_GetTransactionById(t *testing.T) {
	createdAt := time.Date(2026, 5, 11, 8, 0, 0, 0, time.UTC)

	tests := []struct {
		name     string
		req      *transactionv1.GetTransactionByIdRequest
		ucFn     func(ctx context.Context, transactionID, userID string) (*domain.Transaction, error)
		wantCode codes.Code
	}{
		{
			name: "success response mapping",
			req:  &transactionv1.GetTransactionByIdRequest{TransactionId: "01968ad4-98b1-79c8-a6f0-ec21f8f434d0", UserId: "01968ad4-98b1-79c8-a6f0-ec21f8f434c6"},
			ucFn: func(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
				return &domain.Transaction{
					ID:        transactionID,
					UserID:    userID,
					Items:     []domain.TransactionItem{{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c7", Amount: 2}},
					CreatedAt: createdAt,
					UpdatedAt: createdAt,
				}, nil
			},
		},
		{
			name: "invalid uuid mapping",
			req:  &transactionv1.GetTransactionByIdRequest{},
			ucFn: func(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
				return nil, pkgerrors.InvalidInput("invalid request payload")
			},
			wantCode: codes.InvalidArgument,
		},
		{
			name: "not found mapping",
			req:  &transactionv1.GetTransactionByIdRequest{},
			ucFn: func(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
				return nil, pkgerrors.NotFound("transaction not found")
			},
			wantCode: codes.NotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := NewTransactionServer(&fakeTransactionUsecase{getTransactionByIDFn: tt.ucFn})
			_, err := srv.GetTransactionById(context.Background(), tt.req)
			if tt.wantCode != codes.OK {
				if status.Code(err) != tt.wantCode {
					t.Fatalf("code = %v, want %v", status.Code(err), tt.wantCode)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

func TestTransactionServer_GetTransactionsForEnrichment(t *testing.T) {
	createdAt := time.Date(2026, 5, 11, 8, 0, 0, 0, time.UTC)

	tests := []struct {
		name      string
		req       *transactionv1.GetTransactionsForEnrichmentRequest
		ucFn      func(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error)
		wantCode  codes.Code
		wantTotal int32
	}{
		{
			name: "success response mapping",
			req:  &transactionv1.GetTransactionsForEnrichmentRequest{Limit: 10, Offset: 5},
			ucFn: func(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
				return []*domain.Transaction{{
					ID:        "01968ad4-98b1-79c8-a6f0-ec21f8f434d0",
					UserID:    "01968ad4-98b1-79c8-a6f0-ec21f8f434c6",
					Items:     []domain.TransactionItem{{ItemID: "01968ad4-98b1-79c8-a6f0-ec21f8f434c7", Amount: 1}},
					CreatedAt: createdAt,
					UpdatedAt: createdAt,
				}}, nil
			},
			wantTotal: 1,
		},
		{
			name: "invalid pagination mapping",
			req:  &transactionv1.GetTransactionsForEnrichmentRequest{},
			ucFn: func(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
				return nil, pkgerrors.InvalidInput("invalid request payload")
			},
			wantCode: codes.InvalidArgument,
		},
		{
			name: "internal error mapping",
			req:  &transactionv1.GetTransactionsForEnrichmentRequest{},
			ucFn: func(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
				return nil, pkgerrors.Internal("internal server error", nil)
			},
			wantCode: codes.Internal,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := NewTransactionServer(&fakeTransactionUsecase{getTransactionsForEnrichmentFn: tt.ucFn})
			resp, err := srv.GetTransactionsForEnrichment(context.Background(), tt.req)
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
		})
	}
}
