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
	ItemServiceAddr    string
	GRPCRequestTimeout time.Duration
	// ItemValidationTimeout is the per-call deadline applied when the
	// transaction service calls the item service to validate transaction items.
	// It must be smaller than the caller's (API Gateway's) gRPC call timeout so
	// that a slow item service is surfaced as a dependency error before the
	// parent request budget is exhausted.
	ItemValidationTimeout time.Duration
}

func Load() (*Config, error) {
	grpcRequestTimeout, err := getEnvDuration("GRPC_REQUEST_TIMEOUT", 30*time.Second)
	if err != nil {
		return nil, fmt.Errorf("GRPC_REQUEST_TIMEOUT: %w", err)
	}
	if grpcRequestTimeout <= 0 {
		return nil, fmt.Errorf("GRPC_REQUEST_TIMEOUT must be greater than 0")
	}

	itemValidationTimeout, err := getEnvDuration("ITEM_VALIDATION_TIMEOUT", 25*time.Second)
	if err != nil {
		return nil, fmt.Errorf("ITEM_VALIDATION_TIMEOUT: %w", err)
	}
	if itemValidationTimeout <= 0 {
		return nil, fmt.Errorf("ITEM_VALIDATION_TIMEOUT must be greater than 0")
	}
	if itemValidationTimeout >= grpcRequestTimeout {
		return nil, fmt.Errorf(
			"ITEM_VALIDATION_TIMEOUT (%s) must be smaller than GRPC_REQUEST_TIMEOUT (%s)",
			itemValidationTimeout,
			grpcRequestTimeout,
		)
	}

	cfg := &Config{
		GRPCPort:              pkgconfig.GetEnv("GRPC_PORT", "50053"),
		DatabaseURL:           os.Getenv("DATABASE_URL"),
		ItemServiceAddr:       os.Getenv("ITEM_SERVICE_ADDR"),
		GRPCRequestTimeout:    grpcRequestTimeout,
		ItemValidationTimeout: itemValidationTimeout,
	}

	if cfg.DatabaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.ItemServiceAddr == "" {
		return nil, fmt.Errorf("ITEM_SERVICE_ADDR is required")
	}

	return cfg, nil
}

// getEnvDuration parses a duration env var. Returns (fallback, nil) when the
// variable is unset, and (0, error) when the value is present but invalid.
// This rejects invalid values explicitly rather than silently falling back.
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
