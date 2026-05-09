-- +goose Up
-- Requires PostgreSQL 18+ because DEFAULT uuidv7() is used below.
CREATE TABLE items (
  id UUID PRIMARY KEY DEFAULT uuidv7(),
  name TEXT NOT NULL,
  available_amount BIGINT NOT NULL CHECK (available_amount >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ NULL
);

CREATE UNIQUE INDEX items_name_active_unique
ON items (lower(name))
WHERE deleted_at IS NULL;

-- +goose Down
DROP TABLE items;
