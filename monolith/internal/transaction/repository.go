package transaction

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type PostgresRepository struct {
	db *pgxpool.Pool
}

func NewPostgresRepository(db *pgxpool.Pool) *PostgresRepository {
	return &PostgresRepository{db: db}
}

func (r *PostgresRepository) Create(ctx context.Context, userID string, items []CreateItemRequest) (Transaction, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return Transaction{}, apperror.Internal("internal server error", fmt.Errorf("beginning transaction: %w", err))
	}
	defer func() {
		_ = tx.Rollback(ctx)
	}()

	availableAfter := make(map[string]int, len(items))
	for _, item := range orderedItemsForAllocation(items) {
		after, err := allocateItem(ctx, tx, item)
		if err != nil {
			return Transaction{}, err
		}
		availableAfter[item.ItemID] = after
	}

	transaction, err := insertTransaction(ctx, tx, userID)
	if err != nil {
		return Transaction{}, err
	}

	transaction.Items = make([]Item, 0, len(items))
	for _, item := range items {
		if err := insertTransactionItem(ctx, tx, transaction.ID, item, availableAfter[item.ItemID]); err != nil {
			return Transaction{}, err
		}
		transaction.Items = append(transaction.Items, Item(item))
	}

	if err := tx.Commit(ctx); err != nil {
		return Transaction{}, apperror.Internal("internal server error", fmt.Errorf("committing transaction: %w", err))
	}
	return transaction, nil
}

func orderedItemsForAllocation(items []CreateItemRequest) []CreateItemRequest {
	ordered := make([]CreateItemRequest, len(items))
	copy(ordered, items)
	sort.SliceStable(ordered, func(i, j int) bool {
		return ordered[i].ItemID < ordered[j].ItemID
	})
	return ordered
}

func (r *PostgresRepository) ListOwn(ctx context.Context, userID string, limit, offset int) ([]Transaction, error) {
	const query = `
SELECT id::text, user_id::text, created_at, updated_at
FROM transactions
WHERE user_id = $1::uuid
ORDER BY created_at DESC, id DESC
LIMIT $2 OFFSET $3`
	rows, err := r.db.Query(ctx, query, userID, limit, offset)
	if err != nil {
		return nil, apperror.Internal("internal server error", fmt.Errorf("listing own transactions: %w", err))
	}
	defer rows.Close()

	transactions := make([]Transaction, 0)
	for rows.Next() {
		var tx Transaction
		if err := rows.Scan(&tx.ID, &tx.UserID, &tx.CreatedAt, &tx.UpdatedAt); err != nil {
			return nil, apperror.Internal("internal server error", fmt.Errorf("scanning transaction: %w", err))
		}
		transactions = append(transactions, tx)
	}
	if err := rows.Err(); err != nil {
		return nil, apperror.Internal("internal server error", fmt.Errorf("iterating transactions: %w", err))
	}

	for i := range transactions {
		items, err := r.listItems(ctx, transactions[i].ID)
		if err != nil {
			return nil, err
		}
		transactions[i].Items = items
	}
	return transactions, nil
}

func (r *PostgresRepository) GetOwnByID(ctx context.Context, userID, transactionID string) (Transaction, error) {
	const query = `
SELECT id::text, user_id::text, created_at, updated_at
FROM transactions
WHERE id = $1::uuid AND user_id = $2::uuid`
	var tx Transaction
	if err := r.db.QueryRow(ctx, query, transactionID, userID).Scan(&tx.ID, &tx.UserID, &tx.CreatedAt, &tx.UpdatedAt); err != nil {
		if err == pgx.ErrNoRows {
			return Transaction{}, apperror.NotFound("transaction not found")
		}
		return Transaction{}, apperror.Internal("internal server error", fmt.Errorf("getting transaction: %w", err))
	}
	items, err := r.listItems(ctx, tx.ID)
	if err != nil {
		return Transaction{}, err
	}
	tx.Items = items
	return tx, nil
}

func (r *PostgresRepository) ListEnriched(ctx context.Context, limit, offset int) ([]EnrichedTransaction, error) {
	const query = `
SELECT
  t.id::text,
  t.created_at,
  t.updated_at,
  u.id::text,
  u.name,
  u.email,
  u.created_at,
  u.updated_at,
  i.id::text,
  i.name,
  i.available_amount,
  i.created_at,
  i.updated_at,
  ti.amount
FROM (
	  SELECT id, user_id, created_at, updated_at
	  FROM transactions
	  ORDER BY created_at DESC, id DESC
	  LIMIT $1 OFFSET $2
	) t
JOIN users u ON u.id = t.user_id
JOIN transaction_items ti ON ti.transaction_id = t.id
JOIN items i ON i.id = ti.item_id
ORDER BY t.created_at DESC, t.id DESC, i.id`
	rows, err := r.db.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, apperror.Internal("internal server error", fmt.Errorf("listing enriched transactions: %w", err))
	}
	defer rows.Close()

	byID := make(map[string]*EnrichedTransaction)
	order := make([]string, 0)
	for rows.Next() {
		var row enrichedRow
		if err := rows.Scan(
			&row.TransactionID,
			&row.TransactionCreatedAt,
			&row.TransactionUpdatedAt,
			&row.UserID,
			&row.UserName,
			&row.UserEmail,
			&row.UserCreatedAt,
			&row.UserUpdatedAt,
			&row.ItemID,
			&row.ItemName,
			&row.ItemAvailableAmount,
			&row.ItemCreatedAt,
			&row.ItemUpdatedAt,
			&row.Amount,
		); err != nil {
			return nil, apperror.Internal("internal server error", fmt.Errorf("scanning enriched transaction: %w", err))
		}

		tx, ok := byID[row.TransactionID]
		if !ok {
			order = append(order, row.TransactionID)
			tx = &EnrichedTransaction{
				ID:        row.TransactionID,
				CreatedAt: row.TransactionCreatedAt,
				UpdatedAt: row.TransactionUpdatedAt,
				User: User{
					ID:        row.UserID,
					Name:      row.UserName,
					Email:     row.UserEmail,
					CreatedAt: row.UserCreatedAt,
					UpdatedAt: row.UserUpdatedAt,
				},
			}
			byID[row.TransactionID] = tx
		}
		tx.Items = append(tx.Items, EnrichedItem{
			Item: ItemDetail{
				ID:              row.ItemID,
				Name:            row.ItemName,
				AvailableAmount: row.ItemAvailableAmount,
				CreatedAt:       row.ItemCreatedAt,
				UpdatedAt:       row.ItemUpdatedAt,
			},
			Amount: row.Amount,
		})
	}
	if err := rows.Err(); err != nil {
		return nil, apperror.Internal("internal server error", fmt.Errorf("iterating enriched transactions: %w", err))
	}

	transactions := make([]EnrichedTransaction, 0, len(order))
	for _, id := range order {
		transactions = append(transactions, *byID[id])
	}
	return transactions, nil
}

func (r *PostgresRepository) listItems(ctx context.Context, transactionID string) ([]Item, error) {
	const query = `
SELECT item_id::text, amount
FROM transaction_items
WHERE transaction_id = $1::uuid
ORDER BY item_id`
	rows, err := r.db.Query(ctx, query, transactionID)
	if err != nil {
		return nil, apperror.Internal("internal server error", fmt.Errorf("listing transaction items: %w", err))
	}
	defer rows.Close()

	items := make([]Item, 0)
	for rows.Next() {
		var item Item
		if err := rows.Scan(&item.ItemID, &item.Amount); err != nil {
			return nil, apperror.Internal("internal server error", fmt.Errorf("scanning transaction item: %w", err))
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, apperror.Internal("internal server error", fmt.Errorf("iterating transaction items: %w", err))
	}
	return items, nil
}

func allocateItem(ctx context.Context, tx pgx.Tx, item CreateItemRequest) (int, error) {
	var availableAmount int
	if err := tx.QueryRow(ctx, `SELECT available_amount FROM items WHERE id = $1::uuid FOR UPDATE`, item.ItemID).Scan(&availableAmount); err != nil {
		if err == pgx.ErrNoRows {
			return 0, apperror.NotFound("item not found")
		}
		return 0, apperror.Internal("internal server error", fmt.Errorf("locking item: %w", err))
	}
	if availableAmount < item.Amount {
		return 0, apperror.Conflict("insufficient available amount")
	}

	var availableAfter int
	if err := tx.QueryRow(ctx, `
UPDATE items
SET available_amount = available_amount - $2, updated_at = now()
WHERE id = $1::uuid
RETURNING available_amount`, item.ItemID, item.Amount).Scan(&availableAfter); err != nil {
		return 0, apperror.Internal("internal server error", fmt.Errorf("allocating item: %w", err))
	}
	return availableAfter, nil
}

func insertTransaction(ctx context.Context, tx pgx.Tx, userID string) (Transaction, error) {
	const query = `
	INSERT INTO transactions (user_id)
	VALUES ($1::uuid)
	RETURNING id::text, user_id::text, created_at, updated_at`
	var transaction Transaction
	if err := tx.QueryRow(ctx, query, userID).Scan(&transaction.ID, &transaction.UserID, &transaction.CreatedAt, &transaction.UpdatedAt); err != nil {
		if isMissingTransactionUserError(err) {
			return Transaction{}, apperror.Unauthorized("invalid authentication context")
		}
		return Transaction{}, apperror.Internal("internal server error", fmt.Errorf("inserting transaction: %w", err))
	}
	return transaction, nil
}

func isMissingTransactionUserError(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	return pgErr.Code == "23503" && pgErr.TableName == "transactions" && pgErr.ConstraintName == "transactions_user_id_fkey"
}

func insertTransactionItem(ctx context.Context, tx pgx.Tx, transactionID string, item CreateItemRequest, availableAfter int) error {
	const query = `
INSERT INTO transaction_items (transaction_id, item_id, amount, available_amount_after)
VALUES ($1::uuid, $2::uuid, $3, $4)`
	if _, err := tx.Exec(ctx, query, transactionID, item.ItemID, item.Amount, availableAfter); err != nil {
		return apperror.Internal("internal server error", fmt.Errorf("inserting transaction item: %w", err))
	}
	return nil
}

type enrichedRow struct {
	TransactionID        string
	TransactionCreatedAt time.Time
	TransactionUpdatedAt time.Time
	UserID               string
	UserName             string
	UserEmail            string
	UserCreatedAt        time.Time
	UserUpdatedAt        time.Time
	ItemID               string
	ItemName             string
	ItemAvailableAmount  int
	ItemCreatedAt        time.Time
	ItemUpdatedAt        time.Time
	Amount               int
}
