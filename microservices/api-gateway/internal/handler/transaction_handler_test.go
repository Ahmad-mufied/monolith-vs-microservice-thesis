package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/client"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/middleware"
)

type fakeTransactionClient struct {
	createFn           func(ctx context.Context, userID string, items []dto.CreateTransactionItemRequest) (string, error)
	getOwnFn           func(ctx context.Context, userID string, limit, offset int32) ([]dto.Transaction, error)
	getByIDFn          func(ctx context.Context, transactionID, userID string) (*dto.Transaction, error)
	getForEnrichmentFn func(ctx context.Context, limit, offset int32) ([]client.RawTransaction, error)
}

func (f *fakeTransactionClient) CreateTransaction(ctx context.Context, userID string, items []dto.CreateTransactionItemRequest) (string, error) {
	return f.createFn(ctx, userID, items)
}
func (f *fakeTransactionClient) GetOwnTransactions(ctx context.Context, userID string, limit, offset int32) ([]dto.Transaction, error) {
	return f.getOwnFn(ctx, userID, limit, offset)
}
func (f *fakeTransactionClient) GetTransactionByID(ctx context.Context, transactionID, userID string) (*dto.Transaction, error) {
	return f.getByIDFn(ctx, transactionID, userID)
}
func (f *fakeTransactionClient) GetTransactionsForEnrichment(ctx context.Context, limit, offset int32) ([]client.RawTransaction, error) {
	return f.getForEnrichmentFn(ctx, limit, offset)
}

func TestTransactionHandler_CreateTransaction(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		userID     string
		clientFn   func(ctx context.Context, userID string, items []dto.CreateTransactionItemRequest) (string, error)
		wantStatus int
		wantID     string
	}{
		{
			name:   "success returns 201 with transaction id",
			body:   `{"items":[{"item_id":"iid-1","amount":2}]}`,
			userID: "uid-1",
			clientFn: func(_ context.Context, userID string, items []dto.CreateTransactionItemRequest) (string, error) {
				if userID != "uid-1" {
					return "", &httputil.AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: "wrong userID"}
				}
				return "txid-1", nil
			},
			wantStatus: http.StatusCreated,
			wantID:     "txid-1",
		},
		{
			name:       "invalid json returns 400",
			body:       `{`,
			userID:     "uid-1",
			wantStatus: http.StatusBadRequest,
		},
		{
			name:   "failed precondition returns 409",
			body:   `{"items":[{"item_id":"iid-1","amount":9999}]}`,
			userID: "uid-1",
			clientFn: func(_ context.Context, _ string, _ []dto.CreateTransactionItemRequest) (string, error) {
				return "", &httputil.AppError{Status: http.StatusConflict, Code: "CONFLICT", Message: "amount exceeded"}
			},
			wantStatus: http.StatusConflict,
		},
		{
			name:   "item not found returns 404",
			body:   `{"items":[{"item_id":"iid-missing","amount":1}]}`,
			userID: "uid-1",
			clientFn: func(_ context.Context, _ string, _ []dto.CreateTransactionItemRequest) (string, error) {
				return "", &httputil.AppError{Status: http.StatusNotFound, Code: "NOT_FOUND", Message: "item not found"}
			},
			wantStatus: http.StatusNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeTransactionClient{}
			if tt.clientFn != nil {
				fake.createFn = tt.clientFn
			}
			h := NewTransactionHandler(fake, nil, nil)
			c, rec := newEchoCtx(http.MethodPost, "/api/v1/transactions", tt.body)
			c.Set("user_id", tt.userID)
			runHandler(h.CreateTransaction, c)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantID != "" {
				var body map[string]any
				if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
					t.Fatalf("unmarshal: %v", err)
				}
				data, _ := body["data"].(map[string]any)
				if data["id"] != tt.wantID {
					t.Errorf("id = %q, want %q", data["id"], tt.wantID)
				}
			}
		})
	}
}

func TestTransactionHandler_GetOwnTransactions(t *testing.T) {
	tests := []struct {
		name       string
		userID     string
		clientFn   func(ctx context.Context, userID string, limit, offset int32) ([]dto.Transaction, error)
		wantStatus int
		wantLen    int
	}{
		{
			name:   "success returns list",
			userID: "uid-1",
			clientFn: func(_ context.Context, _ string, _, _ int32) ([]dto.Transaction, error) {
				return []dto.Transaction{{ID: "txid-1", UserID: "uid-1"}}, nil
			},
			wantStatus: http.StatusOK,
			wantLen:    1,
		},
		{
			name:   "client error returns 500",
			userID: "uid-1",
			clientFn: func(_ context.Context, _ string, _, _ int32) ([]dto.Transaction, error) {
				return nil, &httputil.AppError{Status: http.StatusInternalServerError, Code: "INTERNAL_SERVER_ERROR", Message: "internal"}
			},
			wantStatus: http.StatusInternalServerError,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeTransactionClient{getOwnFn: tt.clientFn}
			h := NewTransactionHandler(fake, nil, nil)
			c, rec := newEchoCtx(http.MethodGet, "/api/v1/transactions", "")
			c.Set(middleware.UserIDContextKey, tt.userID)
			runHandler(h.GetOwnTransactions, c)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantLen > 0 {
				var body map[string]any
				if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
					t.Fatalf("unmarshal: %v", err)
				}
				data, _ := body["data"].([]any)
				if len(data) != tt.wantLen {
					t.Errorf("len(data) = %d, want %d", len(data), tt.wantLen)
				}
			}
		})
	}
}

func TestTransactionHandler_GetTransactionByID(t *testing.T) {
	tests := []struct {
		name       string
		txID       string
		userID     string
		clientFn   func(ctx context.Context, transactionID, userID string) (*dto.Transaction, error)
		wantStatus int
	}{
		{
			name:   "success returns transaction",
			txID:   "txid-1",
			userID: "uid-1",
			clientFn: func(_ context.Context, txID, _ string) (*dto.Transaction, error) {
				return &dto.Transaction{ID: txID, UserID: "uid-1"}, nil
			},
			wantStatus: http.StatusOK,
		},
		{
			name:   "not found returns 404",
			txID:   "txid-missing",
			userID: "uid-1",
			clientFn: func(_ context.Context, _, _ string) (*dto.Transaction, error) {
				return nil, &httputil.AppError{Status: http.StatusNotFound, Code: "NOT_FOUND", Message: "not found"}
			},
			wantStatus: http.StatusNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeTransactionClient{getByIDFn: tt.clientFn}
			h := NewTransactionHandler(fake, nil, nil)
			c, rec := newEchoCtx(http.MethodGet, "/api/v1/transactions/"+tt.txID, "")
			c.Set(middleware.UserIDContextKey, tt.userID)
			c.SetParamNames("transaction_id")
			c.SetParamValues(tt.txID)
			runHandler(h.GetTransactionByID, c)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
		})
	}
}

func TestTransactionHandler_GetAllEnriched(t *testing.T) {
	rawTxs := []client.RawTransaction{
		{
			ID:        "txid-1",
			UserID:    "uid-1",
			Items:     []dto.TransactionItem{{ItemID: "iid-1", Amount: 2}},
			CreatedAt: "2026-01-01T00:00:00Z",
			UpdatedAt: "2026-01-01T00:00:00Z",
		},
	}

	tests := []struct {
		name            string
		txClientFn      func(ctx context.Context, limit, offset int32) ([]client.RawTransaction, error)
		authClientFn    func(ctx context.Context, ids []string) ([]*dto.UserSummary, error)
		itemClientFn    func(ctx context.Context, ids []string) ([]dto.ItemSummary, error)
		wantStatus      int
		wantLen         int
		wantUserName    string
		wantItemName    string
		wantItemDeleted bool
	}{
		{
			name: "success enriches transactions with user and item",
			txClientFn: func(_ context.Context, _, _ int32) ([]client.RawTransaction, error) {
				return rawTxs, nil
			},
			authClientFn: func(_ context.Context, ids []string) ([]*dto.UserSummary, error) {
				return []*dto.UserSummary{{ID: ids[0], Name: "Ahmad", Email: "a@b.com"}}, nil
			},
			itemClientFn: func(_ context.Context, ids []string) ([]dto.ItemSummary, error) {
				return []dto.ItemSummary{{ID: ids[0], Name: "Item A", Deleted: false}}, nil
			},
			wantStatus:   http.StatusOK,
			wantLen:      1,
			wantUserName: "Ahmad",
			wantItemName: "Item A",
		},
		{
			name: "empty transactions returns empty list",
			txClientFn: func(_ context.Context, _, _ int32) ([]client.RawTransaction, error) {
				return []client.RawTransaction{}, nil
			},
			wantStatus: http.StatusOK,
			wantLen:    0,
		},
		{
			name: "transaction client error returns 503",
			txClientFn: func(_ context.Context, _, _ int32) ([]client.RawTransaction, error) {
				return nil, &httputil.AppError{Status: http.StatusServiceUnavailable, Code: "SERVICE_UNAVAILABLE", Message: "down"}
			},
			wantStatus: http.StatusServiceUnavailable,
		},
		{
			name: "auth client error returns 503",
			txClientFn: func(_ context.Context, _, _ int32) ([]client.RawTransaction, error) {
				return rawTxs, nil
			},
			authClientFn: func(_ context.Context, _ []string) ([]*dto.UserSummary, error) {
				return nil, &httputil.AppError{Status: http.StatusServiceUnavailable, Code: "SERVICE_UNAVAILABLE", Message: "auth down"}
			},
			wantStatus: http.StatusServiceUnavailable,
		},
		{
			name: "item client error returns 503",
			txClientFn: func(_ context.Context, _, _ int32) ([]client.RawTransaction, error) {
				return rawTxs, nil
			},
			authClientFn: func(_ context.Context, ids []string) ([]*dto.UserSummary, error) {
				return []*dto.UserSummary{{ID: ids[0], Name: "Ahmad", Email: "a@b.com"}}, nil
			},
			itemClientFn: func(_ context.Context, _ []string) ([]dto.ItemSummary, error) {
				return nil, &httputil.AppError{Status: http.StatusServiceUnavailable, Code: "SERVICE_UNAVAILABLE", Message: "item down"}
			},
			wantStatus: http.StatusServiceUnavailable,
		},
		{
			name: "deleted item is marked in enriched response",
			txClientFn: func(_ context.Context, _, _ int32) ([]client.RawTransaction, error) {
				return rawTxs, nil
			},
			authClientFn: func(_ context.Context, ids []string) ([]*dto.UserSummary, error) {
				return []*dto.UserSummary{{ID: ids[0], Name: "Ahmad", Email: "a@b.com"}}, nil
			},
			itemClientFn: func(_ context.Context, ids []string) ([]dto.ItemSummary, error) {
				return []dto.ItemSummary{{ID: ids[0], Name: "Item A", Deleted: true}}, nil
			},
			wantStatus:      http.StatusOK,
			wantLen:         1,
			wantItemDeleted: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			txFake := &fakeTransactionClient{getForEnrichmentFn: tt.txClientFn}
			authFake := &fakeAuthClient{getUsersByIDs: tt.authClientFn}
			itemFake := &fakeItemClient{getItemSummariesFn: tt.itemClientFn}

			h := NewTransactionHandler(txFake, authFake, itemFake)
			c, rec := newEchoCtx(http.MethodGet, "/api/v1/admin/transactions", "")
			runHandler(h.GetAllEnriched, c)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}

			if tt.wantStatus != http.StatusOK {
				return
			}

			var body map[string]any
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			data, _ := body["data"].([]any)
			if len(data) != tt.wantLen {
				t.Errorf("len(data) = %d, want %d", len(data), tt.wantLen)
			}
			if tt.wantLen == 0 {
				return
			}

			tx, _ := data[0].(map[string]any)
			user, _ := tx["user"].(map[string]any)
			if tt.wantUserName != "" && user["name"] != tt.wantUserName {
				t.Errorf("user.name = %q, want %q", user["name"], tt.wantUserName)
			}

			items, _ := tx["items"].([]any)
			if len(items) == 0 {
				t.Fatalf("expected items in enriched transaction")
			}
			txItem, _ := items[0].(map[string]any)
			item, _ := txItem["item"].(map[string]any)
			if tt.wantItemName != "" && item["name"] != tt.wantItemName {
				t.Errorf("item.name = %q, want %q", item["name"], tt.wantItemName)
			}
			if tt.wantItemDeleted && item["deleted"] != true {
				t.Errorf("item.deleted = %v, want true", item["deleted"])
			}
		})
	}
}
