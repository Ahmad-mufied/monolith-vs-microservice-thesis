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
				"DATABASE_URL":      "postgres://localhost:5432/transaction_db?sslmode=disable",
				"ITEM_SERVICE_ADDR": "item:50052",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.GRPCPort != "50053" {
					t.Errorf("GRPCPort = %q, want default 50053", cfg.GRPCPort)
				}
				if cfg.GRPCRequestTimeout != 30*time.Second {
					t.Errorf("GRPCRequestTimeout = %s, want 30s", cfg.GRPCRequestTimeout)
				}
				if cfg.ItemValidationTimeout != 25*time.Second {
					t.Errorf("ItemValidationTimeout = %s, want 25s", cfg.ItemValidationTimeout)
				}
			},
		},
		{
			name: "loads grpc request timeout override",
			env: map[string]string{
				"DATABASE_URL":            "postgres://localhost:5432/transaction_db?sslmode=disable",
				"ITEM_SERVICE_ADDR":       "item:50052",
				"GRPC_REQUEST_TIMEOUT":    "45s",
				"ITEM_VALIDATION_TIMEOUT": "25s",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.GRPCRequestTimeout != 45*time.Second {
					t.Errorf("GRPCRequestTimeout = %s, want 45s", cfg.GRPCRequestTimeout)
				}
			},
		},
		{
			name: "loads item validation timeout override",
			env: map[string]string{
				"DATABASE_URL":            "postgres://localhost:5432/transaction_db?sslmode=disable",
				"ITEM_SERVICE_ADDR":       "item:50052",
				"ITEM_VALIDATION_TIMEOUT": "9s",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.ItemValidationTimeout != 9*time.Second {
					t.Errorf("ItemValidationTimeout = %s, want 9s", cfg.ItemValidationTimeout)
				}
			},
		},
		{
			name: "missing database url returns error",
			env: map[string]string{
				"ITEM_SERVICE_ADDR": "item:50052",
			},
			wantErr: true,
		},
		{
			name: "missing item service addr returns error",
			env: map[string]string{
				"DATABASE_URL": "postgres://localhost:5432/transaction_db?sslmode=disable",
			},
			wantErr: true,
		},
		{
			name: "invalid grpc request timeout returns error",
			env: map[string]string{
				"DATABASE_URL":         "postgres://localhost:5432/transaction_db?sslmode=disable",
				"ITEM_SERVICE_ADDR":    "item:50052",
				"GRPC_REQUEST_TIMEOUT": "soon",
			},
			wantErr: true,
		},
		{
			name: "grpc request timeout must be positive",
			env: map[string]string{
				"DATABASE_URL":         "postgres://localhost:5432/transaction_db?sslmode=disable",
				"ITEM_SERVICE_ADDR":    "item:50052",
				"GRPC_REQUEST_TIMEOUT": "0s",
			},
			wantErr: true,
		},
		{
			name: "invalid item validation timeout returns error",
			env: map[string]string{
				"DATABASE_URL":            "postgres://localhost:5432/transaction_db?sslmode=disable",
				"ITEM_SERVICE_ADDR":       "item:50052",
				"ITEM_VALIDATION_TIMEOUT": "soon",
			},
			wantErr: true,
		},
		{
			name: "item validation timeout must be positive",
			env: map[string]string{
				"DATABASE_URL":            "postgres://localhost:5432/transaction_db?sslmode=disable",
				"ITEM_SERVICE_ADDR":       "item:50052",
				"ITEM_VALIDATION_TIMEOUT": "0s",
			},
			wantErr: true,
		},
		{
			name: "item validation timeout must be smaller than grpc request timeout",
			env: map[string]string{
				"DATABASE_URL":            "postgres://localhost:5432/transaction_db?sslmode=disable",
				"ITEM_SERVICE_ADDR":       "item:50052",
				"GRPC_REQUEST_TIMEOUT":    "10s",
				"ITEM_VALIDATION_TIMEOUT": "10s",
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			for _, key := range []string{
				"GRPC_PORT",
				"DATABASE_URL",
				"ITEM_SERVICE_ADDR",
				"GRPC_REQUEST_TIMEOUT",
				"ITEM_VALIDATION_TIMEOUT",
			} {
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
