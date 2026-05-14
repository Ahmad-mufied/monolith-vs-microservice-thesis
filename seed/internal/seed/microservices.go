package seed

import (
	"context"
	"fmt"
	"strings"

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

		for _, user := range ds.Users {
			hash, err := bcrypt.GenerateFromPassword([]byte(user.Password), 12)
			if err != nil {
				return err
			}
			_, err = tx.Exec(ctx, `
				INSERT INTO users (name, email, password_hash)
				VALUES ($1, $2, $3)
				ON CONFLICT (email) DO UPDATE
				SET
					name = EXCLUDED.name,
					password_hash = EXCLUDED.password_hash
			`, user.Name, user.Email, string(hash))
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
			{Name: "Smoke User 1", Email: "smoke-user-1@example.com", Password: "Password123!"},
			{Name: "Smoke User 2", Email: "smoke-user-2@example.com", Password: "Password123!"},
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
		users = append(users, userSeed{
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
