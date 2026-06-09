package grpcutil

import (
	"context"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// UnaryServerTimeout applies a deadline to every unary gRPC request handled by
// a server. If the parent context already has an earlier deadline, that earlier
// deadline still wins through normal context propagation.
func UnaryServerTimeout(timeout time.Duration) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		timedCtx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()

		resp, err := handler(timedCtx, req)
		if ctxErr := timedCtx.Err(); ctxErr != nil {
			return nil, grpcContextError(ctxErr)
		}
		return resp, err
	}
}

func grpcContextError(err error) error {
	switch err {
	case context.DeadlineExceeded:
		return status.Error(codes.DeadlineExceeded, "request timed out")
	case context.Canceled:
		return status.Error(codes.Canceled, "request canceled")
	default:
		return err
	}
}
