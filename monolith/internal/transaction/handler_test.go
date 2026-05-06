package transaction

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/middleware"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
	"github.com/labstack/echo/v4"
)

type fakeTransactionService struct {
	resp        Response
	list        []Response
	enriched    []EnrichedResponse
	err         error
	userID      string
	transaction string
	page        pagination.Page
}

func (f *fakeTransactionService) Create(_ context.Context, userID string, _ CreateRequest) (Response, error) {
	f.userID = userID
	return f.resp, f.err
}

func (f *fakeTransactionService) ListOwn(_ context.Context, userID string, page pagination.Page) ([]Response, error) {
	f.userID = userID
	f.page = page
	return f.list, f.err
}

func (f *fakeTransactionService) GetOwnByID(_ context.Context, userID, transactionID string) (Response, error) {
	f.userID = userID
	f.transaction = transactionID
	return f.resp, f.err
}

func (f *fakeTransactionService) ListEnriched(_ context.Context, page pagination.Page) ([]EnrichedResponse, error) {
	f.page = page
	return f.enriched, f.err
}

func TestHandlerCreate(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		userID     string
		service    *fakeTransactionService
		wantStatus int
	}{
		{name: "success", body: `{"items":[{"item_id":"018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001","amount":2}]}`, userID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001", service: &fakeTransactionService{resp: Response{ID: "tx"}}, wantStatus: http.StatusCreated},
		{name: "missing user", body: `{}`, service: &fakeTransactionService{}, wantStatus: http.StatusUnauthorized},
		{name: "invalid json", body: `{`, userID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001", service: &fakeTransactionService{}, wantStatus: http.StatusBadRequest},
		{name: "service conflict", body: `{"items":[{"item_id":"018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001","amount":2}]}`, userID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001", service: &fakeTransactionService{err: apperror.Conflict("insufficient available amount")}, wantStatus: http.StatusConflict},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := executeTransactionHandler(http.MethodPost, "/api/v1/transactions", tt.body, tt.userID, nil, NewHandler(tt.service).Create)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
		})
	}
}

func TestHandlerListAndDetail(t *testing.T) {
	userID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001"
	tests := []struct {
		name       string
		method     string
		target     string
		params     map[string]string
		handler    func(*Handler) echo.HandlerFunc
		service    *fakeTransactionService
		wantStatus int
	}{
		{name: "list own success", method: http.MethodGet, target: "/api/v1/transactions?limit=10", handler: func(h *Handler) echo.HandlerFunc { return h.ListOwn }, service: &fakeTransactionService{list: []Response{{ID: "tx"}}}, wantStatus: http.StatusOK},
		{name: "list invalid pagination", method: http.MethodGet, target: "/api/v1/transactions?limit=101", handler: func(h *Handler) echo.HandlerFunc { return h.ListOwn }, service: &fakeTransactionService{}, wantStatus: http.StatusBadRequest},
		{name: "detail success", method: http.MethodGet, target: "/api/v1/transactions/tx-1", params: map[string]string{"transaction_id": "tx-1"}, handler: func(h *Handler) echo.HandlerFunc { return h.GetOwnByID }, service: &fakeTransactionService{resp: Response{ID: "tx-1"}}, wantStatus: http.StatusOK},
		{name: "detail not found", method: http.MethodGet, target: "/api/v1/transactions/tx-1", params: map[string]string{"transaction_id": "tx-1"}, handler: func(h *Handler) echo.HandlerFunc { return h.GetOwnByID }, service: &fakeTransactionService{err: apperror.NotFound("transaction not found")}, wantStatus: http.StatusNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := NewHandler(tt.service)
			rec := executeTransactionHandler(tt.method, tt.target, "", userID, tt.params, tt.handler(h))
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantStatus < 400 && tt.service.userID != userID {
				t.Fatalf("userID = %q, want %q", tt.service.userID, userID)
			}
		})
	}
}

func TestHandlerListEnriched(t *testing.T) {
	tests := []struct {
		name       string
		target     string
		service    *fakeTransactionService
		wantStatus int
	}{
		{name: "success", target: "/api/v1/admin/transactions", service: &fakeTransactionService{enriched: []EnrichedResponse{{ID: "tx", User: UserSummaryResponse{ID: "user-1", Name: "Ahmad", Email: "ahmad@example.com"}, Items: []EnrichedItemResponse{{Item: ItemSummaryResponse{ID: "item-1", Name: "Item A"}, Amount: 2}}}}}, wantStatus: http.StatusOK},
		{name: "invalid pagination", target: "/api/v1/admin/transactions?offset=-1", service: &fakeTransactionService{}, wantStatus: http.StatusBadRequest},
		{name: "service error", target: "/api/v1/admin/transactions", service: &fakeTransactionService{err: apperror.Internal("internal server error", nil)}, wantStatus: http.StatusInternalServerError},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := executeTransactionHandler(http.MethodGet, tt.target, "", "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001", nil, NewHandler(tt.service).ListEnriched)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantStatus == http.StatusOK {
				var got map[string]any
				if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
					t.Fatalf("unmarshal response: %v", err)
				}
				data, ok := got["data"].([]any)
				if !ok || len(data) == 0 {
					t.Fatalf("data payload = %+v", got["data"])
				}
				first, ok := data[0].(map[string]any)
				if !ok {
					t.Fatalf("transaction payload = %+v", data[0])
				}
				items, ok := first["items"].([]any)
				if !ok || len(items) == 0 {
					t.Fatalf("items payload = %+v", first["items"])
				}
				itemEntry, ok := items[0].(map[string]any)
				if !ok {
					t.Fatalf("item entry = %+v", items[0])
				}
				itemSummary, ok := itemEntry["item"].(map[string]any)
				if !ok {
					t.Fatalf("item summary = %+v", itemEntry["item"])
				}
				if _, exists := itemSummary["available_amount"]; exists {
					t.Fatalf("enriched item unexpectedly exposes available_amount: %+v", itemSummary)
				}
				if _, exists := itemSummary["created_at"]; exists {
					t.Fatalf("enriched item unexpectedly exposes created_at: %+v", itemSummary)
				}
			}
		})
	}
}

func executeTransactionHandler(method, target, body, userID string, params map[string]string, handler echo.HandlerFunc) *httptest.ResponseRecorder {
	e := echo.New()
	req := httptest.NewRequest(method, target, bytes.NewBufferString(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	if userID != "" {
		c.Set(middleware.UserIDKey, userID)
	}
	if len(params) > 0 {
		names := make([]string, 0, len(params))
		values := make([]string, 0, len(params))
		for name, value := range params {
			names = append(names, name)
			values = append(values, value)
		}
		c.SetParamNames(names...)
		c.SetParamValues(values...)
	}
	_ = handler(c)
	return rec
}
