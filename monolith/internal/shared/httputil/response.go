package httputil

import (
	"errors"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/labstack/echo/v4"
)

type SuccessResponse struct {
	Data any `json:"data"`
}

type MessageDataResponse struct {
	Message string `json:"message"`
	Data    any    `json:"data"`
}

type IDData struct {
	ID string `json:"id"`
}

type MessageResponse struct {
	Message string `json:"message"`
}

type ListResponse struct {
	Data any            `json:"data"`
	Meta PaginationMeta `json:"meta"`
}

type PaginationMeta struct {
	Limit         int `json:"limit"`
	Offset        int `json:"offset"`
	TotalReturned int `json:"total_returned"`
}

type ErrorResponse struct {
	Error ErrorPayload `json:"error"`
}

type ErrorPayload struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details"`
}

func Success(c echo.Context, status int, data any) error {
	return c.JSON(status, SuccessResponse{Data: data})
}

func MessageData(c echo.Context, status int, message string, data any) error {
	return c.JSON(status, MessageDataResponse{Message: message, Data: data})
}

func Message(c echo.Context, status int, message string) error {
	return c.JSON(status, MessageResponse{Message: message})
}

func ID(c echo.Context, status int, message, id string) error {
	return MessageData(c, status, message, IDData{ID: id})
}

func List(c echo.Context, status int, data any, limit, offset, totalReturned int) error {
	return c.JSON(status, ListResponse{
		Data: data,
		Meta: PaginationMeta{
			Limit:         limit,
			Offset:        offset,
			TotalReturned: totalReturned,
		},
	})
}

func Error(c echo.Context, err error) error {
	appErr := toAppError(err)
	return c.JSON(appErr.Status, ErrorResponse{
		Error: ErrorPayload{
			Code:    string(appErr.Code),
			Message: appErr.Message,
			Details: appErr.Details,
		},
	})
}

func toAppError(err error) *apperror.Error {
	if appErr, ok := errors.AsType[*apperror.Error](err); ok {
		return appErr
	}
	return apperror.Internal("internal server error", err)
}
