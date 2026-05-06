package item

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
	"github.com/labstack/echo/v4"
)

type fakeItemService struct {
	resp Response
	list []Response
	err  error
	page pagination.Page
	id   string
}

func (f *fakeItemService) Create(context.Context, CreateRequest) (Response, error) {
	return f.resp, f.err
}

func (f *fakeItemService) List(_ context.Context, page pagination.Page) ([]Response, error) {
	f.page = page
	return f.list, f.err
}

func (f *fakeItemService) GetByID(_ context.Context, id string) (Response, error) {
	f.id = id
	return f.resp, f.err
}

func (f *fakeItemService) Update(_ context.Context, id string, _ UpdateRequest) (Response, error) {
	f.id = id
	return f.resp, f.err
}

func (f *fakeItemService) Delete(_ context.Context, id string) error {
	f.id = id
	return f.err
}

func TestHandlerCreate(t *testing.T) {
	now := time.Date(2026, 5, 5, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name       string
		body       string
		service    *fakeItemService
		wantStatus int
	}{
		{name: "success", body: `{"name":"Item","available_amount":10}`, service: &fakeItemService{resp: Response{ID: "item", Name: "Item", AvailableAmount: 10, CreatedAt: now, UpdatedAt: now}}, wantStatus: http.StatusCreated},
		{name: "invalid json", body: `{`, service: &fakeItemService{}, wantStatus: http.StatusBadRequest},
		{name: "service error", body: `{}`, service: &fakeItemService{err: apperror.BadRequest("invalid request payload", nil)}, wantStatus: http.StatusBadRequest},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := executeItemHandler(http.MethodPost, "/api/v1/items", tt.body, nil, NewHandler(tt.service).Create)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
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
		})
	}
}

func TestHandlerGetUpdateDelete(t *testing.T) {
	tests := []struct {
		name       string
		method     string
		body       string
		handler    func(*Handler) echo.HandlerFunc
		service    *fakeItemService
		wantStatus int
	}{
		{name: "get success", method: http.MethodGet, handler: func(h *Handler) echo.HandlerFunc { return h.GetByID }, service: &fakeItemService{resp: Response{ID: "item"}}, wantStatus: http.StatusOK},
		{name: "get not found", method: http.MethodGet, handler: func(h *Handler) echo.HandlerFunc { return h.GetByID }, service: &fakeItemService{err: apperror.NotFound("item not found")}, wantStatus: http.StatusNotFound},
		{name: "update success", method: http.MethodPut, body: `{"name":"Updated"}`, handler: func(h *Handler) echo.HandlerFunc { return h.Update }, service: &fakeItemService{resp: Response{ID: "item"}}, wantStatus: http.StatusOK},
		{name: "update invalid json", method: http.MethodPut, body: `{`, handler: func(h *Handler) echo.HandlerFunc { return h.Update }, service: &fakeItemService{}, wantStatus: http.StatusBadRequest},
		{name: "delete success", method: http.MethodDelete, handler: func(h *Handler) echo.HandlerFunc { return h.Delete }, service: &fakeItemService{}, wantStatus: http.StatusOK},
		{name: "delete conflict", method: http.MethodDelete, handler: func(h *Handler) echo.HandlerFunc { return h.Delete }, service: &fakeItemService{err: apperror.Conflict("item is referenced by transaction")}, wantStatus: http.StatusConflict},
		{name: "delete not found", method: http.MethodDelete, handler: func(h *Handler) echo.HandlerFunc { return h.Delete }, service: &fakeItemService{err: apperror.NotFound("item not found")}, wantStatus: http.StatusNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := NewHandler(tt.service)
			rec := executeItemHandler(tt.method, "/api/v1/items/item-1", tt.body, map[string]string{"item_id": "item-1"}, tt.handler(h))
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantStatus < 400 && tt.service.id != "item-1" && tt.method != http.MethodPost {
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
	for name, value := range params {
		c.SetParamNames(name)
		c.SetParamValues(value)
	}
	_ = handler(c)
	return rec
}
