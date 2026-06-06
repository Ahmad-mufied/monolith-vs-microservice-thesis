package postgres

import (
	"context"
	"errors"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/domain"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type UserRepository struct {
	pool *pgxpool.Pool
}

func NewUserRepository(pool *pgxpool.Pool) *UserRepository {
	return &UserRepository{pool: pool}
}

func (r *UserRepository) Insert(ctx context.Context, name, email, passwordHash string) (*domain.User, error) {
	const query = `
INSERT INTO users (name, email, password_hash)
VALUES ($1, lower($2), $3)
RETURNING id, name, email, password_hash, created_at, updated_at;
`

	var user domain.User
	err := r.pool.QueryRow(ctx, query, name, email, passwordHash).Scan(
		&user.ID,
		&user.Name,
		&user.Email,
		&user.PasswordHash,
		&user.CreatedAt,
		&user.UpdatedAt,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, pkgerrors.Conflict("email already exists")
		}
		return nil, pkgerrors.InternalFromContext("insert user", err)
	}
	return &user, nil
}

func (r *UserRepository) FindByEmail(ctx context.Context, email string) (*domain.User, error) {
	const query = `
SELECT id, name, email, password_hash, created_at, updated_at
FROM users
WHERE lower(email) = lower($1);
`

	var user domain.User
	err := r.pool.QueryRow(ctx, query, email).Scan(
		&user.ID,
		&user.Name,
		&user.Email,
		&user.PasswordHash,
		&user.CreatedAt,
		&user.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, pkgerrors.NotFound("user not found")
	}
	if err != nil {
		return nil, pkgerrors.InternalFromContext("find user by email", err)
	}
	return &user, nil
}

func (r *UserRepository) FindByID(ctx context.Context, id string) (*domain.User, error) {
	const query = `
SELECT id, name, email, password_hash, created_at, updated_at
FROM users
WHERE id = $1::uuid;
`

	var user domain.User
	err := r.pool.QueryRow(ctx, query, id).Scan(
		&user.ID,
		&user.Name,
		&user.Email,
		&user.PasswordHash,
		&user.CreatedAt,
		&user.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, pkgerrors.NotFound("user not found")
	}
	if err != nil {
		return nil, pkgerrors.InternalFromContext("find user by id", err)
	}
	return &user, nil
}

func (r *UserRepository) FindByIDs(ctx context.Context, ids []string) ([]*domain.User, error) {
	const query = `
SELECT id, name, email, password_hash, created_at, updated_at
FROM users
WHERE id = ANY($1::uuid[]);
`

	rows, err := r.pool.Query(ctx, query, ids)
	if err != nil {
		return nil, pkgerrors.InternalFromContext("find users by ids", err)
	}
	defer rows.Close()

	users := make([]*domain.User, 0, len(ids))
	for rows.Next() {
		var user domain.User
		if err := rows.Scan(
			&user.ID,
			&user.Name,
			&user.Email,
			&user.PasswordHash,
			&user.CreatedAt,
			&user.UpdatedAt,
		); err != nil {
			return nil, pkgerrors.InternalFromContext("scan users by ids", err)
		}
		users = append(users, &user)
	}
	if err := rows.Err(); err != nil {
		return nil, pkgerrors.InternalFromContext("iterate users by ids", err)
	}
	return users, nil
}
