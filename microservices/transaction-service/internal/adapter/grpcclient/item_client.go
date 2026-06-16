package grpcclient

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/debuglog"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/numconv"
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
	startedAt := time.Now()
	reqItems := make([]*itemv1.TransactionItemValidationInput, 0, len(items))
	for _, item := range items {
		amount, err := numconv.IntToInt32(item.Amount, "amount")
		if err != nil {
			return pkgerrors.InvalidInput(err.Error())
		}

		reqItems = append(reqItems, &itemv1.TransactionItemValidationInput{
			ItemId: item.ItemID,
			Amount: amount,
		})
	}

	_, err := c.client.ValidateTransactionItems(ctx, &itemv1.ValidateTransactionItemsRequest{
		Items: reqItems,
	})
	if err == nil {
		return nil
	}
	if ctxErr := pkgerrors.FromContext(err, "item service request timed out", "item service request canceled"); ctxErr != nil {
		// Context-derived failures are logged before returning so we can separate
		// caller deadline pressure from business-rule responses in Datadog.
		debuglog.GRPC(
			context.Background(),
			"transaction-service item rpc failure",
			"transaction_item_validate_rpc_failure",
			"/item.v1.ItemService/ValidateTransactionItems",
			startedAt,
			err,
			"mapped_error", ctxErr.Error(),
		)
		return ctxErr
	}

	st, ok := status.FromError(err)
	if !ok {
		appErr := pkgerrors.Internal("internal server error", fmt.Errorf("validate transaction items: %w", err))
		// This branch is intentionally separate from debuglog.GRPC because there
		// is no stable gRPC status to extract from a non-status transport error.
		debuglog.ErrorWithDuration(
			context.Background(),
			slog.LevelError,
			"transaction-service item rpc failure",
			"transaction_item_validate_rpc_failure",
			startedAt,
			err,
			"grpc_method", "/item.v1.ItemService/ValidateTransactionItems",
			"mapped_error", appErr.Error(),
		)
		return appErr
	}

	var appErr error
	switch st.Code() {
	case codes.NotFound:
		appErr = pkgerrors.NotFound("item not found")
	case codes.FailedPrecondition:
		appErr = pkgerrors.FailedPrecondition("requested amount exceeds available amount")
	case codes.InvalidArgument:
		appErr = pkgerrors.InvalidInput("invalid request payload")
	case codes.Aborted:
		appErr = pkgerrors.Conflict("transaction conflict")
	case codes.DeadlineExceeded:
		appErr = pkgerrors.DeadlineExceeded("item service request timed out")
	case codes.Canceled:
		appErr = pkgerrors.Canceled("item service request canceled")
	case codes.Unavailable:
		appErr = pkgerrors.Unavailable("item service unavailable")
	default:
		appErr = pkgerrors.Internal("internal server error", fmt.Errorf("validate transaction items: %w", err))
	}

	// Every mapped gRPC response is logged once at this boundary so transaction
	// RCA can correlate upstream item-service behavior with local error mapping.
	debuglog.GRPC(
		context.Background(),
		"transaction-service item rpc failure",
		"transaction_item_validate_rpc_failure",
		"/item.v1.ItemService/ValidateTransactionItems",
		startedAt,
		err,
		"mapped_error", appErr.Error(),
	)
	return appErr
}
