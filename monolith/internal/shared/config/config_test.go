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
			name: "loads http server overrides",
			env: map[string]string{
				"DATABASE_URL":             "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":               testJWTSecret(t),
				"HTTP_READ_HEADER_TIMEOUT": "6s",
				"HTTP_READ_TIMEOUT":        "20s",
				"HTTP_WRITE_TIMEOUT":       "40s",
				"HTTP_IDLE_TIMEOUT":        "75s",
				"HTTP_SHUTDOWN_TIMEOUT":    "12s",
				"HTTP_MAX_HEADER_BYTES":    "2097152",
			},
		},
		{
			name: "loads app request timeout override",
			env: map[string]string{
				"DATABASE_URL":        "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":          testJWTSecret(t),
				"APP_REQUEST_TIMEOUT": "12s",
				"HTTP_WRITE_TIMEOUT":  "20s",
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
		{
			name: "invalid http duration",
			env: map[string]string{
				"DATABASE_URL":      "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":        testJWTSecret(t),
				"HTTP_READ_TIMEOUT": "later",
			},
			wantError: true,
		},
		{
			name: "invalid app request timeout",
			env: map[string]string{
				"DATABASE_URL":        "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":          testJWTSecret(t),
				"APP_REQUEST_TIMEOUT": "later",
			},
			wantError: true,
		},
		{
			name: "app request timeout equal to write timeout is allowed",
			env: map[string]string{
				"DATABASE_URL":        "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":          testJWTSecret(t),
				"APP_REQUEST_TIMEOUT": "30s",
				"HTTP_WRITE_TIMEOUT":  "30s",
			},
			wantError: false,
		},
		{
			name: "app request timeout must not exceed write timeout",
			env: map[string]string{
				"DATABASE_URL":        "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":          testJWTSecret(t),
				"APP_REQUEST_TIMEOUT": "40s",
				"HTTP_WRITE_TIMEOUT":  "30s",
			},
			wantError: true,
		},
		{
			name: "invalid http max header bytes",
			env: map[string]string{
				"DATABASE_URL":          "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":            testJWTSecret(t),
				"HTTP_MAX_HEADER_BYTES": "big",
			},
			wantError: true,
		},
		{
			name: "http max header bytes must be positive",
			env: map[string]string{
				"DATABASE_URL":          "postgres://localhost:5432/mono_db?sslmode=disable",
				"JWT_SECRET":            testJWTSecret(t),
				"HTTP_MAX_HEADER_BYTES": "0",
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
			t.Setenv("HTTP_READ_HEADER_TIMEOUT", "")
			t.Setenv("HTTP_READ_TIMEOUT", "")
			t.Setenv("HTTP_WRITE_TIMEOUT", "")
			t.Setenv("HTTP_IDLE_TIMEOUT", "")
			t.Setenv("HTTP_SHUTDOWN_TIMEOUT", "")
			t.Setenv("HTTP_MAX_HEADER_BYTES", "")
			t.Setenv("APP_REQUEST_TIMEOUT", "")
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
			if tt.name == "loads required config with defaults" {
				if got.RequestTimeout != 35*time.Second {
					t.Fatalf("request timeout default = %s, want 35s", got.RequestTimeout)
				}
				if got.HTTPServer.ReadHeaderTimeout != 5*time.Second || got.HTTPServer.ReadTimeout != 15*time.Second || got.HTTPServer.WriteTimeout != 40*time.Second || got.HTTPServer.IdleTimeout != time.Minute || got.HTTPServer.ShutdownTimeout != 10*time.Second || got.HTTPServer.MaxHeaderBytes != 1048576 {
					t.Fatalf("http server defaults = %+v", got.HTTPServer)
				}
			}
			if tt.name == "loads http server overrides" {
				if got.HTTPServer.ReadHeaderTimeout != 6*time.Second || got.HTTPServer.ReadTimeout != 20*time.Second || got.HTTPServer.WriteTimeout != 40*time.Second || got.HTTPServer.IdleTimeout != 75*time.Second || got.HTTPServer.ShutdownTimeout != 12*time.Second || got.HTTPServer.MaxHeaderBytes != 2097152 {
					t.Fatalf("http server overrides = %+v", got.HTTPServer)
				}
			}
			if tt.name == "loads app request timeout override" {
				if got.RequestTimeout != 12*time.Second {
					t.Fatalf("request timeout override = %s, want 12s", got.RequestTimeout)
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
