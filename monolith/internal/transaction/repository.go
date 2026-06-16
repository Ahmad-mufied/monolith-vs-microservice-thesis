package transaction

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
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
		return Transaction{}, apperror.InternalFromContext(ctx, "beginning transaction", err)
	}
	finalizeCtx, finalizeCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer finalizeCancel()
	defer func() {
		_ = tx.Rollback(finalizeCtx)
	}()

	orderedItems := orderedItemsForAllocation(items)
	for _, item := range orderedItems {
		if err := validateItem(ctx, tx, item); err != nil {
			return Transaction{}, err
		}
	}

	transaction, err := insertTransaction(ctx, tx, userID)
	if err != nil {
		return Transaction{}, err
	}

	transaction.Items = make([]Item, 0, len(orderedItems))
	for _, item := range orderedItems {
		if err := insertTransactionItem(ctx, tx, transaction.ID, item); err != nil {
			return Transaction{}, err
		}
		transaction.Items = append(transaction.Items, Item(item))
	}

	if err := tx.Commit(ctx); err != nil {
		return Transaction{}, apperror.InternalFromContext(ctx, "committing transaction", err)
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
		return nil, apperror.InternalFromContext(ctx, "listing own transactions", err)
	}
	defer rows.Close()

	transactions := make([]Transaction, 0, limit)
	for rows.Next() {
		var tx Transaction
		if err := rows.Scan(&tx.ID, &tx.UserID, &tx.CreatedAt, &tx.UpdatedAt); err != nil {
			return nil, apperror.InternalFromContext(ctx, "scanning transaction", err)
		}
		transactions = append(transactions, tx)
	}
	if err := rows.Err(); err != nil {
		return nil, apperror.InternalFromContext(ctx, "iterating transactions", err)
	}
	if len(transactions) == 0 {
		return transactions, nil
	}

	itemsByTransactionID, err := r.listItemsByTransactionIDs(ctx, transactionIDs(transactions))
	if err != nil {
		return nil, err
	}
	for i := range transactions {
		transactions[i].Items = itemsByTransactionID[transactions[i].ID]
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
		return Transaction{}, apperror.InternalFromContext(ctx, "getting transaction", err)
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
  i.deleted_at IS NOT NULL AS deleted,
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
		return nil, apperror.InternalFromContext(ctx, "listing enriched transactions", err)
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
			&row.ItemDeleted,
			&row.Amount,
		); err != nil {
			return nil, apperror.InternalFromContext(ctx, "scanning enriched transaction", err)
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
				ID:      row.ItemID,
				Name:    row.ItemName,
				Deleted: row.ItemDeleted,
			},
			Amount: row.Amount,
		})
	}
	if err := rows.Err(); err != nil {
		return nil, apperror.InternalFromContext(ctx, "iterating enriched transactions", err)
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
		return nil, apperror.InternalFromContext(ctx, "listing transaction items", err)
	}
	defer rows.Close()

	items := make([]Item, 0, 20)
	for rows.Next() {
		var item Item
		if err := rows.Scan(&item.ItemID, &item.Amount); err != nil {
			return nil, apperror.InternalFromContext(ctx, "scanning transaction item", err)
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, apperror.InternalFromContext(ctx, "iterating transaction items", err)
	}
	return items, nil
}

func (r *PostgresRepository) listItemsByTransactionIDs(ctx context.Context, transactionIDs []string) (map[string][]Item, error) {
	query, args := buildListItemsByTransactionIDsQuery(transactionIDs)
	rows, err := r.db.Query(ctx, query, args...)
	if err != nil {
		return nil, apperror.InternalFromContext(ctx, "listing transaction items", err)
	}
	defer rows.Close()

	itemsByTransactionID := make(map[string][]Item, len(transactionIDs))
	for _, transactionID := range transactionIDs {
		itemsByTransactionID[transactionID] = []Item{}
	}

	for rows.Next() {
		var transactionID string
		var item Item
		if err := rows.Scan(&transactionID, &item.ItemID, &item.Amount); err != nil {
			return nil, apperror.InternalFromContext(ctx, "scanning transaction item", err)
		}
		itemsByTransactionID[transactionID] = append(itemsByTransactionID[transactionID], item)
	}
	if err := rows.Err(); err != nil {
		return nil, apperror.InternalFromContext(ctx, "iterating transaction items", err)
	}
	return itemsByTransactionID, nil
}

func buildListItemsByTransactionIDsQuery(transactionIDs []string) (string, []any) {
	placeholders := make([]string, len(transactionIDs))
	args := make([]any, 0, len(transactionIDs))
	for i, transactionID := range transactionIDs {
		placeholders[i] = fmt.Sprintf("$%d::uuid", i+1)
		args = append(args, transactionID)
	}

	query := fmt.Sprintf(`
SELECT transaction_id::text, item_id::text, amount
FROM transaction_items
WHERE transaction_id IN (%s)
ORDER BY transaction_id, item_id`, strings.Join(placeholders, ", "))
	return query, args
}

func transactionIDs(transactions []Transaction) []string {
	ids := make([]string, 0, len(transactions))
	for _, transaction := range transactions {
		ids = append(ids, transaction.ID)
	}
	return ids
}

func validateItem(ctx context.Context, tx pgx.Tx, item CreateItemRequest) error {
	var availableAmount int
	if err := tx.QueryRow(ctx, `SELECT available_amount FROM items WHERE id = $1::uuid AND deleted_at IS NULL`, item.ItemID).Scan(&availableAmount); err != nil {
		if err == pgx.ErrNoRows {
			return apperror.NotFound("item not found")
		}
		return apperror.InternalFromContext(ctx, "validating item", err)
	}
	if availableAmount < item.Amount {
		return apperror.Conflict("insufficient available amount")
	}
	return nil
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
		return Transaction{}, apperror.InternalFromContext(ctx, "inserting transaction", err)
	}
	return transaction, nil
}

func isMissingTransactionUserError(err error) bool {
	pgErr, ok := errors.AsType[*pgconn.PgError](err)
	if !ok {
		return false
	}
	return pgErr.Code == "23503" && pgErr.TableName == "transactions" && pgErr.ConstraintName == "transactions_user_id_fkey"
}

func insertTransactionItem(ctx context.Context, tx pgx.Tx, transactionID string, item CreateItemRequest) error {
	const query = `
INSERT INTO transaction_items (transaction_id, item_id, amount)
VALUES ($1::uuid, $2::uuid, $3)`
	if _, err := tx.Exec(ctx, query, transactionID, item.ItemID, item.Amount); err != nil {
		return apperror.InternalFromContext(ctx, "inserting transaction item", err)
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
	ItemDeleted          bool
	Amount               int
}
