package admission

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// ErrRejected is returned when the limiter cannot acquire a slot within the
// configured queue timeout. Callers should map this to an appropriate overload
// error (e.g. gRPC ResourceExhausted or HTTP 503).
var ErrRejected = fmt.Errorf("login admission rejected / overloaded")

// IsRejected returns true if err is or wraps ErrRejected.
func IsRejected(err error) bool {
	return errors.Is(err, ErrRejected)
}

// Config controls the admission limiter behavior.
type Config struct {
	// Enabled must be true for the limiter to enforce concurrency control.
	// When false, all operations pass through without waiting.
	Enabled bool

	// MaxConcurrency is the maximum number of concurrent operations allowed.
	// Must be > 0 when Enabled is true.
	MaxConcurrency int

	// QueueTimeout is the maximum time a caller waits for a slot before being
	// rejected. Must be > 0 when Enabled is true.
	QueueTimeout time.Duration
}

// Limiter is a bounded semaphore-based admission controller. It limits the
// number of concurrent operations and rejects callers that cannot acquire a
// slot within the configured queue timeout.
type Limiter struct {
	enabled       bool
	maxConcurrent int
	queueTimeout  time.Duration
	semaphore     chan struct{}
}

// NewLimiter creates a Limiter from the given Config. Returns an error if the
// config is invalid (enabled with non-positive concurrency or timeout).
func NewLimiter(cfg Config) (*Limiter, error) {
	if !cfg.Enabled {
		return &Limiter{enabled: false}, nil
	}
	if cfg.MaxConcurrency <= 0 {
		return nil, fmt.Errorf("admission: max_concurrency must be > 0, got %d", cfg.MaxConcurrency)
	}
	if cfg.QueueTimeout <= 0 {
		return nil, fmt.Errorf("admission: queue_timeout must be > 0, got %s", cfg.QueueTimeout)
	}
	return &Limiter{
		enabled:       true,
		maxConcurrent: cfg.MaxConcurrency,
		queueTimeout:  cfg.QueueTimeout,
		semaphore:     make(chan struct{}, cfg.MaxConcurrency),
	}, nil
}

// Do acquires a slot, executes fn, and releases the slot. When the limiter is
// disabled, fn executes directly. Returns ErrRejected if the slot cannot be
// acquired within QueueTimeout. Returns the caller's context error if the
// context ends before the slot is acquired.
func (l *Limiter) Do(ctx context.Context, fn func() error) error {
	if !l.enabled {
		return fn()
	}

	if err := l.acquire(ctx); err != nil {
		return err
	}
	defer l.release()

	return fn()
}

// DoValue is the generic version of Do for functions that return a value.
func DoValue[T any](l *Limiter, ctx context.Context, fn func() (T, error)) (T, error) {
	var zero T

	if !l.enabled {
		return fn()
	}

	if err := l.acquire(ctx); err != nil {
		return zero, err
	}
	defer l.release()

	return fn()
}

// acquire waits for a semaphore slot. It respects both the caller's context
// deadline and the configured queue timeout.
func (l *Limiter) acquire(ctx context.Context) error {
	timer := time.NewTimer(l.queueTimeout)
	defer timer.Stop()

	select {
	case l.semaphore <- struct{}{}:
		return nil
	case <-timer.C:
		return ErrRejected
	case <-ctx.Done():
		return ctx.Err()
	}
}

// release returns the semaphore slot. Must be called exactly once per acquire.
func (l *Limiter) release() {
	<-l.semaphore
}
