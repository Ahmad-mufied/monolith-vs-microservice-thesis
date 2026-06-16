package postgres

import (
	"context"
	"errors"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/domain"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/port"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const rollbackTimeout = 5 * time.Second

type TransactionRepository struct {
	pool *pgxpool.Pool
}

func NewTransactionRepository(pool *pgxpool.Pool) *TransactionRepository {
	return &TransactionRepository{pool: pool}
}

func (r *TransactionRepository) BeginTx(ctx context.Context) (port.TransactionWriteTx, error) {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, pkgerrors.InternalFromContext(ctx, "begin transaction", err)
	}
	return &transactionWriteTx{tx: tx}, nil
}

func (r *TransactionRepository) ListByUserID(ctx context.Context, userID string, limit, offset int32) ([]*domain.Transaction, error) {
	const query = `
SELECT id, user_id, created_at, updated_at
FROM transactions
WHERE user_id = $1::uuid
ORDER BY created_at DESC, id DESC
LIMIT $2 OFFSET $3;
`

	rows, err := r.pool.Query(ctx, query, userID, limit, offset)
	if err != nil {
		return nil, pkgerrors.InternalFromContext(ctx, "list own transactions", err)
	}
	defer rows.Close()

	return scanTransactions(ctx, rows, "scan own transactions")
}

func (r *TransactionRepository) GetByIDAndUserID(ctx context.Context, transactionID, userID string) (*domain.Transaction, error) {
	const query = `
SELECT id, user_id, created_at, updated_at
FROM transactions
WHERE id = $1::uuid
  AND user_id = $2::uuid;
`

	row := r.pool.QueryRow(ctx, query, transactionID, userID)

	var transaction domain.Transaction
	if err := row.Scan(&transaction.ID, &transaction.UserID, &transaction.CreatedAt, &transaction.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, pkgerrors.NotFound("transaction not found")
		}
		return nil, pkgerrors.InternalFromContext(ctx, "get transaction by id", err)
	}

	return &transaction, nil
}

func (r *TransactionRepository) ListForEnrichment(ctx context.Context, limit, offset int32) ([]*domain.Transaction, error) {
	const query = `
SELECT id, user_id, created_at, updated_at
FROM transactions
ORDER BY created_at DESC, id DESC
LIMIT $1 OFFSET $2;
`

	rows, err := r.pool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, pkgerrors.InternalFromContext(ctx, "list transactions for enrichment", err)
	}
	defer rows.Close()

	return scanTransactions(ctx, rows, "scan enrichment transactions")
}

func (r *TransactionRepository) ListItemsByTransactionIDs(ctx context.Context, transactionIDs []string) (map[string][]domain.TransactionItem, error) {
	if len(transactionIDs) == 0 {
		return map[string][]domain.TransactionItem{}, nil
	}

	const query = `
SELECT transaction_id, item_id, amount
FROM transaction_items
WHERE transaction_id = ANY($1::uuid[])
ORDER BY transaction_id, created_at ASC, item_id ASC;
`

	rows, err := r.pool.Query(ctx, query, transactionIDs)
	if err != nil {
		return nil, pkgerrors.InternalFromContext(ctx, "list transaction items", err)
	}
	defer rows.Close()

	itemsByTransactionID := make(map[string][]domain.TransactionItem, len(transactionIDs))
	for rows.Next() {
		var transactionID string
		var item domain.TransactionItem
		if err := rows.Scan(&transactionID, &item.ItemID, &item.Amount); err != nil {
			return nil, pkgerrors.InternalFromContext(ctx, "scan transaction items", err)
		}
		itemsByTransactionID[transactionID] = append(itemsByTransactionID[transactionID], item)
	}
	if err := rows.Err(); err != nil {
		return nil, pkgerrors.InternalFromContext(ctx, "iterate transaction items", err)
	}

	return itemsByTransactionID, nil
}

type transactionWriteTx struct {
	tx pgx.Tx
}

func (t *transactionWriteTx) InsertTransaction(ctx context.Context, userID string) (string, error) {
	const query = `
INSERT INTO transactions (user_id)
VALUES ($1::uuid)
RETURNING id;
`

	var transactionID string
	if err := t.tx.QueryRow(ctx, query, userID).Scan(&transactionID); err != nil {
		return "", pkgerrors.InternalFromContext(ctx, "insert transaction", err)
	}
	return transactionID, nil
}

func (t *transactionWriteTx) InsertTransactionItems(ctx context.Context, transactionID string, items []domain.TransactionItem) error {
	const query = `
INSERT INTO transaction_items (transaction_id, item_id, amount)
VALUES ($1::uuid, $2::uuid, $3);
`

	for _, item := range items {
		if _, err := t.tx.Exec(ctx, query, transactionID, item.ItemID, item.Amount); err != nil {
			return pkgerrors.InternalFromContext(ctx, "insert transaction item", err)
		}
	}

	return nil
}

func (t *transactionWriteTx) Commit(ctx context.Context) error {
	if err := t.tx.Commit(ctx); err != nil {
		return pkgerrors.InternalFromContext(ctx, "commit transaction", err)
	}
	return nil
}

func (t *transactionWriteTx) Rollback() error {
	ctx, cancel := context.WithTimeout(context.Background(), rollbackTimeout)
	defer cancel()
	return t.tx.Rollback(ctx)
}

func scanTransactions(ctx context.Context, rows pgx.Rows, action string) ([]*domain.Transaction, error) {
	transactions := make([]*domain.Transaction, 0)
	for rows.Next() {
		var transaction domain.Transaction
		if err := rows.Scan(&transaction.ID, &transaction.UserID, &transaction.CreatedAt, &transaction.UpdatedAt); err != nil {
			return nil, pkgerrors.InternalFromContext(ctx, action, err)
		}
		transactions = append(transactions, &transaction)
	}
	if err := rows.Err(); err != nil {
		return nil, pkgerrors.InternalFromContext(ctx, action, err)
	}

	return transactions, nil
}
