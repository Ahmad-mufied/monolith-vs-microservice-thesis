package dto

// Transaction request/response DTOs matching openapi.yaml schemas.

type CreateTransactionRequest struct {
	Items []CreateTransactionItemRequest `json:"items"`
}

type CreateTransactionItemRequest struct {
	ItemID string `json:"item_id"`
	Amount int64  `json:"amount"`
}

type TransactionItem struct {
	ItemID string `json:"item_id"`
	Amount int64  `json:"amount"`
}

type Transaction struct {
	ID        string            `json:"id"`
	UserID    string            `json:"user_id"`
	Items     []TransactionItem `json:"items"`
	CreatedAt string            `json:"created_at"`
	UpdatedAt string            `json:"updated_at"`
}

type EnrichedTransactionItem struct {
	Item   ItemSummary `json:"item"`
	Amount int64       `json:"amount"`
}

type EnrichedTransaction struct {
	ID        string                    `json:"id"`
	User      UserSummary               `json:"user"`
	Items     []EnrichedTransactionItem `json:"items"`
	CreatedAt string                    `json:"created_at"`
	UpdatedAt string                    `json:"updated_at"`
}
