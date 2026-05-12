package transaction

import "time"

type Transaction struct {
	ID        string
	UserID    string
	Items     []Item
	CreatedAt time.Time
	UpdatedAt time.Time
}

type Item struct {
	ItemID string
	Amount int
}

type EnrichedTransaction struct {
	ID        string
	User      User
	Items     []EnrichedItem
	CreatedAt time.Time
	UpdatedAt time.Time
}

type User struct {
	ID        string
	Name      string
	Email     string
	CreatedAt time.Time
	UpdatedAt time.Time
}

type EnrichedItem struct {
	Item   ItemDetail
	Amount int
}

type ItemDetail struct {
	ID      string
	Name    string
	Deleted bool
}

type Response struct {
	ID        string         `json:"id"`
	UserID    string         `json:"user_id"`
	Items     []ItemResponse `json:"items"`
	CreatedAt time.Time      `json:"created_at"`
	UpdatedAt time.Time      `json:"updated_at"`
}

type ItemResponse struct {
	ItemID string `json:"item_id"`
	Amount int    `json:"amount"`
}

type EnrichedResponse struct {
	ID        string                 `json:"id"`
	User      UserSummaryResponse    `json:"user"`
	Items     []EnrichedItemResponse `json:"items"`
	CreatedAt time.Time              `json:"created_at"`
	UpdatedAt time.Time              `json:"updated_at"`
}

type UserResponse struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Email     string    `json:"email"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type UserSummaryResponse struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}

type EnrichedItemResponse struct {
	Item   ItemSummaryResponse `json:"item"`
	Amount int                 `json:"amount"`
}

type ItemDetailResponse struct {
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	AvailableAmount int       `json:"available_amount"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

type ItemSummaryResponse struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Deleted bool   `json:"deleted"`
}

func toResponse(tx Transaction) Response {
	items := make([]ItemResponse, 0, len(tx.Items))
	for _, item := range tx.Items {
		items = append(items, ItemResponse(item))
	}
	return Response{ID: tx.ID, UserID: tx.UserID, Items: items, CreatedAt: tx.CreatedAt, UpdatedAt: tx.UpdatedAt}
}

func toResponses(transactions []Transaction) []Response {
	responses := make([]Response, 0, len(transactions))
	for _, tx := range transactions {
		responses = append(responses, toResponse(tx))
	}
	return responses
}

func toEnrichedResponse(tx EnrichedTransaction) EnrichedResponse {
	items := make([]EnrichedItemResponse, 0, len(tx.Items))
	for _, item := range tx.Items {
		items = append(items, EnrichedItemResponse{
			Item: ItemSummaryResponse{
				ID:      item.Item.ID,
				Name:    item.Item.Name,
				Deleted: item.Item.Deleted,
			},
			Amount: item.Amount,
		})
	}
	return EnrichedResponse{
		ID: tx.ID,
		User: UserSummaryResponse{
			ID:    tx.User.ID,
			Name:  tx.User.Name,
			Email: tx.User.Email,
		},
		Items:     items,
		CreatedAt: tx.CreatedAt,
		UpdatedAt: tx.UpdatedAt,
	}
}

func toEnrichedResponses(transactions []EnrichedTransaction) []EnrichedResponse {
	responses := make([]EnrichedResponse, 0, len(transactions))
	for _, tx := range transactions {
		responses = append(responses, toEnrichedResponse(tx))
	}
	return responses
}
