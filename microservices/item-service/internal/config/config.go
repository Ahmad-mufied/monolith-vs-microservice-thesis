package config

import (
	"fmt"
	"os"

	pkgconfig "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/config"
)

type Config struct {
	GRPCPort    string
	DatabaseURL string
}

func Load() (*Config, error) {
	cfg := &Config{
		GRPCPort:    pkgconfig.GetEnv("GRPC_PORT", "50052"),
		DatabaseURL: os.Getenv("DATABASE_URL"),
	}

	if cfg.DatabaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}

	return cfg, nil
}
