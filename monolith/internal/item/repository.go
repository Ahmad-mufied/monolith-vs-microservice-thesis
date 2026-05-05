package item

import (
	"context"
	"fmt"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type PostgresRepository struct {
	db *pgxpool.Pool
}

func NewPostgresRepository(db *pgxpool.Pool) *PostgresRepository {
	return &PostgresRepository{db: db}
}

func (r *PostgresRepository) Create(ctx context.Context, name string, availableAmount int) (Item, error) {
	const query = `
INSERT INTO items (name, available_amount)
VALUES ($1, $2)
RETURNING id::text, name, available_amount, created_at, updated_at`
	return scanOne(r.db.QueryRow(ctx, query, name, availableAmount), "creating item")
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

	items := make([]Item, 0)
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

func (r *PostgresRepository) Update(ctx context.Context, id string, name *string, availableAmount *int) (Item, error) {
	const query = `
UPDATE items
SET
  name = CASE WHEN $2 THEN $3 ELSE name END,
  available_amount = CASE WHEN $4 THEN $5 ELSE available_amount END,
  updated_at = now()
WHERE id = $1::uuid
RETURNING id::text, name, available_amount, created_at, updated_at`

	hasName := name != nil
	nameValue := ""
	if name != nil {
		nameValue = *name
	}
	hasAmount := availableAmount != nil
	amountValue := 0
	if availableAmount != nil {
		amountValue = *availableAmount
	}

	return scanOne(r.db.QueryRow(ctx, query, id, hasName, nameValue, hasAmount, amountValue), "updating item")
}

func (r *PostgresRepository) Delete(ctx context.Context, id string) error {
	commandTag, err := r.db.Exec(ctx, `DELETE FROM items WHERE id = $1::uuid`, id)
	if err != nil {
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
		if err == pgx.ErrNoRows {
			return Item{}, apperror.NotFound("item not found")
		}
		return Item{}, apperror.Internal("internal server error", fmt.Errorf("%s: %w", contextMessage, err))
	}
	return item, nil
}
