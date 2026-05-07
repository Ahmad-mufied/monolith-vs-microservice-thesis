package validation

import (
	"errors"
	"testing"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
)

func TestStruct(t *testing.T) {
	type nestedItem struct {
		ItemID string `json:"item_id" validate:"required,uuid"`
		Amount int    `json:"amount" validate:"gt=0"`
	}

	type request struct {
		Name            string       `json:"name" validate:"required,max=5"`
		AvailableAmount *int         `json:"available_amount" validate:"required,gte=0"`
		Items           []nestedItem `json:"items" validate:"required,min=1,max=2,dive"`
	}

	negative := -1

	tests := []struct {
		name        string
		req         request
		wantField   string
		wantMessage string
	}{
		{
			name:        "required field uses json name",
			req:         request{AvailableAmount: &negative, Items: []nestedItem{{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", Amount: 1}}},
			wantField:   "name",
			wantMessage: "is required",
		},
		{
			name:        "max string maps to character message",
			req:         request{Name: "abcdef", AvailableAmount: &negative, Items: []nestedItem{{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", Amount: 1}}},
			wantField:   "name",
			wantMessage: "must be at most 5 characters",
		},
		{
			name:        "nested uuid error flattens to leaf field",
			req:         request{Name: "abc", AvailableAmount: &negative, Items: []nestedItem{{ItemID: "bad", Amount: 1}}},
			wantField:   "available_amount",
			wantMessage: "must be greater than or equal to 0",
		},
		{
			name:        "slice size error maps to items",
			req:         request{Name: "abc", AvailableAmount: new(0), Items: []nestedItem{{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", Amount: 1}, {ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2002", Amount: 1}, {ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2003", Amount: 1}}},
			wantField:   "items",
			wantMessage: "must contain at most 2 items",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := Struct(tt.req)
			assertValidationError(t, err, tt.wantField, tt.wantMessage)
		})
	}
}

func TestStructNestedLeafErrors(t *testing.T) {
	type item struct {
		ItemID string `json:"item_id" validate:"required,uuid"`
		Amount int    `json:"amount" validate:"gt=0"`
	}

	type request struct {
		Items []item `json:"items" validate:"required,min=1,max=20,dive"`
	}

	err := Struct(request{Items: []item{{ItemID: "bad", Amount: 0}}})
	assertValidationError(t, err, "item_id", "must be a valid UUID")

	err = Struct(request{Items: []item{{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", Amount: 0}}})
	assertValidationError(t, err, "amount", "must be greater than 0")
}

func assertValidationError(t *testing.T, err error, wantField, wantMessage string) {
	t.Helper()
	if err == nil {
		t.Fatal("expected error, got nil")
	}

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
	if len(appErr.Details) != 1 {
		t.Fatalf("details = %#v, want exactly one violation", appErr.Details)
	}
}
