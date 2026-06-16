package postgres

import (
	"context"
	"errors"
	"testing"
	"time"

	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
)

func TestRepositoryContextClassification(t *testing.T) {
	tests := []struct {
		name      string
		ctxSetup  func() (context.Context, context.CancelFunc)
		err       error
		action    string
		wantError error
	}{
		{
			name: "active context and non-context driver error",
			ctxSetup: func() (context.Context, context.CancelFunc) {
				return context.Background(), func() {}
			},
			err:       errors.New("connection reset by peer"),
			action:    "find user by email",
			wantError: pkgerrors.ErrInternal,
		},
		{
			name: "canceled context",
			ctxSetup: func() (context.Context, context.CancelFunc) {
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				return ctx, func() {}
			},
			err:       errors.New("driver canceled"),
			action:    "find user by email",
			wantError: pkgerrors.ErrCanceled,
		},
		{
			name: "deadline exceeded context",
			ctxSetup: func() (context.Context, context.CancelFunc) {
				ctx, cancel := context.WithTimeout(context.Background(), 1*time.Millisecond)
				time.Sleep(2 * time.Millisecond)
				return ctx, cancel
			},
			err:       errors.New("driver timeout"),
			action:    "find user by email",
			wantError: pkgerrors.ErrDeadlineExceeded,
		},
		{
			name: "active context but error wraps context.DeadlineExceeded",
			ctxSetup: func() (context.Context, context.CancelFunc) {
				return context.Background(), func() {}
			},
			err:       context.DeadlineExceeded,
			action:    "find user by email",
			wantError: pkgerrors.ErrDeadlineExceeded,
		},
		{
			name: "active context but error wraps context.Canceled",
			ctxSetup: func() (context.Context, context.CancelFunc) {
				return context.Background(), func() {}
			},
			err:       context.Canceled,
			action:    "find user by email",
			wantError: pkgerrors.ErrCanceled,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := tt.ctxSetup()
			defer cancel()

			got := pkgerrors.InternalFromContext(ctx, tt.action, tt.err)
			if !errors.Is(got, tt.wantError) {
				t.Fatalf("expected error kind %v, got %v", tt.wantError, got)
			}
		})
	}
}
