package apperror

import (
	"context"
	"errors"
	"fmt"
	"net/http"
)

type Code string

const (
	CodeBadRequest           Code = "BAD_REQUEST"
	CodeUnauthorized         Code = "UNAUTHORIZED"
	CodeForbidden            Code = "FORBIDDEN"
	CodeNotFound             Code = "NOT_FOUND"
	CodeMethodNotAllowed     Code = "METHOD_NOT_ALLOWED"
	CodeUnsupportedMediaType Code = "UNSUPPORTED_MEDIA_TYPE"
	CodeConflict             Code = "CONFLICT"
	CodeGatewayTimeout       Code = "GATEWAY_TIMEOUT"
	CodeClientCanceled       Code = "CLIENT_CANCELED"
	CodeInternal             Code = "INTERNAL_SERVER_ERROR"
)

type Error struct {
	Code    Code
	Message string
	Details map[string]any
	Status  int
	Err     error
}

func (e *Error) Error() string {
	if e.Message != "" {
		return e.Message
	}
	if e.Err != nil {
		return e.Err.Error()
	}
	return string(e.Code)
}

func (e *Error) Unwrap() error {
	return e.Err
}

func BadRequest(message string, details map[string]any) *Error {
	return &Error{Code: CodeBadRequest, Message: message, Details: details, Status: http.StatusBadRequest}
}

func Unauthorized(message string) *Error {
	return &Error{Code: CodeUnauthorized, Message: message, Status: http.StatusUnauthorized}
}

func Forbidden(message string) *Error {
	return &Error{Code: CodeForbidden, Message: message, Status: http.StatusForbidden}
}

func NotFound(message string) *Error {
	return &Error{Code: CodeNotFound, Message: message, Status: http.StatusNotFound}
}

func Conflict(message string) *Error {
	return &Error{Code: CodeConflict, Message: message, Status: http.StatusConflict}
}

func DeadlineExceeded(message string, err error) *Error {
	return &Error{Code: CodeGatewayTimeout, Message: message, Status: http.StatusGatewayTimeout, Err: err}
}

func Canceled(message string, err error) *Error {
	return &Error{Code: CodeClientCanceled, Message: message, Status: 499, Err: err}
}

func Internal(message string, err error) *Error {
	return &Error{Code: CodeInternal, Message: message, Status: http.StatusInternalServerError, Err: err}
}

func InternalFromContext(action string, err error) *Error {
	if ctxErr := FromContext(err, "request timeout", "request canceled"); ctxErr != nil {
		return ctxErr
	}
	return Internal("internal server error", fmt.Errorf("%s: %w", action, err))
}

func FromContext(err error, deadlineMessage, canceledMessage string) *Error {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return DeadlineExceeded(deadlineMessage, err)
	case errors.Is(err, context.Canceled):
		return Canceled(canceledMessage, err)
	default:
		return nil
	}
}

func FromHTTPStatus(status int, message string) *Error {
	if message == "" {
		message = http.StatusText(status)
	}
	switch status {
	case http.StatusBadRequest:
		return BadRequest(message, nil)
	case http.StatusUnauthorized:
		return Unauthorized(message)
	case http.StatusForbidden:
		return Forbidden(message)
	case http.StatusNotFound:
		return NotFound(message)
	case http.StatusMethodNotAllowed:
		return &Error{Code: CodeMethodNotAllowed, Message: message, Status: status}
	case http.StatusUnsupportedMediaType:
		return &Error{Code: CodeUnsupportedMediaType, Message: message, Status: status}
	case http.StatusConflict:
		return Conflict(message)
	default:
		if status >= http.StatusBadRequest && status < http.StatusInternalServerError {
			return &Error{Code: CodeBadRequest, Message: message, Status: status}
		}
		return Internal(message, nil)
	}
}
