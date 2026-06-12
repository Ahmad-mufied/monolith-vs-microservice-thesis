package admission

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestLimiter_Disabled(t *testing.T) {
	limiter, err := NewLimiter(Config{Enabled: false})
	if err != nil {
		t.Fatalf("NewLimiter() error: %v", err)
	}

	called := false
	err = limiter.Do(context.Background(), func() error {
		called = true
		return nil
	})
	if err != nil {
		t.Fatalf("Do() error: %v", err)
	}
	if !called {
		t.Fatal("Do() did not execute fn")
	}
}

func TestLimiter_DisabledDoValue(t *testing.T) {
	limiter, err := NewLimiter(Config{Enabled: false})
	if err != nil {
		t.Fatalf("NewLimiter() error: %v", err)
	}

	val, err := DoValue(limiter, context.Background(), func() (string, error) {
		return "hello", nil
	})
	if err != nil {
		t.Fatalf("DoValue() error: %v", err)
	}
	if val != "hello" {
		t.Fatalf("DoValue() = %q, want hello", val)
	}
}

func TestLimiter_InvalidConfig(t *testing.T) {
	tests := []struct {
		name string
		cfg  Config
	}{
		{
			name: "zero max concurrency",
			cfg:  Config{Enabled: true, MaxConcurrency: 0, QueueTimeout: time.Second},
		},
		{
			name: "negative max concurrency",
			cfg:  Config{Enabled: true, MaxConcurrency: -1, QueueTimeout: time.Second},
		},
		{
			name: "zero queue timeout",
			cfg:  Config{Enabled: true, MaxConcurrency: 1, QueueTimeout: 0},
		},
		{
			name: "negative queue timeout",
			cfg:  Config{Enabled: true, MaxConcurrency: 1, QueueTimeout: -time.Second},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := NewLimiter(tt.cfg)
			if err == nil {
				t.Fatal("NewLimiter() expected error, got nil")
			}
		})
	}
}

func TestLimiter_ConcurrencyLimit(t *testing.T) {
	limiter, err := NewLimiter(Config{
		Enabled:        true,
		MaxConcurrency: 2,
		QueueTimeout:   5 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewLimiter() error: %v", err)
	}

	var inFlight atomic.Int32
	var maxInFlight atomic.Int32

	worker := func() error {
		current := inFlight.Add(1)
		for {
			old := maxInFlight.Load()
			if current <= old || maxInFlight.CompareAndSwap(old, current) {
				break
			}
		}
		time.Sleep(50 * time.Millisecond)
		inFlight.Add(-1)
		return nil
	}

	done := make(chan error, 4)
	for i := 0; i < 4; i++ {
		go func() {
			done <- limiter.Do(context.Background(), worker)
		}()
	}

	for i := 0; i < 4; i++ {
		if err := <-done; err != nil {
			t.Fatalf("Do() error: %v", err)
		}
	}

	if got := maxInFlight.Load(); got > 2 {
		t.Fatalf("maxInFlight = %d, want <= 2", got)
	}
}

func TestLimiter_QueueTimeoutRejects(t *testing.T) {
	limiter, err := NewLimiter(Config{
		Enabled:        true,
		MaxConcurrency: 1,
		QueueTimeout:   50 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("NewLimiter() error: %v", err)
	}

	blocker := make(chan struct{})
	go func() {
		_ = limiter.Do(context.Background(), func() error {
			<-blocker
			return nil
		})
	}()

	time.Sleep(10 * time.Millisecond)

	err = limiter.Do(context.Background(), func() error {
		return nil
	})
	if !errors.Is(err, ErrRejected) {
		t.Fatalf("Do() error = %v, want ErrRejected", err)
	}

	close(blocker)
}

func TestLimiter_ContextCancellation(t *testing.T) {
	limiter, err := NewLimiter(Config{
		Enabled:        true,
		MaxConcurrency: 1,
		QueueTimeout:   10 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewLimiter() error: %v", err)
	}

	blocker := make(chan struct{})
	go func() {
		_ = limiter.Do(context.Background(), func() error {
			<-blocker
			return nil
		})
	}()

	time.Sleep(10 * time.Millisecond)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err = limiter.Do(ctx, func() error {
		return nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Do() error = %v, want context.Canceled", err)
	}

	close(blocker)
}

func TestLimiter_ReleaseAfterError(t *testing.T) {
	limiter, err := NewLimiter(Config{
		Enabled:        true,
		MaxConcurrency: 1,
		QueueTimeout:   5 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewLimiter() error: %v", err)
	}

	testErr := errors.New("test error")
	err = limiter.Do(context.Background(), func() error {
		return testErr
	})
	if !errors.Is(err, testErr) {
		t.Fatalf("Do() error = %v, want %v", err, testErr)
	}

	err = limiter.Do(context.Background(), func() error {
		return nil
	})
	if err != nil {
		t.Fatalf("Do() after error release: %v", err)
	}
}

func TestLimiter_DoValue_WithConcurrency(t *testing.T) {
	limiter, err := NewLimiter(Config{
		Enabled:        true,
		MaxConcurrency: 2,
		QueueTimeout:   5 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewLimiter() error: %v", err)
	}

	val, err := DoValue(limiter, context.Background(), func() (int, error) {
		return 42, nil
	})
	if err != nil {
		t.Fatalf("DoValue() error: %v", err)
	}
	if val != 42 {
		t.Fatalf("DoValue() = %d, want 42", val)
	}
}
