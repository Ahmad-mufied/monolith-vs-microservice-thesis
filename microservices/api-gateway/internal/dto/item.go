package dto

// Item request/response DTOs matching openapi.yaml schemas.

type Item struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	AvailableAmount int    `json:"available_amount"`
	CreatedAt       string `json:"created_at"`
	UpdatedAt       string `json:"updated_at"`
}

type ItemSummary struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Deleted bool   `json:"deleted"`
}

type SyncItemsRequest struct {
	Items []SyncItemInput `json:"items"`
}

type SyncItemInput struct {
	ID              *string `json:"id,omitempty"`
	Name            string  `json:"name"`
	AvailableAmount int     `json:"available_amount"`
}

type PaginationMeta struct {
	Limit         int `json:"limit"`
	Offset        int `json:"offset"`
	TotalReturned int `json:"total_returned"`
}
