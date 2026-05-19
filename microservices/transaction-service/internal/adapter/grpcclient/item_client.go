package grpcclient

import (
	"context"
	"fmt"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type ItemClient struct {
	client itemv1.ItemServiceClient
}

func NewItemClient(client itemv1.ItemServiceClient) *ItemClient {
	return &ItemClient{client: client}
}

func (c *ItemClient) ValidateTransactionItems(ctx context.Context, items []domain.TransactionItem) error {
	reqItems := make([]*itemv1.TransactionItemValidationInput, 0, len(items))
	for _, item := range items {
		reqItems = append(reqItems, &itemv1.TransactionItemValidationInput{
			ItemId: item.ItemID,
			Amount: int32(item.Amount),
		})
	}

	_, err := c.client.ValidateTransactionItems(ctx, &itemv1.ValidateTransactionItemsRequest{
		Items: reqItems,
	})
	if err == nil {
		return nil
	}

	st, ok := status.FromError(err)
	if !ok {
		return pkgerrors.Internal("internal server error", fmt.Errorf("validate transaction items: %w", err))
	}

	switch st.Code() {
	case codes.NotFound:
		return pkgerrors.NotFound("item not found")
	case codes.FailedPrecondition:
		return pkgerrors.FailedPrecondition("requested amount exceeds available amount")
	case codes.InvalidArgument:
		return pkgerrors.InvalidInput("invalid request payload")
	case codes.Aborted:
		return pkgerrors.Conflict("transaction conflict")
	case codes.DeadlineExceeded:
		return pkgerrors.DeadlineExceeded("item service request timed out")
	case codes.Unavailable:
		return pkgerrors.Unavailable("item service unavailable")
	default:
		return pkgerrors.Internal("internal server error", fmt.Errorf("validate transaction items: %w", err))
	}
}
