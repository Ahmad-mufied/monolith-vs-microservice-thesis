package transaction

type CreateRequest struct {
	Items []CreateItemRequest `json:"items" validate:"required,min=1,max=20,dive"`
}

type CreateItemRequest struct {
	ItemID string `json:"item_id" validate:"required,uuid"`
	Amount int    `json:"amount" validate:"gt=0"`
}
