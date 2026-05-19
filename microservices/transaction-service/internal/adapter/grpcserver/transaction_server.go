package grpcserver

import (
	"context"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/numconv"
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
		protoTransaction, err := domainTransactionToProto(transaction)
		if err != nil {
			return nil, pkgerrors.ToGRPCStatus(pkgerrors.Internal("internal server error", err))
		}
		respTransactions = append(respTransactions, protoTransaction)
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

	protoTransaction, err := domainTransactionToProto(transaction)
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(pkgerrors.Internal("internal server error", err))
	}

	return &transactionv1.GetTransactionByIdResponse{
		Transaction: protoTransaction,
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
		protoTransaction, err := domainTransactionForEnrichmentToProto(transaction)
		if err != nil {
			return nil, pkgerrors.ToGRPCStatus(pkgerrors.Internal("internal server error", err))
		}
		respTransactions = append(respTransactions, protoTransaction)
		totalReturned++
	}

	return &transactionv1.GetTransactionsForEnrichmentResponse{
		Transactions:  respTransactions,
		TotalReturned: totalReturned,
	}, nil
}

func domainTransactionToProto(transaction *domain.Transaction) (*transactionv1.Transaction, error) {
	if transaction == nil {
		return nil, nil
	}

	items := make([]*transactionv1.TransactionItem, 0, len(transaction.Items))
	for _, item := range transaction.Items {
		amount, err := numconv.IntToInt32(item.Amount, "amount")
		if err != nil {
			return nil, err
		}

		items = append(items, &transactionv1.TransactionItem{
			ItemId: item.ItemID,
			Amount: amount,
		})
	}

	return &transactionv1.Transaction{
		Id:        transaction.ID,
		UserId:    transaction.UserID,
		Items:     items,
		CreatedAt: transaction.CreatedAt.UTC().Format(time.RFC3339),
		UpdatedAt: transaction.UpdatedAt.UTC().Format(time.RFC3339),
	}, nil
}

func domainTransactionForEnrichmentToProto(transaction *domain.Transaction) (*transactionv1.TransactionForEnrichment, error) {
	if transaction == nil {
		return nil, nil
	}

	items := make([]*transactionv1.TransactionItem, 0, len(transaction.Items))
	for _, item := range transaction.Items {
		amount, err := numconv.IntToInt32(item.Amount, "amount")
		if err != nil {
			return nil, err
		}

		items = append(items, &transactionv1.TransactionItem{
			ItemId: item.ItemID,
			Amount: amount,
		})
	}

	return &transactionv1.TransactionForEnrichment{
		Id:        transaction.ID,
		UserId:    transaction.UserID,
		Items:     items,
		CreatedAt: transaction.CreatedAt.UTC().Format(time.RFC3339),
		UpdatedAt: transaction.UpdatedAt.UTC().Format(time.RFC3339),
	}, nil
}
