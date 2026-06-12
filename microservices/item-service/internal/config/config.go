package config

import (
	"fmt"
	"os"
	"time"

	pkgconfig "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/config"
)

type Config struct {
	GRPCPort           string
	DatabaseURL        string
	GRPCRequestTimeout time.Duration
}

func Load() (*Config, error) {
	grpcRequestTimeout, err := getEnvDuration("GRPC_REQUEST_TIMEOUT", 30*time.Second)
	if err != nil {
		return nil, fmt.Errorf("GRPC_REQUEST_TIMEOUT: %w", err)
	}
	if grpcRequestTimeout <= 0 {
		return nil, fmt.Errorf("GRPC_REQUEST_TIMEOUT must be greater than 0")
	}

	cfg := &Config{
		GRPCPort:           pkgconfig.GetEnv("GRPC_PORT", "50052"),
		DatabaseURL:        os.Getenv("DATABASE_URL"),
		GRPCRequestTimeout: grpcRequestTimeout,
	}

	if cfg.DatabaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}

	return cfg, nil
}

func getEnvDuration(key string, fallback time.Duration) (time.Duration, error) {
	v := os.Getenv(key)
	if v == "" {
		return fallback, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("must be a valid duration: %w", err)
	}
	return d, nil
}
