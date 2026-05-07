package item

import "time"

type Item struct {
	ID              string
	Name            string
	AvailableAmount int
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

type BulkSaveItem struct {
	ID              *string
	Name            string
	AvailableAmount int
}

type Response struct {
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	AvailableAmount int       `json:"available_amount"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

func toResponse(item Item) Response {
	return Response(item)
}

func toResponses(items []Item) []Response {
	responses := make([]Response, 0, len(items))
	for _, item := range items {
		responses = append(responses, toResponse(item))
	}
	return responses
}
