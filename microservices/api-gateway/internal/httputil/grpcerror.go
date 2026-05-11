package httputil

import (
	"net/http"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// AppError is an HTTP-level error returned by gRPC error mapping.
type AppError struct {
	Status  int
	Code    string
	Message string
}

func (e *AppError) Error() string { return e.Message }

// FromGRPCError maps a gRPC status error to an AppError.
// FromGRPCError converts a gRPC error into an AppError suitable for HTTP responses.
// If err is nil, it returns nil. For recognized gRPC status codes it maps them to
// corresponding HTTP status codes and application-level error codes (for example,
// InvalidArgument -> 400 BAD_REQUEST, Unauthenticated -> 401 UNAUTHORIZED, NotFound -> 404 NOT_FOUND).
// If the error is not a gRPC status error or the status code is not handled, it
// returns an AppError representing an internal server error (500, "INTERNAL_SERVER_ERROR").
func FromGRPCError(err error) *AppError {
	if err == nil {
		return nil
	}

	if st, ok := status.FromError(err); ok {
		msg := st.Message()
		switch st.Code() {
		case codes.InvalidArgument:
			return &AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: msg}
		case codes.Unauthenticated:
			return &AppError{Status: http.StatusUnauthorized, Code: "UNAUTHORIZED", Message: msg}
		case codes.PermissionDenied:
			return &AppError{Status: http.StatusForbidden, Code: "FORBIDDEN", Message: msg}
		case codes.NotFound:
			return &AppError{Status: http.StatusNotFound, Code: "NOT_FOUND", Message: msg}
		case codes.AlreadyExists, codes.FailedPrecondition, codes.Aborted:
			return &AppError{Status: http.StatusConflict, Code: "CONFLICT", Message: msg}
		case codes.Unavailable:
			return &AppError{Status: http.StatusServiceUnavailable, Code: "SERVICE_UNAVAILABLE", Message: msg}
		case codes.DeadlineExceeded:
			return &AppError{Status: http.StatusGatewayTimeout, Code: "GATEWAY_TIMEOUT", Message: msg}
		}
	}

	return &AppError{Status: http.StatusInternalServerError, Code: "INTERNAL_SERVER_ERROR", Message: "internal server error"}
}
