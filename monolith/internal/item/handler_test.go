package item

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
	"github.com/labstack/echo/v4"
)

type fakeItemService struct {
	list          []Response
	resp          Response
	err           error
	page          pagination.Page
	id            string
	lastSyncItems SyncItemsRequest
}

func (f *fakeItemService) SyncItems(_ context.Context, req SyncItemsRequest) error {
	f.lastSyncItems = req
	return f.err
}

func (f *fakeItemService) List(_ context.Context, page pagination.Page) ([]Response, error) {
	f.page = page
	return f.list, f.err
}

func (f *fakeItemService) GetByID(_ context.Context, id string) (Response, error) {
	f.id = id
	return f.resp, f.err
}

func TestHandlerRegisterRoutes(t *testing.T) {
	e := echo.New()
	api := e.Group("/api/v1")

	NewHandler(&fakeItemService{}).RegisterRoutes(api)

	routes := e.Routes()
	hasRoute := func(method, path string) bool {
		for _, route := range routes {
			if route.Method == method && route.Path == path {
				return true
			}
		}
		return false
	}

	if !hasRoute(http.MethodGet, "/api/v1/items") {
		t.Fatal("expected GET /api/v1/items route")
	}
	if !hasRoute(http.MethodPut, "/api/v1/items") {
		t.Fatal("expected PUT /api/v1/items route")
	}
	if !hasRoute(http.MethodGet, "/api/v1/items/:item_id") {
		t.Fatal("expected GET /api/v1/items/:item_id route")
	}
	if hasRoute(http.MethodDelete, "/api/v1/items/:item_id") {
		t.Fatal("did not expect DELETE /api/v1/items/:item_id route")
	}
	if hasRoute(http.MethodPost, "/api/v1/items") {
		t.Fatal("did not expect POST /api/v1/items route")
	}
	if hasRoute(http.MethodPut, "/api/v1/items/:item_id") {
		t.Fatal("did not expect PUT /api/v1/items/:item_id route")
	}
}

func TestHandlerSyncItems(t *testing.T) {
	amount := 10
	tests := []struct {
		name       string
		body       string
		service    *fakeItemService
		wantStatus int
	}{
		{
			name:       "success",
			body:       `{"items":[{"name":"Item","available_amount":10}]}`,
			service:    &fakeItemService{},
			wantStatus: http.StatusOK,
		},
		{name: "invalid json", body: `{`, service: &fakeItemService{}, wantStatus: http.StatusBadRequest},
		{name: "service error", body: `{"items":[{"name":"Item","available_amount":10}]}`, service: &fakeItemService{err: apperror.BadRequest("invalid request payload", nil)}, wantStatus: http.StatusBadRequest},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := executeItemHandler(http.MethodPut, "/api/v1/items", tt.body, nil, NewHandler(tt.service).SyncItems)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantStatus == http.StatusOK {
				var got map[string]string
				if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
					t.Fatalf("unmarshal response: %v", err)
				}
				if got["message"] != "Items synchronized successfully" {
					t.Fatalf("message = %q", got["message"])
				}
				if len(tt.service.lastSyncItems.Items) != 1 {
					t.Fatalf("sync items = %+v", tt.service.lastSyncItems.Items)
				}
				if tt.service.lastSyncItems.Items[0].AvailableAmount == nil || *tt.service.lastSyncItems.Items[0].AvailableAmount != amount {
					t.Fatalf("available_amount = %+v, want 10", tt.service.lastSyncItems.Items[0].AvailableAmount)
				}
			}
		})
	}
}

func TestHandlerList(t *testing.T) {
	tests := []struct {
		name       string
		target     string
		service    *fakeItemService
		wantStatus int
		wantLimit  int
	}{
		{name: "success", target: "/api/v1/items?limit=10&offset=5", service: &fakeItemService{list: []Response{{ID: "item"}}}, wantStatus: http.StatusOK, wantLimit: 10},
		{name: "invalid pagination", target: "/api/v1/items?limit=101", service: &fakeItemService{}, wantStatus: http.StatusBadRequest},
		{name: "service error", target: "/api/v1/items", service: &fakeItemService{err: apperror.Internal("internal server error", nil)}, wantStatus: http.StatusInternalServerError, wantLimit: 50},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := executeItemHandler(http.MethodGet, tt.target, "", nil, NewHandler(tt.service).List)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantLimit != 0 && tt.service.page.Limit != tt.wantLimit {
				t.Fatalf("limit = %d, want %d", tt.service.page.Limit, tt.wantLimit)
			}
			if tt.wantStatus == http.StatusOK && bytes.Contains(rec.Body.Bytes(), []byte(`"status"`)) {
				t.Fatalf("response unexpectedly contains legacy status envelope: %s", rec.Body.String())
			}
		})
	}
}

func TestHandlerGetByID(t *testing.T) {
	tests := []struct {
		name       string
		service    *fakeItemService
		wantStatus int
	}{
		{name: "success", service: &fakeItemService{resp: Response{ID: "item"}}, wantStatus: http.StatusOK},
		{name: "not found", service: &fakeItemService{err: apperror.NotFound("item not found")}, wantStatus: http.StatusNotFound},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := NewHandler(tt.service)
			rec := executeItemHandler(http.MethodGet, "/api/v1/items/item-1", "", map[string]string{"item_id": "item-1"}, h.GetByID)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantStatus < 400 && tt.service.id != "item-1" {
				t.Fatalf("id = %q, want item-1", tt.service.id)
			}
		})
	}
}

func executeItemHandler(method, target, body string, params map[string]string, handler echo.HandlerFunc) *httptest.ResponseRecorder {
	e := echo.New()
	req := httptest.NewRequest(method, target, bytes.NewBufferString(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
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
	if err := handler(c); err != nil {
		e.HTTPErrorHandler(err, c)
	}
	return rec
}
