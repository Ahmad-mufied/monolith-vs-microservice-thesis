package config

import (
	"testing"
	"time"
)

func TestLoad(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		wantErr bool
		check   func(t *testing.T, cfg *Config)
	}{
		{
			name: "all required env vars set",
			env: map[string]string{
				"JWT_SECRET":               "secret",
				"AUTH_SERVICE_ADDR":        "auth:50051",
				"ITEM_SERVICE_ADDR":        "item:50052",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
			},
			wantErr: false,
			check: func(t *testing.T, cfg *Config) {
				if cfg.HTTPPort != "8080" {
					t.Errorf("HTTPPort = %q, want default 8080", cfg.HTTPPort)
				}
				if cfg.JWTSecret != "secret" {
					t.Errorf("JWTSecret = %q, want secret", cfg.JWTSecret)
				}
				if cfg.GRPCCallTimeout != 10*time.Second {
					t.Errorf("GRPCCallTimeout = %s, want 10s", cfg.GRPCCallTimeout)
				}
				if cfg.RequestTimeout != 12*time.Second {
					t.Errorf("RequestTimeout = %s, want 12s", cfg.RequestTimeout)
				}
				if cfg.HTTPServer.ReadHeaderTimeout != 5*time.Second ||
					cfg.HTTPServer.ReadTimeout != 15*time.Second ||
					cfg.HTTPServer.WriteTimeout != 15*time.Second ||
					cfg.HTTPServer.IdleTimeout != time.Minute ||
					cfg.HTTPServer.ShutdownTimeout != 10*time.Second {
					t.Errorf("HTTPServer defaults = %+v", cfg.HTTPServer)
				}
			},
		},
		{
			name: "custom HTTP port",
			env: map[string]string{
				"HTTP_PORT":                "9090",
				"JWT_SECRET":               "secret",
				"AUTH_SERVICE_ADDR":        "auth:50051",
				"ITEM_SERVICE_ADDR":        "item:50052",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.HTTPPort != "9090" {
					t.Errorf("HTTPPort = %q, want 9090", cfg.HTTPPort)
				}
			},
		},
		{
			name: "loads timeout overrides",
			env: map[string]string{
				"JWT_SECRET":               "secret",
				"AUTH_SERVICE_ADDR":        "auth:50051",
				"ITEM_SERVICE_ADDR":        "item:50052",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
				"GRPC_CALL_TIMEOUT":        "9s",
				"REQUEST_TIMEOUT":          "13s",
				"HTTP_READ_HEADER_TIMEOUT": "6s",
				"HTTP_READ_TIMEOUT":        "12s",
				"HTTP_WRITE_TIMEOUT":       "14s",
				"HTTP_IDLE_TIMEOUT":        "45s",
				"HTTP_SHUTDOWN_TIMEOUT":    "9s",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.GRPCCallTimeout != 9*time.Second {
					t.Errorf("GRPCCallTimeout = %s, want 9s", cfg.GRPCCallTimeout)
				}
				if cfg.RequestTimeout != 13*time.Second {
					t.Errorf("RequestTimeout = %s, want 13s", cfg.RequestTimeout)
				}
				if cfg.HTTPServer.ReadHeaderTimeout != 6*time.Second ||
					cfg.HTTPServer.ReadTimeout != 12*time.Second ||
					cfg.HTTPServer.WriteTimeout != 14*time.Second ||
					cfg.HTTPServer.IdleTimeout != 45*time.Second ||
					cfg.HTTPServer.ShutdownTimeout != 9*time.Second {
					t.Errorf("HTTPServer overrides = %+v", cfg.HTTPServer)
				}
			},
		},
		{
			name: "missing JWT_SECRET returns error",
			env: map[string]string{
				"AUTH_SERVICE_ADDR":        "auth:50051",
				"ITEM_SERVICE_ADDR":        "item:50052",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
			},
			wantErr: true,
		},
		{
			name: "missing AUTH_SERVICE_ADDR returns error",
			env: map[string]string{
				"JWT_SECRET":               "secret",
				"ITEM_SERVICE_ADDR":        "item:50052",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
			},
			wantErr: true,
		},
		{
			name: "missing ITEM_SERVICE_ADDR returns error",
			env: map[string]string{
				"JWT_SECRET":               "secret",
				"AUTH_SERVICE_ADDR":        "auth:50051",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
			},
			wantErr: true,
		},
		{
			name: "missing TRANSACTION_SERVICE_ADDR returns error",
			env: map[string]string{
				"JWT_SECRET":        "secret",
				"AUTH_SERVICE_ADDR": "auth:50051",
				"ITEM_SERVICE_ADDR": "item:50052",
			},
			wantErr: true,
		},
		{
			name: "invalid grpc timeout returns error",
			env: map[string]string{
				"JWT_SECRET":               "secret",
				"AUTH_SERVICE_ADDR":        "auth:50051",
				"ITEM_SERVICE_ADDR":        "item:50052",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
				"GRPC_CALL_TIMEOUT":        "soon",
			},
			wantErr: true,
		},
		{
			name: "grpc timeout must be smaller than write timeout",
			env: map[string]string{
				"JWT_SECRET":               "secret",
				"AUTH_SERVICE_ADDR":        "auth:50051",
				"ITEM_SERVICE_ADDR":        "item:50052",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
				"GRPC_CALL_TIMEOUT":        "15s",
				"HTTP_WRITE_TIMEOUT":       "15s",
			},
			wantErr: true,
		},
		{
			name: "request timeout must be greater than grpc timeout",
			env: map[string]string{
				"JWT_SECRET":               "secret",
				"AUTH_SERVICE_ADDR":        "auth:50051",
				"ITEM_SERVICE_ADDR":        "item:50052",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
				"GRPC_CALL_TIMEOUT":        "12s",
				"REQUEST_TIMEOUT":          "10s",
			},
			wantErr: true,
		},
		{
			name: "request timeout must be smaller than write timeout",
			env: map[string]string{
				"JWT_SECRET":               "secret",
				"AUTH_SERVICE_ADDR":        "auth:50051",
				"ITEM_SERVICE_ADDR":        "item:50052",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
				"REQUEST_TIMEOUT":          "15s",
				"HTTP_WRITE_TIMEOUT":       "15s",
			},
			wantErr: true,
		},
		{
			name: "invalid http timeout returns error",
			env: map[string]string{
				"JWT_SECRET":               "secret",
				"AUTH_SERVICE_ADDR":        "auth:50051",
				"ITEM_SERVICE_ADDR":        "item:50052",
				"TRANSACTION_SERVICE_ADDR": "tx:50053",
				"HTTP_WRITE_TIMEOUT":       "later",
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Reset all config keys for deterministic isolation.
			for _, k := range []string{
				"HTTP_PORT",
				"JWT_SECRET",
				"AUTH_SERVICE_ADDR",
				"ITEM_SERVICE_ADDR",
				"TRANSACTION_SERVICE_ADDR",
				"GRPC_CALL_TIMEOUT",
				"REQUEST_TIMEOUT",
				"HTTP_READ_HEADER_TIMEOUT",
				"HTTP_READ_TIMEOUT",
				"HTTP_WRITE_TIMEOUT",
				"HTTP_IDLE_TIMEOUT",
				"HTTP_SHUTDOWN_TIMEOUT",
			} {
				t.Setenv(k, "")
			}
			for k, v := range tt.env {
				t.Setenv(k, v)
			}

			cfg, err := Load()

			if tt.wantErr {
				if err == nil {
					t.Fatalf("Load() error = nil, want error")
				}
				return
			}
			if err != nil {
				t.Fatalf("Load() unexpected error: %v", err)
			}
			if tt.check != nil {
				tt.check(t, cfg)
			}
		})
	}
}
