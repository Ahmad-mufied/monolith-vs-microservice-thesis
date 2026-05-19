package grpcserver

import (
	"context"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	transactionv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/transaction/v1"
)

type transactionUsecase interface {
	CreateTransaction(ctx context.Context, userID string, items []domain.TransactionItem) (string, error)
	GetOwnTransactions(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error)
	GetTransactionByID(ctx context.Context, transactionID, userID string) (*domain.Transaction, error)
	GetTransactionsForEnrichment(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error)
}

type TransactionServer struct {
	transactionv1.UnimplementedTransactionServiceServer
	uc transactionUsecase
}

func NewTransactionServer(uc transactionUsecase) *TransactionServer {
	return &TransactionServer{uc: uc}
}

func (s *TransactionServer) CreateTransaction(ctx context.Context, req *transactionv1.CreateTransactionRequest) (*transactionv1.CreateTransactionResponse, error) {
	items := make([]domain.TransactionItem, 0, len(req.GetItems()))
	for _, item := range req.GetItems() {
		items = append(items, domain.TransactionItem{
			ItemID: item.GetItemId(),
			Amount: int(item.GetAmount()),
		})
	}

	transactionID, err := s.uc.CreateTransaction(ctx, req.GetUserId(), items)
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	return &transactionv1.CreateTransactionResponse{TransactionId: transactionID}, nil
}

func (s *TransactionServer) GetOwnTransactions(ctx context.Context, req *transactionv1.GetOwnTransactionsRequest) (*transactionv1.GetOwnTransactionsResponse, error) {
	transactions, err := s.uc.GetOwnTransactions(ctx, req.GetUserId(), req.GetLimit(), req.GetOffset())
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	var totalReturned int32
	respTransactions := make([]*transactionv1.Transaction, 0, len(transactions))
	for _, transaction := range transactions {
		respTransactions = append(respTransactions, domainTransactionToProto(transaction))
		totalReturned++
	}

	return &transactionv1.GetOwnTransactionsResponse{
		Transactions:  respTransactions,
		TotalReturned: totalReturned,
	}, nil
}

func (s *TransactionServer) GetTransactionById(ctx context.Context, req *transactionv1.GetTransactionByIdRequest) (*transactionv1.GetTransactionByIdResponse, error) {
	transaction, err := s.uc.GetTransactionByID(ctx, req.GetTransactionId(), req.GetUserId())
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	return &transactionv1.GetTransactionByIdResponse{
		Transaction: domainTransactionToProto(transaction),
	}, nil
}

func (s *TransactionServer) GetTransactionsForEnrichment(ctx context.Context, req *transactionv1.GetTransactionsForEnrichmentRequest) (*transactionv1.GetTransactionsForEnrichmentResponse, error) {
	transactions, err := s.uc.GetTransactionsForEnrichment(ctx, req.GetLimit(), req.GetOffset())
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	var totalReturned int32
	respTransactions := make([]*transactionv1.TransactionForEnrichment, 0, len(transactions))
	for _, transaction := range transactions {
		respTransactions = append(respTransactions, domainTransactionForEnrichmentToProto(transaction))
		totalReturned++
	}

	return &transactionv1.GetTransactionsForEnrichmentResponse{
		Transactions:  respTransactions,
		TotalReturned: totalReturned,
	}, nil
}

func domainTransactionToProto(transaction *domain.Transaction) *transactionv1.Transaction {
	if transaction == nil {
		return nil
	}

	items := make([]*transactionv1.TransactionItem, 0, len(transaction.Items))
	for _, item := range transaction.Items {
		items = append(items, &transactionv1.TransactionItem{
			ItemId: item.ItemID,
			Amount: int32(item.Amount),
		})
	}

	return &transactionv1.Transaction{
		Id:        transaction.ID,
		UserId:    transaction.UserID,
		Items:     items,
		CreatedAt: transaction.CreatedAt.UTC().Format(time.RFC3339),
		UpdatedAt: transaction.UpdatedAt.UTC().Format(time.RFC3339),
	}
}

func domainTransactionForEnrichmentToProto(transaction *domain.Transaction) *transactionv1.TransactionForEnrichment {
	if transaction == nil {
		return nil
	}

	items := make([]*transactionv1.TransactionItem, 0, len(transaction.Items))
	for _, item := range transaction.Items {
		items = append(items, &transactionv1.TransactionItem{
			ItemId: item.ItemID,
			Amount: int32(item.Amount),
		})
	}

	return &transactionv1.TransactionForEnrichment{
		Id:        transaction.ID,
		UserId:    transaction.UserID,
		Items:     items,
		CreatedAt: transaction.CreatedAt.UTC().Format(time.RFC3339),
		UpdatedAt: transaction.UpdatedAt.UTC().Format(time.RFC3339),
	}
}
