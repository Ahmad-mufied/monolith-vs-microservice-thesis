package httputil

import (
	"errors"
	"net/http"

	"github.com/labstack/echo/v4"
)

type dataResponse struct {
	Data any `json:"data"`
}

type messageDataResponse struct {
	Message string `json:"message"`
	Data    any    `json:"data"`
}

type messageResponse struct {
	Message string `json:"message"`
}

type listResponse struct {
	Data any            `json:"data"`
	Meta paginationMeta `json:"meta"`
}

type paginationMeta struct {
	Limit         int32 `json:"limit"`
	Offset        int32 `json:"offset"`
	TotalReturned int   `json:"total_returned"`
}

type errorResponse struct {
	Error errorPayload `json:"error"`
}

type errorPayload struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Details any    `json:"details"`
}

// Success sends a JSON response using the provided HTTP status and a body with the given value wrapped under the "data" key.
// The response body has the shape: {"data": <value>}.
func Success(c echo.Context, httpStatus int, data any) error {
	return c.JSON(httpStatus, dataResponse{Data: data})
}

// MessageData sends a JSON response with a message and arbitrary data using the provided HTTP status.
// The response body is an object with "message" (string) and "data" (any) fields.
func MessageData(c echo.Context, httpStatus int, message string, data any) error {
	return c.JSON(httpStatus, messageDataResponse{Message: message, Data: data})
}

// Message sends a JSON response with a single "message" field using the provided HTTP status.
// It returns any error encountered while writing the response.
func Message(c echo.Context, httpStatus int, message string) error {
	return c.JSON(httpStatus, messageResponse{Message: message})
}

// ID sends a JSON response containing the provided message and a `data` object with an `id` field,
// using the given HTTP status. It returns any error encountered while writing the response.
func ID(c echo.Context, httpStatus int, message, id string) error {
	return MessageData(c, httpStatus, message, struct {
		ID string `json:"id"`
	}{ID: id})
}

// List writes a paginated JSON response containing the provided data and pagination metadata (limit, offset, total returned).
// It returns any error encountered while writing the JSON response.
func List(c echo.Context, httpStatus int, data any, limit, offset int32, totalReturned int) error {
	return c.JSON(httpStatus, listResponse{
		Data: data,
		Meta: paginationMeta{Limit: limit, Offset: offset, TotalReturned: totalReturned},
	})
}

// Error writes a standardized JSON error response to the provided Echo context.
// If err is an *AppError the response uses its Status, Code, and Message; otherwise it responds with HTTP 500 and an `INTERNAL_SERVER_ERROR` payload.
func Error(c echo.Context, err error) error {
	var appErr *AppError
	if errors.As(err, &appErr) {
		return c.JSON(appErr.Status, errorResponse{
			Error: errorPayload{Code: appErr.Code, Message: appErr.Message, Details: nil},
		})
	}
	return c.JSON(http.StatusInternalServerError, errorResponse{
		Error: errorPayload{Code: "INTERNAL_SERVER_ERROR", Message: "internal server error", Details: nil},
	})
}
