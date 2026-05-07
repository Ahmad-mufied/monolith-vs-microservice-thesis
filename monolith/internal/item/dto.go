package item

type CreateRequest struct {
	Name            string `json:"name" validate:"required,max=160"`
	AvailableAmount *int   `json:"available_amount" validate:"required,gte=0"`
}

type UpdateRequest struct {
	Name            *string `json:"name" validate:"omitempty,max=160"`
	AvailableAmount *int    `json:"available_amount" validate:"omitempty,gte=0"`
}
