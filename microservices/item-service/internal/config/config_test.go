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
			name: "loads required config with defaults",
			env: map[string]string{
				"DATABASE_URL": "postgres://localhost:5432/item_db?sslmode=disable",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.GRPCPort != "50052" {
					t.Errorf("GRPCPort = %q, want default 50052", cfg.GRPCPort)
				}
				if cfg.GRPCRequestTimeout != 30*time.Second {
					t.Errorf("GRPCRequestTimeout = %s, want 30s", cfg.GRPCRequestTimeout)
				}
			},
		},
		{
			name: "loads grpc request timeout override",
			env: map[string]string{
				"DATABASE_URL":         "postgres://localhost:5432/item_db?sslmode=disable",
				"GRPC_REQUEST_TIMEOUT": "12s",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.GRPCRequestTimeout != 12*time.Second {
					t.Errorf("GRPCRequestTimeout = %s, want 12s", cfg.GRPCRequestTimeout)
				}
			},
		},
		{
			name: "invalid grpc request timeout returns error",
			env: map[string]string{
				"DATABASE_URL":         "postgres://localhost:5432/item_db?sslmode=disable",
				"GRPC_REQUEST_TIMEOUT": "soon",
			},
			wantErr: true,
		},
		{
			name: "grpc request timeout must be positive",
			env: map[string]string{
				"DATABASE_URL":         "postgres://localhost:5432/item_db?sslmode=disable",
				"GRPC_REQUEST_TIMEOUT": "0s",
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			for _, key := range []string{"GRPC_PORT", "DATABASE_URL", "GRPC_REQUEST_TIMEOUT"} {
				t.Setenv(key, "")
			}
			for key, value := range tt.env {
				t.Setenv(key, value)
			}

			cfg, err := Load()
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.check != nil {
				tt.check(t, cfg)
			}
		})
	}
}
