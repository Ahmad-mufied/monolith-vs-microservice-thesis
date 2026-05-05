package item

import "time"

type Item struct {
	ID              string
	Name            string
	AvailableAmount int
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

type Response struct {
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	AvailableAmount int       `json:"available_amount"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

func toResponse(item Item) Response {
	return Response{
		ID:              item.ID,
		Name:            item.Name,
		AvailableAmount: item.AvailableAmount,
		CreatedAt:       item.CreatedAt,
		UpdatedAt:       item.UpdatedAt,
	}
}

func toResponses(items []Item) []Response {
	responses := make([]Response, 0, len(items))
	for _, item := range items {
		responses = append(responses, toResponse(item))
	}
	return responses
}
