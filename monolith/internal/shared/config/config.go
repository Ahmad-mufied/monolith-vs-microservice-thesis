package config

import (
	"fmt"
	"os"
	"time"
)

type Config struct {
	AppEnv         string
	AppPort        string
	ServiceName    string
	DatabaseURL    string
	JWTSecret      string
	JWTTokenTTL    time.Duration
	DatadogEnabled bool
}

func Load() (Config, error) {
	cfg := Config{
		AppEnv:         getEnv("APP_ENV", "development"),
		AppPort:        getEnv("APP_PORT", "8080"),
		ServiceName:    getEnv("SERVICE_NAME", "monolith"),
		DatabaseURL:    os.Getenv("DATABASE_URL"),
		JWTSecret:      os.Getenv("JWT_SECRET"),
		JWTTokenTTL:    24 * time.Hour,
		DatadogEnabled: os.Getenv("DATADOG_ENABLED") == "true",
	}

	if cfg.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.JWTSecret == "" {
		return Config{}, fmt.Errorf("JWT_SECRET is required")
	}

	return cfg, nil
}

func getEnv(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}
