package item

type SyncItemsRequest struct {
	Items []SyncItemRequest `json:"items" validate:"max=100,dive"`
}

type SyncItemRequest struct {
	ID              *string `json:"id"               validate:"omitempty,uuid"`
	Name            string  `json:"name"             validate:"max=160"`
	AvailableAmount *int    `json:"available_amount" validate:"required,gte=0"`
}
