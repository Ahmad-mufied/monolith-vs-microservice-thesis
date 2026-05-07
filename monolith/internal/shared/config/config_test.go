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
			name: "loads db pool overrides",
			env: map[string]string{
				"DATABASE_URL":               "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":                 testJWTSecret(t),
				"DB_POOL_MAX_CONNS":          "40",
				"DB_POOL_MIN_CONNS":          "4",
				"DB_POOL_MAX_CONN_LIFETIME":  "10m",
				"DB_POOL_MAX_CONN_IDLE_TIME": "2m",
				"DB_PING_TIMEOUT":            "7s",
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
		{
			name: "invalid db pool max conns",
			env: map[string]string{
				"DATABASE_URL":      "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":        testJWTSecret(t),
				"DB_POOL_MAX_CONNS": "abc",
			},
			wantError: true,
		},
		{
			name: "db pool min conns cannot exceed max",
			env: map[string]string{
				"DATABASE_URL":      "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":        testJWTSecret(t),
				"DB_POOL_MAX_CONNS": "2",
				"DB_POOL_MIN_CONNS": "3",
			},
			wantError: true,
		},
		{
			name: "invalid db pool duration",
			env: map[string]string{
				"DATABASE_URL":              "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":                testJWTSecret(t),
				"DB_POOL_MAX_CONN_LIFETIME": "soon",
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
			t.Setenv("DB_POOL_MAX_CONNS", "")
			t.Setenv("DB_POOL_MIN_CONNS", "")
			t.Setenv("DB_POOL_MAX_CONN_LIFETIME", "")
			t.Setenv("DB_POOL_MAX_CONN_IDLE_TIME", "")
			t.Setenv("DB_PING_TIMEOUT", "")
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
			if tt.name == "loads required config with defaults" {
				if got.DBPool.MaxConns != 25 || got.DBPool.MinConns != 2 || got.DBPool.MaxConnLifetime != 5*time.Minute || got.DBPool.MaxConnIdleTime != time.Minute || got.DBPool.PingTimeout != 5*time.Second {
					t.Fatalf("db pool defaults = %+v", got.DBPool)
				}
			}
			if tt.name == "loads db pool overrides" {
				if got.DBPool.MaxConns != 40 || got.DBPool.MinConns != 4 || got.DBPool.MaxConnLifetime != 10*time.Minute || got.DBPool.MaxConnIdleTime != 2*time.Minute || got.DBPool.PingTimeout != 7*time.Second {
					t.Fatalf("db pool overrides = %+v", got.DBPool)
				}
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
