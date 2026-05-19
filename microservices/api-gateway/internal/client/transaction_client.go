package client

import (
	"context"
	"net/http"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/numconv"
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

func paginationToProto(limit, offset int) (int32, int32, error) {
	protoLimit, err := numconv.IntToInt32(limit, "limit")
	if err != nil {
		return 0, 0, &httputil.AppError{
			Status:  http.StatusBadRequest,
			Code:    "BAD_REQUEST",
			Message: err.Error(),
		}
	}

	protoOffset, err := numconv.IntToInt32(offset, "offset")
	if err != nil {
		return 0, 0, &httputil.AppError{
			Status:  http.StatusBadRequest,
			Code:    "BAD_REQUEST",
			Message: err.Error(),
		}
	}

	return protoLimit, protoOffset, nil
}
