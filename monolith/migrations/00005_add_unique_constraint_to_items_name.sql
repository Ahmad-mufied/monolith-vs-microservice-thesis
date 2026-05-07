-- +goose Up
ALTER TABLE items
ADD CONSTRAINT items_name_key UNIQUE (name);

-- +goose Down
ALTER TABLE items
DROP CONSTRAINT IF EXISTS items_name_key;
