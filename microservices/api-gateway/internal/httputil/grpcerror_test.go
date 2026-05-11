package httputil

import (
	"net/http"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestFromGRPCError(t *testing.T) {
	tests := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{
			name:       "nil error returns nil",
			err:        nil,
			wantStatus: 0,
			wantCode:   "",
		},
		{
			name:       "InvalidArgument -> 400 BAD_REQUEST",
			err:        status.Error(codes.InvalidArgument, "bad input"),
			wantStatus: http.StatusBadRequest,
			wantCode:   "BAD_REQUEST",
		},
		{
			name:       "Unauthenticated -> 401 UNAUTHORIZED",
			err:        status.Error(codes.Unauthenticated, "no auth"),
			wantStatus: http.StatusUnauthorized,
			wantCode:   "UNAUTHORIZED",
		},
		{
			name:       "PermissionDenied -> 403 FORBIDDEN",
			err:        status.Error(codes.PermissionDenied, "forbidden"),
			wantStatus: http.StatusForbidden,
			wantCode:   "FORBIDDEN",
		},
		{
			name:       "NotFound -> 404 NOT_FOUND",
			err:        status.Error(codes.NotFound, "not found"),
			wantStatus: http.StatusNotFound,
			wantCode:   "NOT_FOUND",
		},
		{
			name:       "AlreadyExists -> 409 CONFLICT",
			err:        status.Error(codes.AlreadyExists, "conflict"),
			wantStatus: http.StatusConflict,
			wantCode:   "CONFLICT",
		},
		{
			name:       "FailedPrecondition -> 409 CONFLICT",
			err:        status.Error(codes.FailedPrecondition, "precondition"),
			wantStatus: http.StatusConflict,
			wantCode:   "CONFLICT",
		},
		{
			name:       "Aborted -> 409 CONFLICT",
			err:        status.Error(codes.Aborted, "aborted"),
			wantStatus: http.StatusConflict,
			wantCode:   "CONFLICT",
		},
		{
			name:       "Unavailable -> 503 SERVICE_UNAVAILABLE",
			err:        status.Error(codes.Unavailable, "unavailable"),
			wantStatus: http.StatusServiceUnavailable,
			wantCode:   "SERVICE_UNAVAILABLE",
		},
		{
			name:       "DeadlineExceeded -> 504 GATEWAY_TIMEOUT",
			err:        status.Error(codes.DeadlineExceeded, "timeout"),
			wantStatus: http.StatusGatewayTimeout,
			wantCode:   "GATEWAY_TIMEOUT",
		},
		{
			name:       "Internal -> 500 INTERNAL_SERVER_ERROR",
			err:        status.Error(codes.Internal, "internal"),
			wantStatus: http.StatusInternalServerError,
			wantCode:   "INTERNAL_SERVER_ERROR",
		},
		{
			name:       "unknown gRPC code -> 500 INTERNAL_SERVER_ERROR",
			err:        status.Error(codes.Unknown, "unknown"),
			wantStatus: http.StatusInternalServerError,
			wantCode:   "INTERNAL_SERVER_ERROR",
		},
		{
			name:       "non-gRPC error -> 500 INTERNAL_SERVER_ERROR",
			err:        errPlain("plain error"),
			wantStatus: http.StatusInternalServerError,
			wantCode:   "INTERNAL_SERVER_ERROR",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := FromGRPCError(tt.err)
			if tt.err == nil {
				if got != nil {
					t.Fatalf("FromGRPCError(nil) = %v, want nil", got)
				}
				return
			}
			if got == nil {
				t.Fatalf("FromGRPCError(%v) = nil, want non-nil", tt.err)
			}
			if got.Status != tt.wantStatus {
				t.Errorf("Status = %d, want %d", got.Status, tt.wantStatus)
			}
			if got.Code != tt.wantCode {
				t.Errorf("Code = %q, want %q", got.Code, tt.wantCode)
			}
			if got.Message == "" {
				t.Errorf("Message is empty")
			}
		})
	}
}

type errPlain string

func (e errPlain) Error() string { return string(e) }
