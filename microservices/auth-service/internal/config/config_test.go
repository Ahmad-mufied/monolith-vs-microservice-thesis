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
				"DATABASE_URL": "postgres://localhost:5432/auth_db?sslmode=disable",
				"JWT_SECRET":   "secret",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.GRPCPort != "50051" {
					t.Errorf("GRPCPort = %q, want default 50051", cfg.GRPCPort)
				}
				if cfg.GRPCRequestTimeout != 30*time.Second {
					t.Errorf("GRPCRequestTimeout = %s, want 30s", cfg.GRPCRequestTimeout)
				}
				if !cfg.LoginAdmission.Enabled {
					t.Errorf("LoginAdmission.Enabled = false, want true")
				}
				if cfg.LoginAdmission.MaxConcurrency != 2 {
					t.Errorf("LoginAdmission.MaxConcurrency = %d, want 2", cfg.LoginAdmission.MaxConcurrency)
				}
				if cfg.LoginAdmission.QueueTimeout != 2*time.Second {
					t.Errorf("LoginAdmission.QueueTimeout = %s, want 2s", cfg.LoginAdmission.QueueTimeout)
				}
			},
		},
		{
			name: "loads grpc request timeout override",
			env: map[string]string{
				"DATABASE_URL":         "postgres://localhost:5432/auth_db?sslmode=disable",
				"JWT_SECRET":           "secret",
				"GRPC_REQUEST_TIMEOUT": "12s",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.GRPCRequestTimeout != 12*time.Second {
					t.Errorf("GRPCRequestTimeout = %s, want 12s", cfg.GRPCRequestTimeout)
				}
			},
		},
		{
			name: "loads login admission overrides when enabled",
			env: map[string]string{
				"DATABASE_URL":            "postgres://localhost:5432/auth_db?sslmode=disable",
				"JWT_SECRET":              "secret",
				"LOGIN_ADMISSION_ENABLED": "true",
				"LOGIN_MAX_CONCURRENCY":   "3",
				"LOGIN_QUEUE_TIMEOUT":     "1500ms",
			},
			check: func(t *testing.T, cfg *Config) {
				if !cfg.LoginAdmission.Enabled {
					t.Errorf("LoginAdmission.Enabled = false, want true")
				}
				if cfg.LoginAdmission.MaxConcurrency != 3 {
					t.Errorf("LoginAdmission.MaxConcurrency = %d, want 3", cfg.LoginAdmission.MaxConcurrency)
				}
				if cfg.LoginAdmission.QueueTimeout != 1500*time.Millisecond {
					t.Errorf("LoginAdmission.QueueTimeout = %s, want 1500ms", cfg.LoginAdmission.QueueTimeout)
				}
			},
		},
		{
			name: "disabled login admission ignores limiter env values",
			env: map[string]string{
				"DATABASE_URL":            "postgres://localhost:5432/auth_db?sslmode=disable",
				"JWT_SECRET":              "secret",
				"LOGIN_ADMISSION_ENABLED": "false",
				"LOGIN_MAX_CONCURRENCY":   "not-a-number",
				"LOGIN_QUEUE_TIMEOUT":     "not-a-duration",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.LoginAdmission.Enabled {
					t.Errorf("LoginAdmission.Enabled = true, want false")
				}
				if cfg.LoginAdmission.MaxConcurrency != 0 {
					t.Errorf("LoginAdmission.MaxConcurrency = %d, want 0", cfg.LoginAdmission.MaxConcurrency)
				}
				if cfg.LoginAdmission.QueueTimeout != 0 {
					t.Errorf("LoginAdmission.QueueTimeout = %s, want 0s", cfg.LoginAdmission.QueueTimeout)
				}
			},
		},
		{
			name: "invalid login admission enabled returns error",
			env: map[string]string{
				"DATABASE_URL":            "postgres://localhost:5432/auth_db?sslmode=disable",
				"JWT_SECRET":              "secret",
				"LOGIN_ADMISSION_ENABLED": "tru",
			},
			wantErr: true,
		},
		{
			name: "invalid grpc request timeout returns error",
			env: map[string]string{
				"DATABASE_URL":         "postgres://localhost:5432/auth_db?sslmode=disable",
				"JWT_SECRET":           "secret",
				"GRPC_REQUEST_TIMEOUT": "soon",
			},
			wantErr: true,
		},
		{
			name: "grpc request timeout must be positive",
			env: map[string]string{
				"DATABASE_URL":         "postgres://localhost:5432/auth_db?sslmode=disable",
				"JWT_SECRET":           "secret",
				"GRPC_REQUEST_TIMEOUT": "0s",
			},
			wantErr: true,
		},
		{
			name: "login max concurrency must be positive when admission is enabled",
			env: map[string]string{
				"DATABASE_URL":            "postgres://localhost:5432/auth_db?sslmode=disable",
				"JWT_SECRET":              "secret",
				"LOGIN_ADMISSION_ENABLED": "true",
				"LOGIN_MAX_CONCURRENCY":   "0",
			},
			wantErr: true,
		},
		{
			name: "login queue timeout must be positive when admission is enabled",
			env: map[string]string{
				"DATABASE_URL":            "postgres://localhost:5432/auth_db?sslmode=disable",
				"JWT_SECRET":              "secret",
				"LOGIN_ADMISSION_ENABLED": "true",
				"LOGIN_QUEUE_TIMEOUT":     "0s",
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			for _, key := range []string{
				"GRPC_PORT",
				"DATABASE_URL",
				"JWT_SECRET",
				"JWT_EXPIRY",
				"BCRYPT_COST",
				"GRPC_REQUEST_TIMEOUT",
				"LOGIN_ADMISSION_ENABLED",
				"LOGIN_MAX_CONCURRENCY",
				"LOGIN_QUEUE_TIMEOUT",
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
