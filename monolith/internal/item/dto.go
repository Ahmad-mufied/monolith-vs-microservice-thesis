package item

type CreateRequest struct {
	Name            string `json:"name"`
	AvailableAmount *int   `json:"available_amount"`
}

type UpdateRequest struct {
	Name            *string `json:"name"`
	AvailableAmount *int    `json:"available_amount"`
}
