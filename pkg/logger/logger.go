package logger

import (
	"context"
	"log/slog"
	"os"
	"strings"

	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"
)

// ddHandler wraps an existing slog.Handler to inject Datadog trace context.
type ddHandler struct {
	slog.Handler
}

// Handle extracts tracing IDs from the context and adds them to the log record.
func (h *ddHandler) Handle(ctx context.Context, r slog.Record) error {
	if ctx != nil {
		if span, ok := tracer.SpanFromContext(ctx); ok {
			r.Add(
				slog.String("dd.trace_id", span.Context().TraceID()),
				slog.Uint64("dd.span_id", span.Context().SpanID()),
			)
		}
	}
	return h.Handler.Handle(ctx, r)
}

func New(level string) *slog.Logger {
	var lv slog.Level
	switch strings.ToLower(level) {
	case "debug":
		lv = slog.LevelDebug
	case "warn", "warning":
		lv = slog.LevelWarn
	case "error":
		lv = slog.LevelError
	default:
		lv = slog.LevelInfo
	}

	jsonHandler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lv})
	return slog.New(&ddHandler{Handler: jsonHandler})
}
