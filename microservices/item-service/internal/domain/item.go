package domain

import "time"

type Item struct {
	ID              string
	Name            string
	AvailableAmount int64
	CreatedAt       time.Time
	UpdatedAt       time.Time
	DeletedAt       *time.Time
}

type ItemSummary struct {
	ID      string
	Name    string
	Deleted bool
}

type SyncItemInput struct {
	ID              *string
	Name            string
	AvailableAmount int64
}

type TransactionItemValidationInput struct {
	ItemID string
	Amount int64
}
