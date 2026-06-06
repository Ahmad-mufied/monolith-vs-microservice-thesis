package item

import (
	"context"
	"errors"
	"fmt"
	"sort"

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

func (r *PostgresRepository) SyncItems(ctx context.Context, items []SyncItem) error {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return internalError("begin sync transaction", err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()

	keepIDs, inserts, upserts := partitionSyncItems(items)

	sort.Strings(keepIDs)
	sort.Slice(upserts, func(i, j int) bool {
		return *upserts[i].ID < *upserts[j].ID
	})

	if err := softDeleteOmittedItems(ctx, tx, keepIDs); err != nil {
		return internalError("soft delete omitted items", err)
	}
	if len(inserts) > 0 {
		if err := batchInsertItems(ctx, tx, inserts); err != nil {
			return err
		}
	}
	if len(upserts) > 0 {
		if err := batchUpsertItems(ctx, tx, upserts); err != nil {
			return err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return internalError("commit sync transaction", err)
	}
	return nil
}

func (r *PostgresRepository) List(ctx context.Context, limit, offset int) ([]Item, error) {
	const query = `
SELECT id::text, name, available_amount, deleted_at, created_at, updated_at
FROM items
WHERE deleted_at IS NULL
ORDER BY created_at DESC, id DESC
LIMIT $1 OFFSET $2`

	rows, err := r.db.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, internalError("list items", err)
	}
	defer rows.Close()

	items := make([]Item, 0, limit)
	for rows.Next() {
		item, err := scanItem(rows)
		if err != nil {
			return nil, internalError("scan item row", err)
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, internalError("iterate items", err)
	}
	return items, nil
}

func (r *PostgresRepository) GetByID(ctx context.Context, id string) (Item, error) {
	const query = `
SELECT id::text, name, available_amount, deleted_at, created_at, updated_at
FROM items
WHERE id = $1::uuid
  AND deleted_at IS NULL`

	item, err := scanItem(r.db.QueryRow(ctx, query, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return Item{}, apperror.NotFound("item not found")
	}
	if err != nil {
		return Item{}, internalError("get item by id", err)
	}
	return item, nil
}

// softDeleteOmittedItems sets deleted_at on all active items whose IDs are
// not in keepIDs. An empty keepIDs means soft-delete all active items.
func softDeleteOmittedItems(ctx context.Context, tx pgx.Tx, keepIDs []string) error {
	const selectQuery = `
SELECT id::text
FROM items
WHERE deleted_at IS NULL
  AND (
    cardinality(COALESCE($1::uuid[], ARRAY[]::uuid[])) = 0
    OR NOT (id = ANY(COALESCE($1::uuid[], ARRAY[]::uuid[])))
  )
ORDER BY id
FOR UPDATE`

	rows, err := tx.Query(ctx, selectQuery, keepIDs)
	if err != nil {
		return err
	}
	defer rows.Close()

	var idsToSoftDelete []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return err
		}
		idsToSoftDelete = append(idsToSoftDelete, id)
	}
	if err := rows.Err(); err != nil {
		return err
	}

	if len(idsToSoftDelete) == 0 {
		return nil
	}

	const updateQuery = `
UPDATE items
SET deleted_at = now(), updated_at = now()
WHERE id = ANY($1::uuid[])`

	_, err = tx.Exec(ctx, updateQuery, idsToSoftDelete)
	return err
}

// partitionSyncItems splits the payload into:
//   - keepIDs: IDs to exclude from soft-delete
//   - inserts: items without ID (DB generates UUID)
//   - upserts: items with ID (insert or reactivate)
func partitionSyncItems(items []SyncItem) (keepIDs []string, inserts []SyncItem, upserts []SyncItem) {
	for _, item := range items {
		if item.ID == nil {
			inserts = append(inserts, item)
		} else {
			keepIDs = append(keepIDs, *item.ID)
			upserts = append(upserts, item)
		}
	}
	return
}

// batchInsertItems inserts all items without a client-provided ID in one query.
func batchInsertItems(ctx context.Context, tx pgx.Tx, items []SyncItem) error {
	names := make([]string, len(items))
	amounts := make([]int, len(items))
	for i, item := range items {
		names[i] = item.Name
		amounts[i] = item.AvailableAmount
	}
	const query = `
INSERT INTO items (name, available_amount)
SELECT unnest($1::text[]), unnest($2::int[])`
	_, err := tx.Exec(ctx, query, names, amounts)
	return mapConflictError(err)
}

// batchUpsertItems upserts all items with a client-provided ID in one query,
// reactivating any that were previously soft-deleted.
func batchUpsertItems(ctx context.Context, tx pgx.Tx, items []SyncItem) error {
	ids := make([]string, len(items))
	names := make([]string, len(items))
	amounts := make([]int, len(items))
	for i, item := range items {
		ids[i] = *item.ID
		names[i] = item.Name
		amounts[i] = item.AvailableAmount
	}
	const query = `
INSERT INTO items (id, name, available_amount, deleted_at)
SELECT unnest($1::uuid[]), unnest($2::text[]), unnest($3::int[]), NULL
ON CONFLICT (id) DO UPDATE
SET name             = EXCLUDED.name,
    available_amount = EXCLUDED.available_amount,
    deleted_at       = NULL,
    updated_at       = now()`
	_, err := tx.Exec(ctx, query, ids, names, amounts)
	return mapConflictError(err)
}

// scanItem scans a row into an Item. Works with both pgx.Row and pgx.Rows.
func scanItem(row interface{ Scan(...any) error }) (Item, error) {
	var item Item
	err := row.Scan(&item.ID, &item.Name, &item.AvailableAmount, &item.DeletedAt, &item.CreatedAt, &item.UpdatedAt)
	return item, err
}

// mapConflictError translates PostgreSQL errors into domain-level errors.
//   - unique_violation (23505) → 409 Conflict
//   - serialization_failure (40001) → 409 Conflict (retryable)
//   - deadlock_detected (40P01) → 409 Conflict (retryable)
//   - query_canceled (57014) → 409 Conflict (timeout, retryable)
//   - other errors → 500 Internal Server Error
func mapConflictError(err error) error {
	if err == nil {
		return nil
	}
	pgErr, ok := errors.AsType[*pgconn.PgError](err)
	if !ok {
		return internalError("upsert item", err)
	}
	switch pgErr.Code {
	case "23505":
		return apperror.Conflict("item name already exists")
	case "40001", "40P01", "57014":
		return apperror.Conflict("transaction conflict, please retry")
	default:
		return internalError("upsert item", err)
	}
}

func internalError(action string, err error) error {
	if ctxErr := apperror.FromContext(err, "request timeout", "request canceled"); ctxErr != nil {
		return ctxErr
	}
	return apperror.Internal("internal server error", fmt.Errorf("%s: %w", action, err))
}
