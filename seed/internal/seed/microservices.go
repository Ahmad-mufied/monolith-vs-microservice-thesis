package seed

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
)

type MicroservicesConfig struct {
	AuthDatabaseURL        string
	ItemDatabaseURL        string
	TransactionDatabaseURL string
}

type userSeed struct {
	ID       string
	Name     string
	Email    string
	Password string
}

type itemSeed struct {
	ID              string
	Name            string
	AvailableAmount int64
}

type dataset struct {
	Users []userSeed
	Items []itemSeed
}

const (
	smokeEnrichmentTransactionCount     = 12
	benchmarkEnrichmentTransactionCount = 240
)

type enrichmentDatasetSpec struct {
	Mode             string
	RequiredUsers    int
	RequiredItems    int
	TransactionCount int
	AnchorTime       time.Time
}

type enrichmentTransaction struct {
	UserID    string
	CreatedAt time.Time
	Items     []enrichmentTransactionItem
}

type enrichmentTransactionItem struct {
	ItemID    string
	Amount    int64
	CreatedAt time.Time
}

func ResetMicroservicesData(ctx context.Context, cfg MicroservicesConfig) error {
	if err := cfg.validate(); err != nil {
		return err
	}

	if err := withPool(ctx, cfg.TransactionDatabaseURL, func(pool *pgxpool.Pool) error {
		_, err := pool.Exec(ctx, `DELETE FROM transaction_items`)
		if err != nil {
			return err
		}
		_, err = pool.Exec(ctx, `DELETE FROM transactions`)
		return err
	}); err != nil {
		return fmt.Errorf("reset transaction_db: %w", err)
	}

	if err := withPool(ctx, cfg.ItemDatabaseURL, func(pool *pgxpool.Pool) error {
		_, err := pool.Exec(ctx, `DELETE FROM items`)
		return err
	}); err != nil {
		return fmt.Errorf("reset item_db: %w", err)
	}

	if err := withPool(ctx, cfg.AuthDatabaseURL, func(pool *pgxpool.Pool) error {
		_, err := pool.Exec(ctx, `DELETE FROM users`)
		return err
	}); err != nil {
		return fmt.Errorf("reset auth_db: %w", err)
	}

	return nil
}

func SeedMicroservicesData(ctx context.Context, cfg MicroservicesConfig, mode string) error {
	if err := cfg.validate(); err != nil {
		return err
	}

	ds, err := buildDataset(mode)
	if err != nil {
		return err
	}

	if err := withPool(ctx, cfg.AuthDatabaseURL, func(pool *pgxpool.Pool) error {
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)

		passwordHashes := make(map[string]string, len(ds.Users))

		for _, user := range ds.Users {
			hash, ok := passwordHashes[user.Password]
			if !ok {
				encoded, err := bcrypt.GenerateFromPassword([]byte(user.Password), 12)
				if err != nil {
					return err
				}
				hash = string(encoded)
				passwordHashes[user.Password] = hash
			}
			_, err = tx.Exec(ctx, `
				INSERT INTO users (id, name, email, password_hash)
				VALUES ($1, $2, $3, $4)
				ON CONFLICT (id) DO UPDATE
				SET
					name = EXCLUDED.name,
					email = EXCLUDED.email,
					password_hash = EXCLUDED.password_hash
			`, user.ID, user.Name, user.Email, hash)
			if err != nil {
				return err
			}
		}
		return tx.Commit(ctx)
	}); err != nil {
		return fmt.Errorf("seed auth_db: %w", err)
	}

	if err := withPool(ctx, cfg.ItemDatabaseURL, func(pool *pgxpool.Pool) error {
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)

		for _, item := range ds.Items {
			if err := insertMicroserviceItem(ctx, tx, item); err != nil {
				return err
			}
		}
		return tx.Commit(ctx)
	}); err != nil {
		return fmt.Errorf("seed item_db: %w", err)
	}

	return nil
}

func PrepareMicroservicesEnrichmentData(ctx context.Context, cfg MicroservicesConfig, mode string) error {
	if err := cfg.validate(); err != nil {
		return err
	}

	spec, err := buildEnrichmentDatasetSpec(mode)
	if err != nil {
		return err
	}

	userIDs, err := loadOrderedUserIDs(ctx, cfg.AuthDatabaseURL, spec.RequiredUsers)
	if err != nil {
		return err
	}

	itemIDs, err := loadOrderedItemIDs(ctx, cfg.ItemDatabaseURL, spec.RequiredItems)
	if err != nil {
		return err
	}

	transactions, err := buildEnrichmentTransactions(spec, userIDs, itemIDs)
	if err != nil {
		return err
	}

	return withPool(ctx, cfg.TransactionDatabaseURL, func(pool *pgxpool.Pool) error {
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)

		if err := insertEnrichmentTransactions(ctx, tx, transactions); err != nil {
			return err
		}

		return tx.Commit(ctx)
	})
}

func insertMicroserviceItem(ctx context.Context, tx pgx.Tx, item itemSeed) error {
	if item.ID == "" {
		_, err := tx.Exec(ctx, `
			INSERT INTO items (name, available_amount)
			VALUES ($1, $2)
		`, item.Name, item.AvailableAmount)
		return err
	}

	_, err := tx.Exec(ctx, `
		INSERT INTO items (id, name, available_amount)
		VALUES ($1, $2, $3)
		ON CONFLICT (id) DO UPDATE
		SET
			name = EXCLUDED.name,
			available_amount = EXCLUDED.available_amount
	`, item.ID, item.Name, item.AvailableAmount)
	return err
}

func (c MicroservicesConfig) validate() error {
	if strings.TrimSpace(c.AuthDatabaseURL) == "" {
		return fmt.Errorf("auth database url is required")
	}
	if strings.TrimSpace(c.ItemDatabaseURL) == "" {
		return fmt.Errorf("item database url is required")
	}
	if strings.TrimSpace(c.TransactionDatabaseURL) == "" {
		return fmt.Errorf("transaction database url is required")
	}
	return nil
}

func withPool(ctx context.Context, databaseURL string, fn func(pool *pgxpool.Pool) error) error {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	if err := pool.Ping(ctx); err != nil {
		return err
	}

	return fn(pool)
}

func buildDataset(mode string) (*dataset, error) {
	switch mode {
	case "smoke":
		return smokeDataset(), nil
	case "benchmark":
		return benchmarkDataset(), nil
	default:
		return nil, fmt.Errorf("unsupported dataset mode %q", mode)
	}
}

func smokeDataset() *dataset {
	return &dataset{
		Users: []userSeed{
			{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f1001", Name: "Smoke User 1", Email: "smoke-user-1@example.com", Password: "Password123!"},
			{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f1002", Name: "Smoke User 2", Email: "smoke-user-2@example.com", Password: "Password123!"},
		},
		Items: []itemSeed{
			{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", Name: "Smoke Item A", AvailableAmount: 1000},
			{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2002", Name: "Smoke Item B", AvailableAmount: 500},
			{ID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2003", Name: "Smoke Item C", AvailableAmount: 250},
		},
	}
}

func benchmarkDataset() *dataset {
	users := make([]userSeed, 0, 100)
	items := make([]itemSeed, 0, 100)

	for i := 1; i <= 100; i++ {
		userID := uuid.MustParse(fmt.Sprintf("10000000-0000-7000-8000-%012d", i)).String()
		users = append(users, userSeed{
			ID:       userID,
			Name:     fmt.Sprintf("Benchmark User %03d", i),
			Email:    fmt.Sprintf("benchmark-user-%03d@example.com", i),
			Password: "Password123!",
		})

		itemID := uuid.MustParse(fmt.Sprintf("00000000-0000-7000-8000-%012d", i)).String()
		items = append(items, itemSeed{
			ID:              itemID,
			Name:            fmt.Sprintf("Benchmark Item %03d", i),
			AvailableAmount: int64(100 + (i % 25 * 10)),
		})
	}

	return &dataset{Users: users, Items: items}
}

func buildEnrichmentDatasetSpec(mode string) (enrichmentDatasetSpec, error) {
	switch mode {
	case "smoke":
		ds := smokeDataset()
		return enrichmentDatasetSpec{
			Mode:             mode,
			RequiredUsers:    len(ds.Users),
			RequiredItems:    len(ds.Items),
			TransactionCount: smokeEnrichmentTransactionCount,
			AnchorTime:       time.Date(2026, time.January, 1, 9, 0, 0, 0, time.UTC),
		}, nil
	case "benchmark":
		ds := benchmarkDataset()
		return enrichmentDatasetSpec{
			Mode:             mode,
			RequiredUsers:    len(ds.Users),
			RequiredItems:    len(ds.Items),
			TransactionCount: benchmarkEnrichmentTransactionCount,
			AnchorTime:       time.Date(2026, time.January, 2, 9, 0, 0, 0, time.UTC),
		}, nil
	default:
		return enrichmentDatasetSpec{}, fmt.Errorf("unsupported dataset mode %q", mode)
	}
}

func buildEnrichmentTransactions(spec enrichmentDatasetSpec, userIDs, itemIDs []string) ([]enrichmentTransaction, error) {
	if len(userIDs) < spec.RequiredUsers {
		return nil, fmt.Errorf("base users not found for dataset=%s: found %d, need at least %d; run reset + seed first", spec.Mode, len(userIDs), spec.RequiredUsers)
	}
	if len(itemIDs) < spec.RequiredItems {
		return nil, fmt.Errorf("base items not found for dataset=%s: found %d, need at least %d; run reset + seed first", spec.Mode, len(itemIDs), spec.RequiredItems)
	}

	transactions := make([]enrichmentTransaction, 0, spec.TransactionCount)
	for i := range spec.TransactionCount {
		txCreatedAt := spec.AnchorTime.Add(time.Duration(i) * time.Minute)
		itemCount := min(1+(i%3), len(itemIDs))
		selectedItemIDs := selectOrderedEnrichmentItemIDs(itemIDs, i, itemCount)
		items := make([]enrichmentTransactionItem, 0, len(selectedItemIDs))
		for j, itemID := range selectedItemIDs {
			items = append(items, enrichmentTransactionItem{
				ItemID:    itemID,
				Amount:    int64(1 + ((i + j) % 5)),
				CreatedAt: txCreatedAt.Add(time.Duration(j) * time.Second),
			})
		}
		transactions = append(transactions, enrichmentTransaction{
			UserID:    userIDs[i%len(userIDs)],
			CreatedAt: txCreatedAt,
			Items:     items,
		})
	}

	return transactions, nil
}

func selectOrderedEnrichmentItemIDs(itemIDs []string, transactionIndex, itemCount int) []string {
	selected := make([]string, 0, itemCount)
	start := (transactionIndex * 2) % len(itemIDs)
	for i := range itemCount {
		selected = append(selected, itemIDs[(start+i)%len(itemIDs)])
	}
	slices.Sort(selected)
	return selected
}

func loadOrderedUserIDs(ctx context.Context, databaseURL string, required int) ([]string, error) {
	return loadOrderedIDsFromPool(ctx, databaseURL, `SELECT id::text FROM users ORDER BY email ASC, id ASC`, required, "base users")
}

func loadOrderedItemIDs(ctx context.Context, databaseURL string, required int) ([]string, error) {
	return loadOrderedIDsFromPool(ctx, databaseURL, `SELECT id::text FROM items ORDER BY name ASC, id ASC`, required, "base items")
}

func loadOrderedIDsFromPool(ctx context.Context, databaseURL, query string, required int, label string) ([]string, error) {
	var ids []string
	err := withPool(ctx, databaseURL, func(pool *pgxpool.Pool) error {
		var err error
		ids, err = loadOrderedIDs(ctx, pool, query, required, label)
		return err
	})
	return ids, err
}

type orderedIDQueryer interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

func loadOrderedIDs(ctx context.Context, queryer orderedIDQueryer, query string, required int, label string) ([]string, error) {
	rows, err := queryer.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("load %s: %w", label, err)
	}
	defer rows.Close()

	ids := make([]string, 0, required)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scan %s: %w", label, err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate %s: %w", label, err)
	}
	if len(ids) < required {
		return nil, fmt.Errorf("%s not found for dataset preparation: found %d, need at least %d; run reset + seed first", label, len(ids), required)
	}

	return ids, nil
}

func insertEnrichmentTransactions(ctx context.Context, tx pgx.Tx, transactions []enrichmentTransaction) error {
	const insertTransactionQuery = `
		INSERT INTO transactions (user_id, status, created_at, updated_at)
		VALUES ($1::uuid, 'SUCCESS', $2, $2)
		RETURNING id
	`
	const insertTransactionItemQuery = `
		INSERT INTO transaction_items (transaction_id, item_id, amount, created_at, updated_at)
		VALUES ($1::uuid, $2::uuid, $3, $4, $4)
	`

	for _, transaction := range transactions {
		var transactionID string
		if err := tx.QueryRow(ctx, insertTransactionQuery, transaction.UserID, transaction.CreatedAt).Scan(&transactionID); err != nil {
			return fmt.Errorf("insert enrichment transaction: %w", err)
		}
		for _, item := range transaction.Items {
			if _, err := tx.Exec(ctx, insertTransactionItemQuery, transactionID, item.ItemID, item.Amount, item.CreatedAt); err != nil {
				return fmt.Errorf("insert enrichment transaction item: %w", err)
			}
		}
	}

	return nil
}
