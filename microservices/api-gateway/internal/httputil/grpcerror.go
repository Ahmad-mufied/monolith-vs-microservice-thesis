package httputil

import (
	"net/http"

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const statusClientClosedRequest = 499

// AppError is an HTTP-level error returned by gRPC error mapping.
type AppError struct {
	Status  int
	Code    string
	Message string
	Details any
}

func (e *AppError) Error() string { return e.Message }

// FromGRPCError maps a gRPC status error to an AppError.
// Returns nil if err is nil.
func FromGRPCError(err error) *AppError {
	if err == nil {
		return nil
	}

	if st, ok := status.FromError(err); ok {
		msg := st.Message()
		switch st.Code() {
		case codes.InvalidArgument:
			return &AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: msg, Details: grpcBadRequestDetails(st)}
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
		case codes.Canceled:
			return &AppError{Status: statusClientClosedRequest, Code: "CLIENT_CANCELED", Message: msg}
		}
	}

	return &AppError{Status: http.StatusInternalServerError, Code: "INTERNAL_SERVER_ERROR", Message: "internal server error"}
}

// grpcBadRequestDetails extracts field-level validation details from a gRPC BadRequest payload.
func grpcBadRequestDetails(st *status.Status) map[string]string {
	details := make(map[string]string)
	for _, detail := range st.Details() {
		badRequest, ok := detail.(*errdetails.BadRequest)
		if !ok {
			continue
		}
		for _, violation := range badRequest.GetFieldViolations() {
			if violation.GetField() == "" {
				continue
			}
			details[violation.GetField()] = violation.GetDescription()
		}
	}
	if len(details) == 0 {
		return nil
	}
	return details
}
