package auth

import (
	"context"
	"errors"

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

func (r *PostgresRepository) CreateUser(ctx context.Context, name, email, passwordHash string) (User, error) {
	const query = `
INSERT INTO users (name, email, password_hash)
VALUES ($1, $2, $3)
RETURNING id::text, name, email, password_hash, created_at, updated_at`

	var user User
	if err := r.db.QueryRow(ctx, query, name, email, passwordHash).Scan(
		&user.ID,
		&user.Name,
		&user.Email,
		&user.PasswordHash,
		&user.CreatedAt,
		&user.UpdatedAt,
	); err != nil {
		if isUniqueViolation(err) {
			return User{}, apperror.Conflict("email already exists")
		}
		return User{}, apperror.InternalFromContext("creating user", err)
	}
	return user, nil
}

func (r *PostgresRepository) FindUserByEmail(ctx context.Context, email string) (User, error) {
	const query = `
SELECT id::text, name, email, password_hash, created_at, updated_at
FROM users
WHERE lower(email) = lower($1)`

	var user User
	if err := r.db.QueryRow(ctx, query, email).Scan(
		&user.ID,
		&user.Name,
		&user.Email,
		&user.PasswordHash,
		&user.CreatedAt,
		&user.UpdatedAt,
	); err != nil {
		if err == pgx.ErrNoRows {
			return User{}, apperror.Unauthorized("invalid email or password")
		}
		return User{}, apperror.InternalFromContext("finding user by email", err)
	}
	return user, nil
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}
