package item

type BulkSaveRequest struct {
	Items []BulkSaveItemRequest `json:"items" validate:"required,min=1,max=100,dive"`
}

type BulkSaveItemRequest struct {
	ID              *string `json:"id" validate:"omitempty,uuid"`
	Name            string  `json:"name" validate:"required,max=160"`
	AvailableAmount *int    `json:"available_amount" validate:"required,gte=0"`
}
