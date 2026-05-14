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
				INSERT INTO users (name, email, password_hash)
				VALUES ($1, $2, $3)
			`, user.Name, user.Email, string(hash)); err != nil {
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
	`, item.ID, item.Name, item.AvailableAmount)
	return err
}

func (c MonolithConfig) validate() error {
	if strings.TrimSpace(c.DatabaseURL) == "" {
		return fmt.Errorf("monolith database url is required")
	}
	return nil
}
