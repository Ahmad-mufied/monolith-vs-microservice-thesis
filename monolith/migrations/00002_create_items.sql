-- +goose Up
-- Requires PostgreSQL 18+ because DEFAULT uuidv7() is used below.
CREATE TABLE items (
  id UUID PRIMARY KEY DEFAULT uuidv7(),
  name TEXT NOT NULL,
  available_amount INT NOT NULL CHECK (available_amount >= 0),
  deleted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE items;
