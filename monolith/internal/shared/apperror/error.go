package apperror

import "net/http"

type Code string

const (
	CodeBadRequest   Code = "BAD_REQUEST"
	CodeUnauthorized Code = "UNAUTHORIZED"
	CodeNotFound     Code = "NOT_FOUND"
	CodeConflict     Code = "CONFLICT"
	CodeInternal     Code = "INTERNAL_SERVER_ERROR"
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

func NotFound(message string) *Error {
	return &Error{Code: CodeNotFound, Message: message, Status: http.StatusNotFound}
}

func Conflict(message string) *Error {
	return &Error{Code: CodeConflict, Message: message, Status: http.StatusConflict}
}

func Internal(message string, err error) *Error {
	return &Error{Code: CodeInternal, Message: message, Status: http.StatusInternalServerError, Err: err}
}
