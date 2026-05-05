package httputil

import (
	"errors"
	"net/http"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/labstack/echo/v4"
)

type SuccessResponse struct {
	Status string `json:"status"`
	Data   any    `json:"data"`
}

type MessageResponse struct {
	Status  string `json:"status"`
	Message string `json:"message"`
}

type ListResponse struct {
	Status string         `json:"status"`
	Data   any            `json:"data"`
	Meta   PaginationMeta `json:"meta"`
}

type PaginationMeta struct {
	Limit         int `json:"limit"`
	Offset        int `json:"offset"`
	TotalReturned int `json:"total_returned"`
}

type ErrorResponse struct {
	Status string       `json:"status"`
	Error  ErrorPayload `json:"error"`
}

type ErrorPayload struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

func Success(c echo.Context, status int, data any) error {
	return c.JSON(status, SuccessResponse{Status: "success", Data: data})
}

func Message(c echo.Context, message string) error {
	return c.JSON(http.StatusOK, MessageResponse{Status: "success", Message: message})
}

func List(c echo.Context, status int, data any, limit, offset, totalReturned int) error {
	return c.JSON(status, ListResponse{
		Status: "success",
		Data:   data,
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
		Status: "error",
		Error: ErrorPayload{
			Code:    string(appErr.Code),
			Message: appErr.Message,
			Details: appErr.Details,
		},
	})
}

func toAppError(err error) *apperror.Error {
	var appErr *apperror.Error
	if errors.As(err, &appErr) {
		return appErr
	}
	return apperror.Internal("internal server error", err)
}
