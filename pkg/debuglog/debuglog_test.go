package debuglog

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type capturedRecord struct {
	level slog.Level
	msg   string
	attrs map[string]any
}

type captureHandler struct {
	mu      sync.Mutex
	records []capturedRecord
}

func (h *captureHandler) Enabled(context.Context, slog.Level) bool { return true }

func (h *captureHandler) Handle(_ context.Context, record slog.Record) error {
	attrs := map[string]any{}
	record.Attrs(func(attr slog.Attr) bool {
		attrs[attr.Key] = attr.Value.Any()
		return true
	})

	h.mu.Lock()
	defer h.mu.Unlock()
	h.records = append(h.records, capturedRecord{
		level: record.Level,
		msg:   record.Message,
		attrs: attrs,
	})
	return nil
}

func (h *captureHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *captureHandler) WithGroup(string) slog.Handler      { return h }

func resetEnabledCache() {
	ResetForTesting()
}

func withCapturedLogger(t *testing.T) *captureHandler {
	t.Helper()

	handler := &captureHandler{}
	previous := slog.Default()
	slog.SetDefault(slog.New(handler))
	t.Cleanup(func() {
		slog.SetDefault(previous)
	})
	return handler
}

func TestEnabledDefaultsFalse(t *testing.T) {
	tests := []struct {
		name     string
		envValue string
		want     bool
	}{
		{name: "unset defaults false", envValue: "", want: false},
		{name: "truthy env enables", envValue: "true", want: true},
		{name: "invalid env stays false", envValue: "definitely-not-bool", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv(envEnabled, tt.envValue)
			resetEnabledCache()

			if got := Enabled(); got != tt.want {
				t.Fatalf("Enabled() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestDiagnosticLoggingHelpers(t *testing.T) {
	cause := io.EOF
	baseErr := errors.New("top level: " + cause.Error())

	tests := []struct {
		name      string
		invoke    func()
		wantLevel slog.Level
		wantAttrs map[string]any
	}{
		{
			name: "ErrorWithDuration includes duration and error metadata",
			invoke: func() {
				ErrorWithDuration(
					context.Background(),
					slog.LevelWarn,
					"login failed",
					"auth_login_usecase_failure",
					time.Now().Add(-25*time.Millisecond),
					baseErr,
					"category", "context",
				)
			},
			wantLevel: slog.LevelWarn,
			wantAttrs: map[string]any{
				"event":    "auth_login_usecase_failure",
				"category": "context",
			},
		},
		{
			name: "GRPC internal maps to error level and status fields",
			invoke: func() {
				GRPC(
					context.Background(),
					"rpc failed",
					"gateway_auth_login_rpc_failure",
					"/auth.v1.AuthService/Login",
					time.Now().Add(-10*time.Millisecond),
					status.Error(codes.Internal, "boom"),
					"http_status", 500,
				)
			},
			wantLevel: slog.LevelError,
			wantAttrs: map[string]any{
				"event":            "gateway_auth_login_rpc_failure",
				"grpc_status_code": "Internal",
				"http_status":      500,
			},
		},
		{
			name: "HTTP 503 stays warn",
			invoke: func() {
				HTTP(
					context.Background(),
					"http failed",
					"gateway_auth_login_http_failure",
					503,
					"SERVICE_UNAVAILABLE",
					"request timeout",
				)
			},
			wantLevel: slog.LevelWarn,
			wantAttrs: map[string]any{
				"event":       "gateway_auth_login_http_failure",
				"http_status": 503,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv(envEnabled, "true")
			resetEnabledCache()
			handler := withCapturedLogger(t)

			tt.invoke()

			if len(handler.records) != 1 {
				t.Fatalf("record count = %d, want 1", len(handler.records))
			}

			record := handler.records[0]
			if record.level != tt.wantLevel {
				t.Fatalf("level = %v, want %v", record.level, tt.wantLevel)
			}

			for key, want := range tt.wantAttrs {
				got := record.attrs[key]
				if key == "http_status" {
					switch value := got.(type) {
					case int:
						if value != want {
							t.Fatalf("%s = %v, want %v", key, got, want)
						}
					case int64:
						if int(value) != want {
							t.Fatalf("%s = %v, want %v", key, got, want)
						}
					default:
						t.Fatalf("%s = %v, want %v", key, got, want)
					}
					continue
				}

				if got != want {
					t.Fatalf("%s = %v, want %v", key, got, want)
				}
			}

			if tt.wantAttrs["category"] != nil {
				if _, ok := record.attrs["duration_ms"]; !ok {
					t.Fatal("duration_ms is missing")
				}
				if record.attrs["error"] == nil {
					t.Fatal("error is missing")
				}
			}
		})
	}
}
