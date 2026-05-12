package postgres

import (
	"context"
	"errors"
	"fmt"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/domain"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type ItemRepository struct {
	pool *pgxpool.Pool
}

func NewItemRepository(pool *pgxpool.Pool) *ItemRepository {
	return &ItemRepository{pool: pool}
}

func (r *ItemRepository) SyncItems(ctx context.Context, items []domain.SyncItemInput) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return pkgerrors.Internal("internal server error", fmt.Errorf("begin sync items transaction: %w", err))
	}
	defer func() { _ = tx.Rollback(context.Background()) }()

	keepIDs, inserts, upserts := partitionSyncItems(items)

	if err := softDeleteOmittedItems(ctx, tx, keepIDs); err != nil {
		return pkgerrors.Internal("internal server error", fmt.Errorf("soft delete omitted items: %w", err))
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
		return pkgerrors.Internal("internal server error", fmt.Errorf("commit sync items transaction: %w", err))
	}
	return nil
}

func (r *ItemRepository) ListItems(ctx context.Context, limit, offset int32) ([]*domain.Item, error) {
	const query = `
SELECT id, name, available_amount, created_at, updated_at, deleted_at
FROM items
WHERE deleted_at IS NULL
ORDER BY created_at DESC, id DESC
LIMIT $1 OFFSET $2`

	rows, err := r.pool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, pkgerrors.Internal("internal server error", fmt.Errorf("list items: %w", err))
	}
	defer rows.Close()

	items := make([]*domain.Item, 0, limit)
	for rows.Next() {
		item, err := scanItem(rows)
		if err != nil {
			return nil, pkgerrors.Internal("internal server error", fmt.Errorf("scan listed items: %w", err))
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, pkgerrors.Internal("internal server error", fmt.Errorf("iterate listed items: %w", err))
	}

	return items, nil
}

func (r *ItemRepository) GetItemByID(ctx context.Context, id string) (*domain.Item, error) {
	const query = `
SELECT id, name, available_amount, created_at, updated_at, deleted_at
FROM items
WHERE id = $1::uuid
  AND deleted_at IS NULL`

	row := r.pool.QueryRow(ctx, query, id)
	item, err := scanItem(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, pkgerrors.NotFound("item not found")
	}
	if err != nil {
		return nil, pkgerrors.Internal("internal server error", fmt.Errorf("get item by id: %w", err))
	}

	return item, nil
}

func (r *ItemRepository) GetItemSummariesByIDs(ctx context.Context, ids []string) ([]*domain.ItemSummary, error) {
	if len(ids) == 0 {
		return []*domain.ItemSummary{}, nil
	}

	const query = `
SELECT id, name, deleted_at IS NOT NULL AS deleted
FROM items
WHERE id = ANY($1::uuid[])`

	rows, err := r.pool.Query(ctx, query, ids)
	if err != nil {
		return nil, pkgerrors.Internal("internal server error", fmt.Errorf("get item summaries by ids: %w", err))
	}
	defer rows.Close()

	items := make([]*domain.ItemSummary, 0, len(ids))
	for rows.Next() {
		var item domain.ItemSummary
		if err := rows.Scan(&item.ID, &item.Name, &item.Deleted); err != nil {
			return nil, pkgerrors.Internal("internal server error", fmt.Errorf("scan item summaries: %w", err))
		}
		items = append(items, &item)
	}
	if err := rows.Err(); err != nil {
		return nil, pkgerrors.Internal("internal server error", fmt.Errorf("iterate item summaries: %w", err))
	}

	return items, nil
}

func (r *ItemRepository) ValidateTransactionItems(ctx context.Context, items []domain.TransactionItemValidationInput) error {
	if len(items) == 0 {
		return nil
	}

	itemIDs := make([]string, 0, len(items))
	requestedAmounts := make(map[string]int64, len(items))
	for _, item := range items {
		itemIDs = append(itemIDs, item.ItemID)
		requestedAmounts[item.ItemID] = item.Amount
	}

	const query = `
SELECT id, available_amount
FROM items
WHERE deleted_at IS NULL
  AND id = ANY($1::uuid[])`

	rows, err := r.pool.Query(ctx, query, itemIDs)
	if err != nil {
		return pkgerrors.Internal("internal server error", fmt.Errorf("validate transaction items: %w", err))
	}
	defer rows.Close()

	found := make(map[string]int64, len(items))
	for rows.Next() {
		var itemID string
		var availableAmount int64
		if err := rows.Scan(&itemID, &availableAmount); err != nil {
			return pkgerrors.Internal("internal server error", fmt.Errorf("scan validated items: %w", err))
		}
		found[itemID] = availableAmount
	}
	if err := rows.Err(); err != nil {
		return pkgerrors.Internal("internal server error", fmt.Errorf("iterate validated items: %w", err))
	}

	if len(found) != len(requestedAmounts) {
		return pkgerrors.NotFound("item not found")
	}

	for itemID, requestedAmount := range requestedAmounts {
		if requestedAmount > found[itemID] {
			return pkgerrors.FailedPrecondition("requested amount exceeds available amount")
		}
	}

	return nil
}

// softDeleteOmittedItems sets deleted_at on all active items whose IDs are
// not in keepIDs. An empty keepIDs means soft-delete all active items.
func softDeleteOmittedItems(ctx context.Context, tx pgx.Tx, keepIDs []string) error {
	const softDeleteOmittedItemsQuery = `
UPDATE items
SET deleted_at = now(), updated_at = now()
WHERE deleted_at IS NULL
  AND (
    cardinality(COALESCE($1::uuid[], ARRAY[]::uuid[])) = 0
    OR NOT (id = ANY(COALESCE($1::uuid[], ARRAY[]::uuid[])))
  )`
	_, err := tx.Exec(ctx, softDeleteOmittedItemsQuery, keepIDs)
	return err
}

// partitionSyncItems splits the payload into:
//   - keepIDs: IDs to exclude from soft-delete
//   - inserts: items without ID (DB generates UUID)
//   - upserts: items with ID (insert or reactivate)
func partitionSyncItems(items []domain.SyncItemInput) (keepIDs []string, inserts []domain.SyncItemInput, upserts []domain.SyncItemInput) {
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
func batchInsertItems(ctx context.Context, tx pgx.Tx, items []domain.SyncItemInput) error {
	names := make([]string, len(items))
	amounts := make([]int64, len(items))
	for i, item := range items {
		names[i] = item.Name
		amounts[i] = item.AvailableAmount
	}
	const query = `
INSERT INTO items (name, available_amount)
SELECT unnest($1::text[]), unnest($2::bigint[])`
	_, err := tx.Exec(ctx, query, names, amounts)
	return mapConflictError(err)
}

// batchUpsertItems upserts all items with a client-provided ID in one query,
// reactivating any that were previously soft-deleted.
func batchUpsertItems(ctx context.Context, tx pgx.Tx, items []domain.SyncItemInput) error {
	ids := make([]string, len(items))
	names := make([]string, len(items))
	amounts := make([]int64, len(items))
	for i, item := range items {
		ids[i] = *item.ID
		names[i] = item.Name
		amounts[i] = item.AvailableAmount
	}
	const query = `
INSERT INTO items (id, name, available_amount, deleted_at)
SELECT unnest($1::uuid[]), unnest($2::text[]), unnest($3::bigint[]), NULL
ON CONFLICT (id) DO UPDATE
SET name             = EXCLUDED.name,
    available_amount = EXCLUDED.available_amount,
    deleted_at       = NULL,
    updated_at       = now()`
	_, err := tx.Exec(ctx, query, ids, names, amounts)
	return mapConflictError(err)
}

// scanItem scans a row into a domain.Item. Works with both pgx.Row and pgx.Rows.
func scanItem(row interface{ Scan(dest ...any) error }) (*domain.Item, error) {
	var item domain.Item
	if err := row.Scan(
		&item.ID,
		&item.Name,
		&item.AvailableAmount,
		&item.CreatedAt,
		&item.UpdatedAt,
		&item.DeletedAt,
	); err != nil {
		return nil, err
	}
	return &item, nil
}

// mapConflictError translates a PostgreSQL unique-violation (23505) into a
// domain-level Conflict error. Other errors are returned as Internal.
func mapConflictError(err error) error {
	if err == nil {
		return nil
	}
	if pgErr, ok := errors.AsType[*pgconn.PgError](err); ok && pgErr.Code == "23505" {
		return pkgerrors.Conflict("item name already exists")
	}
	return pkgerrors.Internal("internal server error", fmt.Errorf("upsert item: %w", err))
}
