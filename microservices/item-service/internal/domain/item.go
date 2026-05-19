package domain

import "time"

type Item struct {
	ID              string
	Name            string
	AvailableAmount int
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
	AvailableAmount int
}

type TransactionItemValidationInput struct {
	ItemID string
	Amount int
}
