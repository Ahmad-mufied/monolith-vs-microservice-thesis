package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
)

type fakeItemClient struct {
	syncItemsFn        func(ctx context.Context, items []dto.SyncItemInput) error
	listItemsFn        func(ctx context.Context, limit, offset int32) ([]dto.Item, error)
	getItemByIDFn      func(ctx context.Context, itemID string) (*dto.Item, error)
	getItemSummariesFn func(ctx context.Context, ids []string) ([]dto.ItemSummary, error)
}

func (f *fakeItemClient) SyncItems(ctx context.Context, items []dto.SyncItemInput) error {
	return f.syncItemsFn(ctx, items)
}
func (f *fakeItemClient) ListItems(ctx context.Context, limit, offset int32) ([]dto.Item, error) {
	return f.listItemsFn(ctx, limit, offset)
}
func (f *fakeItemClient) GetItemByID(ctx context.Context, itemID string) (*dto.Item, error) {
	return f.getItemByIDFn(ctx, itemID)
}
func (f *fakeItemClient) GetItemSummariesByIDs(ctx context.Context, ids []string) ([]dto.ItemSummary, error) {
	return f.getItemSummariesFn(ctx, ids)
}

func TestItemHandler_ListItems(t *testing.T) {
	tests := []struct {
		name       string
		query      string
		clientFn   func(ctx context.Context, limit, offset int32) ([]dto.Item, error)
		wantStatus int
		wantLen    int
		wantLimit  int32
		wantOffset int32
	}{
		{
			name:  "success with default pagination",
			query: "",
			clientFn: func(_ context.Context, limit, offset int32) ([]dto.Item, error) {
				return []dto.Item{{ID: "iid-1", Name: "Item A"}}, nil
			},
			wantStatus: http.StatusOK,
			wantLen:    1,
			wantLimit:  50,
			wantOffset: 0,
		},
		{
			name:  "success with explicit pagination",
			query: "?limit=10&offset=5",
			clientFn: func(_ context.Context, limit, offset int32) ([]dto.Item, error) {
				if limit != 10 || offset != 5 {
					return nil, &httputil.AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: "wrong pagination"}
				}
				return []dto.Item{}, nil
			},
			wantStatus: http.StatusOK,
			wantLimit:  10,
			wantOffset: 5,
		},
		{
			name:       "invalid limit returns 400",
			query:      "?limit=200",
			wantStatus: http.StatusBadRequest,
		},
		{
			name:  "client error returns 503",
			query: "",
			clientFn: func(_ context.Context, _, _ int32) ([]dto.Item, error) {
				return nil, &httputil.AppError{Status: http.StatusServiceUnavailable, Code: "SERVICE_UNAVAILABLE", Message: "down"}
			},
			wantStatus: http.StatusServiceUnavailable,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeItemClient{}
			if tt.clientFn != nil {
				fake.listItemsFn = tt.clientFn
			}
			h := NewItemHandler(fake)
			c, rec := newEchoCtx(http.MethodGet, "/api/v1/items"+tt.query, "")
			runHandler(h.ListItems, c)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantStatus == http.StatusOK && tt.wantLen > 0 {
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

func TestItemHandler_SyncItems(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		clientFn   func(ctx context.Context, items []dto.SyncItemInput) error
		wantStatus int
		wantMsg    string
	}{
		{
			name:       "success returns 200 with message",
			body:       `{"items":[{"name":"Item A","available_amount":100}]}`,
			clientFn:   func(_ context.Context, _ []dto.SyncItemInput) error { return nil },
			wantStatus: http.StatusOK,
			wantMsg:    "Items synchronized successfully",
		},
		{
			name:       "invalid json returns 400",
			body:       `{`,
			wantStatus: http.StatusBadRequest,
		},
		{
			name: "conflict returns 409",
			body: `{"items":[{"name":"Item A","available_amount":100}]}`,
			clientFn: func(_ context.Context, _ []dto.SyncItemInput) error {
				return &httputil.AppError{Status: http.StatusConflict, Code: "CONFLICT", Message: "name conflict"}
			},
			wantStatus: http.StatusConflict,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeItemClient{}
			if tt.clientFn != nil {
				fake.syncItemsFn = tt.clientFn
			}
			h := NewItemHandler(fake)
			c, rec := newEchoCtx(http.MethodPut, "/api/v1/items", tt.body)
			runHandler(h.SyncItems, c)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantMsg != "" {
				var body map[string]any
				if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
					t.Fatalf("unmarshal: %v", err)
				}
				if body["message"] != tt.wantMsg {
					t.Errorf("message = %q, want %q", body["message"], tt.wantMsg)
				}
			}
		})
	}
}

func TestItemHandler_GetItemByID(t *testing.T) {
	tests := []struct {
		name       string
		itemID     string
		clientFn   func(ctx context.Context, itemID string) (*dto.Item, error)
		wantStatus int
		wantName   string
	}{
		{
			name:   "success returns item",
			itemID: "iid-1",
			clientFn: func(_ context.Context, id string) (*dto.Item, error) {
				return &dto.Item{ID: id, Name: "Item A", AvailableAmount: 100}, nil
			},
			wantStatus: http.StatusOK,
			wantName:   "Item A",
		},
		{
			name:   "not found returns 404",
			itemID: "iid-missing",
			clientFn: func(_ context.Context, _ string) (*dto.Item, error) {
				return nil, &httputil.AppError{Status: http.StatusNotFound, Code: "NOT_FOUND", Message: "item not found"}
			},
			wantStatus: http.StatusNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeItemClient{getItemByIDFn: tt.clientFn}
			h := NewItemHandler(fake)
			c, rec := newEchoCtx(http.MethodGet, "/api/v1/items/"+tt.itemID, "")
			c.SetParamNames("item_id")
			c.SetParamValues(tt.itemID)
			runHandler(h.GetItemByID, c)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantName != "" {
				var body map[string]any
				if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
					t.Fatalf("unmarshal: %v", err)
				}
				data, _ := body["data"].(map[string]any)
				if data["name"] != tt.wantName {
					t.Errorf("name = %q, want %q", data["name"], tt.wantName)
				}
			}
		})
	}
}
