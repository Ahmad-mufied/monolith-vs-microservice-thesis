package transaction

type CreateRequest struct {
	Items []CreateItemRequest `json:"items"`
}

type CreateItemRequest struct {
	ItemID string `json:"item_id"`
	Amount int    `json:"amount"`
}
