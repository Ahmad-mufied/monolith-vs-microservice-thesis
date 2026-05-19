package domain

import "time"

type Transaction struct {
	ID        string
	UserID    string
	Items     []TransactionItem
	CreatedAt time.Time
	UpdatedAt time.Time
}

type TransactionItem struct {
	ItemID string
	Amount int
}
