package config

import (
	"crypto/rand"
	"encoding/hex"
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
				"DATABASE_URL": "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":   testJWTSecret(t),
			},
		},
		{
			name: "missing database url",
			env: map[string]string{
				"JWT_SECRET": testJWTSecret(t),
			},
			wantError: true,
		},
		{
			name: "missing jwt secret",
			env: map[string]string{
				"DATABASE_URL": "postgres://localhost:5432/mono_db?sslmode=disable",
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

func testJWTSecret(t *testing.T) string {
	t.Helper()

	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatalf("rand.Read() error: %v", err)
	}
	return hex.EncodeToString(secret)
}
