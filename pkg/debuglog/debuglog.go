package debuglog

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"sync"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const envEnabled = "DIAGNOSTIC_LOGGING_ENABLED"

var (
	enabledOnce sync.Once
	enabled     bool
)

// ResetForTesting clears the cached env lookup so tests in other packages can
// safely toggle DIAGNOSTIC_LOGGING_ENABLED in the same process.
func ResetForTesting() {
	enabledOnce = sync.Once{}
	enabled = false
}

// Enabled caches the env flag once because this helper is hit from hot failure
// paths and should stay effectively free when debugging is disabled.
func Enabled() bool {
	enabledOnce.Do(func() {
		value, err := strconv.ParseBool(os.Getenv(envEnabled))
		enabled = err == nil && value
	})
	return enabled
}

// Log is a no-op unless diagnostic logging is explicitly enabled.
func Log(ctx context.Context, level slog.Level, msg string, attrs ...any) {
	if !Enabled() {
		return
	}
	slog.Default().Log(ctx, level, msg, attrs...)
}

// Error emits the shared structured error shape used by the debug-only hooks.
// Callers can add domain-specific attributes while keeping error metadata
// consistent across monolith and microservices.
func Error(ctx context.Context, level slog.Level, msg, event string, err error, attrs ...any) {
	if err == nil {
		Log(ctx, level, msg, append([]any{"event", event}, attrs...)...)
		return
	}

	fields := []any{
		"event", event,
		"error_type", fmt.Sprintf("%T", err),
		"error", err.Error(),
	}
	if cause := errors.Unwrap(err); cause != nil {
		fields = append(fields,
			"cause_type", fmt.Sprintf("%T", cause),
			"cause", cause.Error(),
		)
	}
	fields = append(fields, attrs...)
	Log(ctx, level, msg, fields...)
}

// ErrorWithDuration is for failure paths that also need latency context.
func ErrorWithDuration(ctx context.Context, level slog.Level, msg, event string, startedAt time.Time, err error, attrs ...any) {
	fields := append([]any{
		"duration_ms", time.Since(startedAt).Milliseconds(),
	}, attrs...)
	Error(ctx, level, msg, event, err, fields...)
}

// GRPC standardizes diagnostic logs for RPC boundaries. It extracts the gRPC
// status when available and falls back to the generic timed error shape when
// the transport returned a non-status error.
func GRPC(ctx context.Context, msg, event, method string, startedAt time.Time, err error, attrs ...any) {
	st, ok := status.FromError(err)
	if !ok {
		ErrorWithDuration(ctx, slog.LevelError, msg, event, startedAt, err, attrs...)
		return
	}

	level := slog.LevelWarn
	if st.Code() == codes.Internal {
		level = slog.LevelError
	}

	fields := []any{
		"event", event,
		"grpc_method", method,
		"grpc_status_code", st.Code().String(),
		"grpc_status_message", st.Message(),
		"duration_ms", time.Since(startedAt).Milliseconds(),
	}
	fields = append(fields, attrs...)
	Log(ctx, level, msg, fields...)
}

// HTTP standardizes final public-response failure logs after a service has
// already mapped the internal failure into an HTTP-facing error contract.
func HTTP(ctx context.Context, msg, event string, statusCode int, code, message any, attrs ...any) {
	level := slog.LevelWarn
	if statusCode >= 500 && statusCode != 503 {
		level = slog.LevelError
	}

	fields := []any{
		"event", event,
		"http_status", statusCode,
		"http_error_code", code,
		"http_error_message", message,
	}
	fields = append(fields, attrs...)
	Log(ctx, level, msg, fields...)
}
