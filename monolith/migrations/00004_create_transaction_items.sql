-- +goose Up
CREATE TABLE transaction_items (
  transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  item_id UUID NOT NULL REFERENCES items(id),
  amount INT NOT NULL CHECK (amount > 0),
  available_amount_after INT NOT NULL CHECK (available_amount_after >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (transaction_id, item_id)
);

CREATE INDEX idx_transaction_items_item_id
ON transaction_items(item_id);

-- +goose Down
DROP TABLE transaction_items;
