package seed

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
)

type MonolithConfig struct {
	DatabaseURL string
}

func ResetMonolithData(ctx context.Context, cfg MonolithConfig) error {
	if err := cfg.validate(); err != nil {
		return err
	}

	return withPool(ctx, cfg.DatabaseURL, func(pool *pgxpool.Pool) error {
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)

		statements := []string{
			`DELETE FROM transaction_items`,
			`DELETE FROM transactions`,
			`DELETE FROM items`,
			`DELETE FROM users`,
		}

		for _, stmt := range statements {
			if _, err := tx.Exec(ctx, stmt); err != nil {
				return err
			}
		}

		return tx.Commit(ctx)
	})
}

func SeedMonolithData(ctx context.Context, cfg MonolithConfig, mode string) error {
	if err := cfg.validate(); err != nil {
		return err
	}

	ds, err := buildDataset(mode)
	if err != nil {
		return err
	}

	return withPool(ctx, cfg.DatabaseURL, func(pool *pgxpool.Pool) error {
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

			if _, err := tx.Exec(ctx, `
				INSERT INTO users (id, name, email, password_hash)
				VALUES ($1, $2, $3, $4)
				ON CONFLICT (id) DO UPDATE
				SET
					name = EXCLUDED.name,
					email = EXCLUDED.email,
					password_hash = EXCLUDED.password_hash
			`, user.ID, user.Name, user.Email, string(hash)); err != nil {
				return err
			}
		}

		for _, item := range ds.Items {
			if err := insertMonolithItem(ctx, tx, item); err != nil {
				return err
			}
		}

		return tx.Commit(ctx)
	})
}

func PrepareMonolithEnrichmentData(ctx context.Context, cfg MonolithConfig, mode string) error {
	if err := cfg.validate(); err != nil {
		return err
	}

	spec, err := buildEnrichmentDatasetSpec(mode)
	if err != nil {
		return err
	}

	return withPool(ctx, cfg.DatabaseURL, func(pool *pgxpool.Pool) error {
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)

		userIDs, err := loadOrderedIDs(ctx, tx, `SELECT id::text FROM users ORDER BY email ASC, id ASC`, spec.RequiredUsers, "base users")
		if err != nil {
			return err
		}

		itemIDs, err := loadOrderedIDs(ctx, tx, `SELECT id::text FROM items ORDER BY name ASC, id ASC`, spec.RequiredItems, "base items")
		if err != nil {
			return err
		}

		transactions, err := buildEnrichmentTransactions(spec, userIDs, itemIDs)
		if err != nil {
			return err
		}

		if err := insertEnrichmentTransactions(ctx, tx, transactions); err != nil {
			return err
		}

		return tx.Commit(ctx)
	})
}

func insertMonolithItem(ctx context.Context, tx pgx.Tx, item itemSeed) error {
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

func (c MonolithConfig) validate() error {
	if strings.TrimSpace(c.DatabaseURL) == "" {
		return fmt.Errorf("monolith database url is required")
	}
	return nil
}
