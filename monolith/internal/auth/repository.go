package auth

import (
	"context"
	"errors"
	"log/slog"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/debuglog"
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
		level := slog.LevelError
		if apperror.IsContext(err) {
			level = slog.LevelWarn
		}

		debuglog.Error(ctx, level, "monolith auth repository failure", "monolith_auth_user_repository_failure", err,
			"repository", "auth_repository",
			"operation", "find_user_by_email",
		)
		return User{}, apperror.InternalFromContext("finding user by email", err)
	}
	return user, nil
}

func isUniqueViolation(err error) bool {
	pgErr, ok := errors.AsType[*pgconn.PgError](err)
	return ok && pgErr.Code == "23505"
}
