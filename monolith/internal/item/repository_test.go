package item

import (
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestIsReferencedItemDeleteError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{
			name: "matching foreign key violation",
			err: &pgconn.PgError{
				Code:           "23503",
				TableName:      "transaction_items",
				ConstraintName: "transaction_items_item_id_fkey",
			},
			want: true,
		},
		{
			name: "other foreign key violation",
			err: &pgconn.PgError{
				Code:           "23503",
				TableName:      "transaction_items",
				ConstraintName: "transaction_items_transaction_id_fkey",
			},
			want: false,
		},
		{name: "generic error", err: errors.New("boom"), want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isReferencedItemDeleteError(tt.err); got != tt.want {
				t.Fatalf("isReferencedItemDeleteError() = %v, want %v", got, tt.want)
			}
		})
	}
}
