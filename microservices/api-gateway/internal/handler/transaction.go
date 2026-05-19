package handler

import (
	"context"
	"net/http"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/client"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/middleware"
	"github.com/labstack/echo/v4"
	"golang.org/x/sync/errgroup"
)

type transactionClient interface {
	CreateTransaction(ctx context.Context, userID string, items []dto.CreateTransactionItemRequest) (string, error)
	GetOwnTransactions(ctx context.Context, userID string, limit, offset int) ([]dto.Transaction, error)
	GetTransactionByID(ctx context.Context, transactionID, userID string) (*dto.Transaction, error)
	GetTransactionsForEnrichment(ctx context.Context, limit, offset int) ([]client.RawTransaction, error)
}

type enrichAuthClient interface {
	GetUsersByIDs(ctx context.Context, ids []string) ([]*dto.UserSummary, error)
}

type enrichItemClient interface {
	GetItemSummariesByIDs(ctx context.Context, ids []string) ([]dto.ItemSummary, error)
}

type TransactionHandler struct {
	txClient   transactionClient
	authClient enrichAuthClient
	itemClient enrichItemClient
}

func NewTransactionHandler(tx transactionClient, auth enrichAuthClient, item enrichItemClient) *TransactionHandler {
	return &TransactionHandler{txClient: tx, authClient: auth, itemClient: item}
}

func (h *TransactionHandler) CreateTransaction(c echo.Context) error {
	userID, err := middleware.UserIDFromContext(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	var req dto.CreateTransactionRequest
	if err := httputil.Bind(c, &req); err != nil {
		return httputil.Error(c, err)
	}
	txID, err := h.txClient.CreateTransaction(c.Request().Context(), userID, req.Items)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.ID(c, http.StatusCreated, "Transaction created successfully", txID)
}

func (h *TransactionHandler) GetOwnTransactions(c echo.Context) error {
	userID, err := middleware.UserIDFromContext(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	limit, offset, err := httputil.ParsePage(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	txs, err := h.txClient.GetOwnTransactions(c.Request().Context(), userID, limit, offset)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.List(c, http.StatusOK, txs, limit, offset, len(txs))
}

func (h *TransactionHandler) GetTransactionByID(c echo.Context) error {
	userID, err := middleware.UserIDFromContext(c)
	if err != nil {
		return httputil.Error(c, err)
	}
	tx, err := h.txClient.GetTransactionByID(c.Request().Context(), c.Param("transaction_id"), userID)
	if err != nil {
		return httputil.Error(c, err)
	}
	return httputil.Success(c, http.StatusOK, tx)
}

func (h *TransactionHandler) GetAllEnriched(c echo.Context) error {
	limit, offset, err := httputil.ParsePage(c)
	if err != nil {
		return httputil.Error(c, err)
	}

	ctx := c.Request().Context()

	rawTxs, err := h.txClient.GetTransactionsForEnrichment(ctx, limit, offset)
	if err != nil {
		return httputil.Error(c, err)
	}

	if len(rawTxs) == 0 {
		return httputil.List(c, http.StatusOK, []dto.EnrichedTransaction{}, limit, offset, 0)
	}

	// Collect unique user_ids and item_ids.
	userIDSet := make(map[string]struct{})
	itemIDSet := make(map[string]struct{})
	for _, tx := range rawTxs {
		userIDSet[tx.UserID] = struct{}{}
		for _, it := range tx.Items {
			itemIDSet[it.ItemID] = struct{}{}
		}
	}

	userIDs := setToSlice(userIDSet)
	itemIDs := setToSlice(itemIDSet)

	var (
		users         []*dto.UserSummary
		itemSummaries []dto.ItemSummary
	)

	g, enrichCtx := errgroup.WithContext(ctx)

	g.Go(func() error {
		result, err := h.authClient.GetUsersByIDs(enrichCtx, userIDs)
		if err != nil {
			return err
		}
		users = result
		return nil
	})

	g.Go(func() error {
		result, err := h.itemClient.GetItemSummariesByIDs(enrichCtx, itemIDs)
		if err != nil {
			return err
		}
		itemSummaries = result
		return nil
	})

	if err := g.Wait(); err != nil {
		return httputil.Error(c, err)
	}

	// Build lookup maps.
	userMap := make(map[string]*dto.UserSummary, len(users))
	for _, u := range users {
		if u == nil || u.ID == "" {
			continue
		}
		userMap[u.ID] = u
	}
	itemMap := make(map[string]dto.ItemSummary, len(itemSummaries))
	for _, it := range itemSummaries {
		itemMap[it.ID] = it
	}

	// Assemble enriched response.
	enriched := make([]dto.EnrichedTransaction, 0, len(rawTxs))
	for _, tx := range rawTxs {
		u, ok := userMap[tx.UserID]
		if !ok {
			return httputil.Error(c, enrichIntegrityError())
		}

		items := make([]dto.EnrichedTransactionItem, 0, len(tx.Items))
		for _, it := range tx.Items {
			summary, ok := itemMap[it.ItemID]
			if !ok {
				return httputil.Error(c, enrichIntegrityError())
			}
			items = append(items, dto.EnrichedTransactionItem{Item: summary, Amount: it.Amount})
		}

		enriched = append(enriched, dto.EnrichedTransaction{
			ID:        tx.ID,
			User:      *u,
			Items:     items,
			CreatedAt: tx.CreatedAt,
			UpdatedAt: tx.UpdatedAt,
		})
	}

	return httputil.List(c, http.StatusOK, enriched, limit, offset, len(enriched))
}

func setToSlice(m map[string]struct{}) []string {
	s := make([]string, 0, len(m))
	for k := range m {
		s = append(s, k)
	}
	return s
}

func enrichIntegrityError() *httputil.AppError {
	return &httputil.AppError{
		Status:  http.StatusInternalServerError,
		Code:    "INTERNAL_SERVER_ERROR",
		Message: "failed to enrich transaction data",
	}
}
