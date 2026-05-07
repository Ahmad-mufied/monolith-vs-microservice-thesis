package transaction

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/pagination"
)

type fakeRepo struct {
	tx          Transaction
	txs         []Transaction
	enriched    []EnrichedTransaction
	err         error
	createItems []CreateItemRequest
}

func (f *fakeRepo) Create(_ context.Context, _ string, items []CreateItemRequest) (Transaction, error) {
	f.createItems = items
	if f.err != nil {
		return Transaction{}, f.err
	}
	return f.tx, nil
}

func (f *fakeRepo) ListOwn(context.Context, string, int, int) ([]Transaction, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.txs, nil
}

func (f *fakeRepo) GetOwnByID(context.Context, string, string) (Transaction, error) {
	if f.err != nil {
		return Transaction{}, f.err
	}
	return f.tx, nil
}

func (f *fakeRepo) ListEnriched(context.Context, int, int) ([]EnrichedTransaction, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.enriched, nil
}

func TestServiceCreate(t *testing.T) {
	userID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001"
	itemID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001"
	tests := []struct {
		name      string
		userID    string
		req       CreateRequest
		repo      *fakeRepo
		wantError bool
		wantCode  apperror.Code
	}{
		{name: "success", userID: userID, req: CreateRequest{Items: []CreateItemRequest{{ItemID: strings.ToUpper(itemID), Amount: 2}}}, repo: &fakeRepo{tx: Transaction{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f3001", UserID: userID, Items: []Item{{ItemID: itemID, Amount: 2}}}}},
		{name: "too many items", userID: userID, req: CreateRequest{Items: repeatCreateItems(itemID, 21)}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "invalid user id", userID: "bad", req: CreateRequest{Items: []CreateItemRequest{{ItemID: itemID, Amount: 2}}}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "empty items", userID: userID, req: CreateRequest{}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "invalid item id", userID: userID, req: CreateRequest{Items: []CreateItemRequest{{ItemID: "bad", Amount: 2}}}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "invalid amount", userID: userID, req: CreateRequest{Items: []CreateItemRequest{{ItemID: itemID, Amount: 0}}}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "duplicate item", userID: userID, req: CreateRequest{Items: []CreateItemRequest{{ItemID: itemID, Amount: 1}, {ItemID: itemID, Amount: 1}}}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "duplicate item with different case", userID: userID, req: CreateRequest{Items: []CreateItemRequest{{ItemID: itemID, Amount: 1}, {ItemID: strings.ToUpper(itemID), Amount: 1}}}, repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest},
		{name: "repo conflict", userID: userID, req: CreateRequest{Items: []CreateItemRequest{{ItemID: itemID, Amount: 2}}}, repo: &fakeRepo{err: apperror.Conflict("insufficient available amount")}, wantError: true, wantCode: apperror.CodeConflict},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NewService(tt.repo).Create(context.Background(), tt.userID, tt.req)
			assertAppError(t, err, tt.wantError, tt.wantCode)
			if !tt.wantError && got == "" {
				t.Fatal("expected transaction ID")
			}
			if !tt.wantError && len(tt.repo.createItems) == 1 && tt.repo.createItems[0].ItemID != itemID {
				t.Fatalf("normalized item_id = %q, want %q", tt.repo.createItems[0].ItemID, itemID)
			}
		})
	}
}

func TestServiceCreateValidationDetails(t *testing.T) {
	service := NewService(&fakeRepo{})
	userID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001"
	itemID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001"

	_, err := service.Create(context.Background(), userID, CreateRequest{Items: []CreateItemRequest{{ItemID: itemID, Amount: 1}, {ItemID: strings.ToUpper(itemID), Amount: 1}}})
	assertValidationDetail(t, err, "item_id", "duplicate item in transaction")
}

func TestServiceReadMethods(t *testing.T) {
	userID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001"
	txID := "018f5f60-7c35-7ccf-9c3c-0a5e6f6f3001"
	now := time.Date(2026, 5, 5, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name      string
		run       func(*testing.T, *Service) error
		repo      *fakeRepo
		wantError bool
		wantCode  apperror.Code
	}{
		{name: "list own success", repo: &fakeRepo{txs: []Transaction{{ID: txID, UserID: userID}}}, run: func(t *testing.T, s *Service) error {
			got, err := s.ListOwn(context.Background(), userID, pagination.Page{Limit: 50})
			if err != nil {
				return err
			}
			if len(got) != 1 || got[0].ID != txID || got[0].UserID != userID {
				t.Fatalf("ListOwn() = %+v", got)
			}
			return nil
		}},
		{name: "detail success", repo: &fakeRepo{tx: Transaction{ID: txID, UserID: userID}}, run: func(t *testing.T, s *Service) error {
			got, err := s.GetOwnByID(context.Background(), userID, txID)
			if err != nil {
				return err
			}
			if got.ID != txID || got.UserID != userID {
				t.Fatalf("GetOwnByID() = %+v", got)
			}
			return nil
		}},
		{name: "enriched success", repo: &fakeRepo{enriched: []EnrichedTransaction{{ID: txID, CreatedAt: now}}}, run: func(t *testing.T, s *Service) error {
			got, err := s.ListEnriched(context.Background(), pagination.Page{Limit: 50})
			if err != nil {
				return err
			}
			if len(got) != 1 || got[0].ID != txID || !got[0].CreatedAt.Equal(now) {
				t.Fatalf("ListEnriched() = %+v", got)
			}
			return nil
		}},
		{name: "invalid detail id", repo: &fakeRepo{}, wantError: true, wantCode: apperror.CodeBadRequest, run: func(_ *testing.T, s *Service) error {
			_, err := s.GetOwnByID(context.Background(), userID, "bad")
			return err
		}},
		{name: "repo not found", repo: &fakeRepo{err: apperror.NotFound("transaction not found")}, wantError: true, wantCode: apperror.CodeNotFound, run: func(_ *testing.T, s *Service) error {
			_, err := s.GetOwnByID(context.Background(), userID, txID)
			return err
		}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.run(t, NewService(tt.repo))
			assertAppError(t, err, tt.wantError, tt.wantCode)
		})
	}
}

func repeatCreateItems(itemID string, count int) []CreateItemRequest {
	items := make([]CreateItemRequest, count)
	for i := range items {
		items[i] = CreateItemRequest{
			ItemID: fmt.Sprintf("018f5f60-7c35-7ccf-9c3c-%012x", i+1),
			Amount: 1,
		}
	}
	return items
}

func assertAppError(t *testing.T, err error, wantError bool, wantCode apperror.Code) {
	t.Helper()
	if wantError {
		if err == nil {
			t.Fatal("expected error, got nil")
		}
		var appErr *apperror.Error
		if !errors.As(err, &appErr) {
			t.Fatalf("error type = %T, want *apperror.Error", err)
		}
		if appErr.Code != wantCode {
			t.Fatalf("code = %s, want %s", appErr.Code, wantCode)
		}
		return
	}
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func assertValidationDetail(t *testing.T, err error, wantField, wantMessage string) {
	t.Helper()
	var appErr *apperror.Error
	if !errors.As(err, &appErr) {
		t.Fatalf("error type = %T, want *apperror.Error", err)
	}

	gotMessage, ok := appErr.Details[wantField]
	if !ok {
		t.Fatalf("details = %#v, want field %q", appErr.Details, wantField)
	}
	if gotMessage != wantMessage {
		t.Fatalf("details[%q] = %v, want %q", wantField, gotMessage, wantMessage)
	}
}
