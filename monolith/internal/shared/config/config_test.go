package config

import (
	"testing"
	"time"
)

func TestLoad(t *testing.T) {
	tests := []struct {
		name      string
		env       map[string]string
		wantError bool
	}{
		{
			name: "loads required config with defaults",
			env: map[string]string{
				"DATABASE_URL": "postgres://user:pass@localhost:5432/mono_db",
				"JWT_SECRET":   "secret",
			},
		},
		{
			name: "missing database url",
			env: map[string]string{
				"JWT_SECRET": "secret",
			},
			wantError: true,
		},
		{
			name: "missing jwt secret",
			env: map[string]string{
				"DATABASE_URL": "postgres://user:pass@localhost:5432/mono_db",
			},
			wantError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("APP_ENV", "")
			t.Setenv("APP_PORT", "")
			t.Setenv("SERVICE_NAME", "")
			t.Setenv("DATABASE_URL", "")
			t.Setenv("JWT_SECRET", "")
			t.Setenv("DATADOG_ENABLED", "")
			for key, value := range tt.env {
				t.Setenv(key, value)
			}

			got, err := Load()
			if tt.wantError {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.AppPort != "8080" || got.ServiceName != "monolith" || got.JWTTokenTTL != 24*time.Hour {
				t.Fatalf("config defaults = %+v", got)
			}
		})
	}
}
