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
// Returns nil if err is nil.
func FromGRPCError(err error) *AppError {
	if err == nil {
		return nil
	}

	msg := err.Error()
	if st, ok := status.FromError(err); ok {
		msg = st.Message()
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
