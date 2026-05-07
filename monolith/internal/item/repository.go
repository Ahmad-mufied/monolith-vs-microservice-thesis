package item

import (
	"context"
	"errors"
	"fmt"
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

func (r *PostgresRepository) BulkSave(ctx context.Context, items []BulkSaveItem) error {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return apperror.Internal("internal server error", fmt.Errorf("beginning item bulk save transaction: %w", err))
	}
	finalizeCtx, finalizeCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer finalizeCancel()
	defer func() {
		_ = tx.Rollback(finalizeCtx)
	}()

	for _, item := range items {
		if err := bulkSaveItem(ctx, tx, item); err != nil {
			return err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return apperror.Internal("internal server error", fmt.Errorf("committing item bulk save transaction: %w", err))
	}
	return nil
}

func (r *PostgresRepository) List(ctx context.Context, limit, offset int) ([]Item, error) {
	const query = `
SELECT id::text, name, available_amount, created_at, updated_at
FROM items
ORDER BY created_at DESC, id DESC
LIMIT $1 OFFSET $2`
	rows, err := r.db.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, apperror.Internal("internal server error", fmt.Errorf("listing items: %w", err))
	}
	defer rows.Close()

	items := make([]Item, 0, limit)
	for rows.Next() {
		var item Item
		if err := rows.Scan(&item.ID, &item.Name, &item.AvailableAmount, &item.CreatedAt, &item.UpdatedAt); err != nil {
			return nil, apperror.Internal("internal server error", fmt.Errorf("scanning item: %w", err))
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, apperror.Internal("internal server error", fmt.Errorf("iterating items: %w", err))
	}
	return items, nil
}

func (r *PostgresRepository) GetByID(ctx context.Context, id string) (Item, error) {
	const query = `
SELECT id::text, name, available_amount, created_at, updated_at
FROM items
WHERE id = $1::uuid`
	return scanOne(r.db.QueryRow(ctx, query, id), "getting item")
}

func (r *PostgresRepository) Delete(ctx context.Context, id string) error {
	commandTag, err := r.db.Exec(ctx, `DELETE FROM items WHERE id = $1::uuid`, id)
	if err != nil {
		if isReferencedItemDeleteError(err) {
			return apperror.Conflict("item is referenced by transaction")
		}
		return apperror.Internal("internal server error", fmt.Errorf("deleting item: %w", err))
	}
	if commandTag.RowsAffected() == 0 {
		return apperror.NotFound("item not found")
	}
	return nil
}

type scanner interface {
	Scan(dest ...any) error
}

func scanOne(row scanner, contextMessage string) (Item, error) {
	var item Item
	if err := row.Scan(&item.ID, &item.Name, &item.AvailableAmount, &item.CreatedAt, &item.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Item{}, apperror.NotFound("item not found")
		}
		return Item{}, apperror.Internal("internal server error", fmt.Errorf("%s: %w", contextMessage, err))
	}
	return item, nil
}

func bulkSaveItem(ctx context.Context, tx pgx.Tx, item BulkSaveItem) error {
	if item.ID == nil {
		const insertQuery = `
INSERT INTO items (name, available_amount)
VALUES ($1, $2)
RETURNING id::text, name, available_amount, created_at, updated_at`
		if _, err := scanOne(tx.QueryRow(ctx, insertQuery, item.Name, item.AvailableAmount), "creating item during bulk save"); err != nil {
			return mapItemConflictError(err)
		}
		return nil
	}

	const upsertQuery = `
INSERT INTO items (id, name, available_amount)
VALUES ($1::uuid, $2, $3)
ON CONFLICT (id) DO UPDATE
SET
  name = EXCLUDED.name,
  available_amount = EXCLUDED.available_amount,
  updated_at = now()
RETURNING id::text, name, available_amount, created_at, updated_at`
	if _, err := scanOne(tx.QueryRow(ctx, upsertQuery, *item.ID, item.Name, item.AvailableAmount), "saving item during bulk save"); err != nil {
		return mapItemConflictError(err)
	}
	return nil
}

func mapItemConflictError(err error) error {
	if isUniqueViolation(err) {
		return apperror.Conflict("item name already exists")
	}
	return err
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

func isReferencedItemDeleteError(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	return pgErr.Code == "23503" && pgErr.TableName == "transaction_items" && pgErr.ConstraintName == "transaction_items_item_id_fkey"
}
