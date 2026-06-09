package grpcutil

import (
	"context"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestUnaryServerTimeoutDeadlineExceeded(t *testing.T) {
	interceptor := UnaryServerTimeout(1 * time.Millisecond)

	_, err := interceptor(context.Background(), "req", nil, func(ctx context.Context, req any) (any, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	})
	if status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("code = %s, want %s", status.Code(err), codes.DeadlineExceeded)
	}
}

func TestUnaryServerTimeoutCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	interceptor := UnaryServerTimeout(5 * time.Second)
	_, err := interceptor(ctx, "req", nil, func(ctx context.Context, req any) (any, error) {
		return nil, ctx.Err()
	})
	if status.Code(err) != codes.Canceled {
		t.Fatalf("code = %s, want %s", status.Code(err), codes.Canceled)
	}
}

func TestUnaryServerTimeoutPassThrough(t *testing.T) {
	interceptor := UnaryServerTimeout(5 * time.Second)

	resp, err := interceptor(context.Background(), "req", nil, func(ctx context.Context, req any) (any, error) {
		if _, ok := ctx.Deadline(); !ok {
			t.Fatal("expected deadline on context")
		}
		return "ok", nil
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp != "ok" {
		t.Fatalf("resp = %v, want ok", resp)
	}
}
