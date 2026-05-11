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

func Success(c echo.Context, httpStatus int, data any) error {
	return c.JSON(httpStatus, dataResponse{Data: data})
}

func MessageData(c echo.Context, httpStatus int, message string, data any) error {
	return c.JSON(httpStatus, messageDataResponse{Message: message, Data: data})
}

func Message(c echo.Context, httpStatus int, message string) error {
	return c.JSON(httpStatus, messageResponse{Message: message})
}

func ID(c echo.Context, httpStatus int, message, id string) error {
	return MessageData(c, httpStatus, message, struct {
		ID string `json:"id"`
	}{ID: id})
}

func List(c echo.Context, httpStatus int, data any, limit, offset int32, totalReturned int) error {
	return c.JSON(httpStatus, listResponse{
		Data: data,
		Meta: paginationMeta{Limit: limit, Offset: offset, TotalReturned: totalReturned},
	})
}

// Error writes an error response. Accepts *AppError or any error.
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
