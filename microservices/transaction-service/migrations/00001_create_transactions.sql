-- +goose Up
-- Requires PostgreSQL 18+ because DEFAULT uuidv7() is used below.
CREATE TABLE transactions (
  id UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id UUID NOT NULL,
  status TEXT NOT NULL DEFAULT 'SUCCESS',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_transactions_user_id_created_at_id
ON transactions(user_id, created_at DESC, id DESC);

CREATE INDEX idx_transactions_created_at_id
ON transactions(created_at DESC, id DESC);

-- +goose Down
DROP TABLE transactions;
