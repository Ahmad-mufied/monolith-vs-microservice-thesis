package transaction

import (
	"context"
	errorspkg "errors"
	"testing"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestOrderedItemsForAllocation(t *testing.T) {
	input := []CreateItemRequest{
		{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2003", Amount: 1},
		{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", Amount: 1},
		{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2002", Amount: 1},
	}

	ordered := orderedItemsForAllocation(input)
	if ordered[0].ItemID != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001" ||
		ordered[1].ItemID != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2002" ||
		ordered[2].ItemID != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2003" {
		t.Fatalf("ordered items = %+v", ordered)
	}

	// Ensure input order is untouched.
	if input[0].ItemID != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2003" {
		t.Fatalf("input mutated: %+v", input)
	}
}

func TestOrderedItemsForAllocationMatchesReadOrder(t *testing.T) {
	input := []CreateItemRequest{
		{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2002", Amount: 3},
		{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", Amount: 1},
	}

	ordered := orderedItemsForAllocation(input)
	responseItems := make([]Item, 0, len(ordered))
	for _, item := range ordered {
		responseItems = append(responseItems, Item(item))
	}

	if responseItems[0].ItemID != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001" ||
		responseItems[1].ItemID != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2002" {
		t.Fatalf("response items = %+v", responseItems)
	}
}

func TestInsertTransactionErrorMapping(t *testing.T) {
	t.Run("missing user foreign key becomes unauthorized", func(t *testing.T) {
		tx := stubTx{
			row: stubRow{
				err: &pgconn.PgError{
					Code:           "23503",
					TableName:      "transactions",
					ConstraintName: "transactions_user_id_fkey",
				},
			},
		}

		_, err := insertTransaction(context.Background(), tx, "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001")
		var appErr *apperror.Error
		if !errorspkg.As(err, &appErr) {
			t.Fatalf("error type = %T, want *apperror.Error", err)
		}
		if appErr.Code != apperror.CodeUnauthorized {
			t.Fatalf("error code = %s, want %s", appErr.Code, apperror.CodeUnauthorized)
		}
	})

	t.Run("other insert errors stay internal", func(t *testing.T) {
		tx := stubTx{row: stubRow{err: errorspkg.New("boom")}}

		_, err := insertTransaction(context.Background(), tx, "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001")
		var appErr *apperror.Error
		if !errorspkg.As(err, &appErr) {
			t.Fatalf("error type = %T, want *apperror.Error", err)
		}
		if appErr.Code != apperror.CodeInternal {
			t.Fatalf("error code = %s, want %s", appErr.Code, apperror.CodeInternal)
		}
	})
}

type stubTx struct {
	row stubRow
}

func (stubTx) Begin(context.Context) (pgx.Tx, error) { return nil, nil }
func (stubTx) Commit(context.Context) error          { return nil }
func (stubTx) Rollback(context.Context) error        { return nil }
func (stubTx) CopyFrom(context.Context, pgx.Identifier, []string, pgx.CopyFromSource) (int64, error) {
	return 0, nil
}
func (stubTx) SendBatch(context.Context, *pgx.Batch) pgx.BatchResults { return nil }
func (stubTx) LargeObjects() pgx.LargeObjects                         { return pgx.LargeObjects{} }
func (stubTx) Prepare(context.Context, string, string) (*pgconn.StatementDescription, error) {
	return nil, nil
}
func (stubTx) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, nil
}
func (stubTx) Query(context.Context, string, ...any) (pgx.Rows, error) { return nil, nil }
func (s stubTx) QueryRow(context.Context, string, ...any) pgx.Row      { return s.row }
func (stubTx) Conn() *pgx.Conn                                         { return nil }

type stubRow struct {
	err error
}

func (r stubRow) Scan(...any) error { return r.err }
