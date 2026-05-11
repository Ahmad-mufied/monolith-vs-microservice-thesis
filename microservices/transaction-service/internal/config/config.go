package config

import (
	"fmt"
	"os"

	pkgconfig "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/config"
)

type Config struct {
	GRPCPort        string
	DatabaseURL     string
	ItemServiceAddr string
}

func Load() (*Config, error) {
	cfg := &Config{
		GRPCPort:        pkgconfig.GetEnv("GRPC_PORT", "50053"),
		DatabaseURL:     os.Getenv("DATABASE_URL"),
		ItemServiceAddr: os.Getenv("ITEM_SERVICE_ADDR"),
	}

	if cfg.DatabaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.ItemServiceAddr == "" {
		return nil, fmt.Errorf("ITEM_SERVICE_ADDR is required")
	}

	return cfg, nil
}
