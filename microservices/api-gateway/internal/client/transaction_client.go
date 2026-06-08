package client

import (
	"context"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/numconv"
	transactionv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/transaction/v1"
)

// TransactionClient wraps the generated gRPC TransactionServiceClient.
type TransactionClient struct {
	grpc        transactionv1.TransactionServiceClient
	grpcTimeout time.Duration
}

// NewTransactionClient creates a TransactionClient. grpcTimeout is applied as a
// context.WithTimeout deadline on every outbound RPC call.
func NewTransactionClient(grpc transactionv1.TransactionServiceClient, grpcTimeout time.Duration) *TransactionClient {
	return &TransactionClient{grpc: grpc, grpcTimeout: grpcTimeout}
}

func (c *TransactionClient) CreateTransaction(ctx context.Context, userID string, items []dto.CreateTransactionItemRequest) (string, error) {
	reqItems := make([]*transactionv1.TransactionItemInput, 0, len(items))
	for _, it := range items {
		amount, err := numconv.IntToInt32(it.Amount, "amount")
		if err != nil {
			return "", &httputil.AppError{
				Status:  400,
				Code:    "BAD_REQUEST",
				Message: err.Error(),
			}
		}

		reqItems = append(reqItems, &transactionv1.TransactionItemInput{ItemId: it.ItemID, Amount: amount})
	}
	ctx, cancel := context.WithTimeout(ctx, c.grpcTimeout)
	defer cancel()
	resp, err := c.grpc.CreateTransaction(ctx, &transactionv1.CreateTransactionRequest{UserId: userID, Items: reqItems})
	if err != nil {
		return "", httputil.FromGRPCError(err)
	}
	return resp.GetTransactionId(), nil
}

func (c *TransactionClient) GetOwnTransactions(ctx context.Context, userID string, limit, offset int) ([]dto.Transaction, error) {
	protoLimit, protoOffset, err := paginationToProto(limit, offset)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(ctx, c.grpcTimeout)
	defer cancel()
	resp, err := c.grpc.GetOwnTransactions(ctx, &transactionv1.GetOwnTransactionsRequest{UserId: userID, Limit: protoLimit, Offset: protoOffset})
	if err != nil {
		return nil, httputil.FromGRPCError(err)
	}
	txs := make([]dto.Transaction, 0, len(resp.GetTransactions()))
	for _, tx := range resp.GetTransactions() {
		txs = append(txs, protoTransactionToDTO(tx))
	}
	return txs, nil
}

func (c *TransactionClient) GetTransactionByID(ctx context.Context, transactionID, userID string) (*dto.Transaction, error) {
	ctx, cancel := context.WithTimeout(ctx, c.grpcTimeout)
	defer cancel()
	resp, err := c.grpc.GetTransactionById(ctx, &transactionv1.GetTransactionByIdRequest{TransactionId: transactionID, UserId: userID})
	if err != nil {
		return nil, httputil.FromGRPCError(err)
	}
	tx := protoTransactionToDTO(resp.GetTransaction())
	return &tx, nil
}

// RawTransaction is used for enrichment — same shape as Transaction but from GetTransactionsForEnrichment.
type RawTransaction struct {
	ID        string
	UserID    string
	Items     []dto.TransactionItem
	CreatedAt string
	UpdatedAt string
}

func (c *TransactionClient) GetTransactionsForEnrichment(ctx context.Context, limit, offset int) ([]RawTransaction, error) {
	protoLimit, protoOffset, err := paginationToProto(limit, offset)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(ctx, c.grpcTimeout)
	defer cancel()
	resp, err := c.grpc.GetTransactionsForEnrichment(ctx, &transactionv1.GetTransactionsForEnrichmentRequest{Limit: protoLimit, Offset: protoOffset})
	if err != nil {
		return nil, httputil.FromGRPCError(err)
	}
	txs := make([]RawTransaction, 0, len(resp.GetTransactions()))
	for _, tx := range resp.GetTransactions() {
		items := make([]dto.TransactionItem, 0, len(tx.GetItems()))
		for _, it := range tx.GetItems() {
			items = append(items, dto.TransactionItem{ItemID: it.GetItemId(), Amount: int(it.GetAmount())})
		}
		txs = append(txs, RawTransaction{
			ID:        tx.GetId(),
			UserID:    tx.GetUserId(),
			Items:     items,
			CreatedAt: tx.GetCreatedAt(),
			UpdatedAt: tx.GetUpdatedAt(),
		})
	}
	return txs, nil
}

func protoTransactionToDTO(tx *transactionv1.Transaction) dto.Transaction {
	if tx == nil {
		return dto.Transaction{}
	}
	items := make([]dto.TransactionItem, 0, len(tx.GetItems()))
	for _, it := range tx.GetItems() {
		items = append(items, dto.TransactionItem{ItemID: it.GetItemId(), Amount: int(it.GetAmount())})
	}
	return dto.Transaction{
		ID:        tx.GetId(),
		UserID:    tx.GetUserId(),
		Items:     items,
		CreatedAt: tx.GetCreatedAt(),
		UpdatedAt: tx.GetUpdatedAt(),
	}
}
