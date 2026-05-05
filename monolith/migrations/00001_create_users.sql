-- +goose Up
-- Requires PostgreSQL 18+ because DEFAULT uuidv7() is used below.
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT uuidv7(),
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_users_email_lower_unique
ON users (lower(email));

-- +goose Down
DROP TABLE users;
