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
	Limit         int `json:"limit"`
	Offset        int `json:"offset"`
	TotalReturned int `json:"total_returned"`
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

func List(c echo.Context, httpStatus int, data any, limit, offset, totalReturned int) error {
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
			Error: errorPayload{Code: appErr.Code, Message: appErr.Message, Details: appErr.Details},
		})
	}
	return c.JSON(http.StatusInternalServerError, errorResponse{
		Error: errorPayload{Code: "INTERNAL_SERVER_ERROR", Message: "internal server error", Details: nil},
	})
}

func BindError(err error) error {
	var httpErr *echo.HTTPError
	if errors.As(err, &httpErr) && httpErr.Code == http.StatusUnsupportedMediaType {
		return &AppError{
			Status:  http.StatusUnsupportedMediaType,
			Code:    "UNSUPPORTED_MEDIA_TYPE",
			Message: httpErrorMessage(httpErr),
		}
	}
	return &AppError{
		Status:  http.StatusBadRequest,
		Code:    "BAD_REQUEST",
		Message: "invalid request payload",
	}
}

func Bind(c echo.Context, dst any) error {
	if err := c.Bind(dst); err != nil {
		return BindError(err)
	}
	return nil
}

func HTTPErrorHandler(err error, c echo.Context) {
	if c.Response().Committed {
		return
	}

	var appErr *AppError
	if errors.As(err, &appErr) {
		_ = Error(c, appErr)
		return
	}

	var httpErr *echo.HTTPError
	if !errors.As(err, &httpErr) {
		_ = Error(c, &AppError{
			Status:  http.StatusInternalServerError,
			Code:    "INTERNAL_SERVER_ERROR",
			Message: "internal server error",
		})
		return
	}

	if httpErr.Code == http.StatusNotFound {
		_ = Error(c, &AppError{
			Status:  http.StatusNotFound,
			Code:    "NOT_FOUND",
			Message: "resource not found",
		})
		return
	}

	_ = Error(c, fromHTTPStatus(httpErr.Code, httpErrorMessage(httpErr)))
}

func fromHTTPStatus(statusCode int, message string) *AppError {
	if message == "" {
		message = http.StatusText(statusCode)
	}

	switch statusCode {
	case http.StatusBadRequest:
		return &AppError{Status: statusCode, Code: "BAD_REQUEST", Message: message}
	case http.StatusUnauthorized:
		return &AppError{Status: statusCode, Code: "UNAUTHORIZED", Message: message}
	case http.StatusForbidden:
		return &AppError{Status: statusCode, Code: "FORBIDDEN", Message: message}
	case http.StatusMethodNotAllowed:
		return &AppError{Status: statusCode, Code: "METHOD_NOT_ALLOWED", Message: message}
	case http.StatusUnsupportedMediaType:
		return &AppError{Status: statusCode, Code: "UNSUPPORTED_MEDIA_TYPE", Message: message}
	case http.StatusConflict:
		return &AppError{Status: statusCode, Code: "CONFLICT", Message: message}
	default:
		if statusCode >= http.StatusBadRequest && statusCode < http.StatusInternalServerError {
			return &AppError{Status: statusCode, Code: "BAD_REQUEST", Message: message}
		}
		return &AppError{Status: http.StatusInternalServerError, Code: "INTERNAL_SERVER_ERROR", Message: "internal server error"}
	}
}

func httpErrorMessage(err *echo.HTTPError) string {
	if message, ok := err.Message.(string); ok {
		return message
	}
	return http.StatusText(err.Code)
}
