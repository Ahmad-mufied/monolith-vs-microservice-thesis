package config

import (
	"testing"
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
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Set env vars for this test.
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
