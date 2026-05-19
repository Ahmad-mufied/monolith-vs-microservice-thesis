package client

import (
	"context"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	transactionv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/transaction/v1"
)

// TransactionClient wraps the generated gRPC TransactionServiceClient.
type TransactionClient struct {
	grpc transactionv1.TransactionServiceClient
}

func NewTransactionClient(grpc transactionv1.TransactionServiceClient) *TransactionClient {
	return &TransactionClient{grpc: grpc}
}

func (c *TransactionClient) CreateTransaction(ctx context.Context, userID string, items []dto.CreateTransactionItemRequest) (string, error) {
	reqItems := make([]*transactionv1.TransactionItemInput, 0, len(items))
	for _, it := range items {
		reqItems = append(reqItems, &transactionv1.TransactionItemInput{ItemId: it.ItemID, Amount: int32(it.Amount)})
	}
	resp, err := c.grpc.CreateTransaction(ctx, &transactionv1.CreateTransactionRequest{UserId: userID, Items: reqItems})
	if err != nil {
		return "", httputil.FromGRPCError(err)
	}
	return resp.GetTransactionId(), nil
}

func (c *TransactionClient) GetOwnTransactions(ctx context.Context, userID string, limit, offset int32) ([]dto.Transaction, error) {
	resp, err := c.grpc.GetOwnTransactions(ctx, &transactionv1.GetOwnTransactionsRequest{UserId: userID, Limit: limit, Offset: offset})
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

func (c *TransactionClient) GetTransactionsForEnrichment(ctx context.Context, limit, offset int32) ([]RawTransaction, error) {
	resp, err := c.grpc.GetTransactionsForEnrichment(ctx, &transactionv1.GetTransactionsForEnrichmentRequest{Limit: limit, Offset: offset})
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
