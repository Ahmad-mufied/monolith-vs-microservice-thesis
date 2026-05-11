package config

import (
	"fmt"
	"os"

	pkgconfig "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/config"
)

type Config struct {
	HTTPPort               string
	JWTSecret              string
	AuthServiceAddr        string
	ItemServiceAddr        string
	TransactionServiceAddr string
}

func Load() (*Config, error) {
	cfg := &Config{
		HTTPPort:               pkgconfig.GetEnv("HTTP_PORT", "8080"),
		JWTSecret:              os.Getenv("JWT_SECRET"),
		AuthServiceAddr:        os.Getenv("AUTH_SERVICE_ADDR"),
		ItemServiceAddr:        os.Getenv("ITEM_SERVICE_ADDR"),
		TransactionServiceAddr: os.Getenv("TRANSACTION_SERVICE_ADDR"),
	}

	if cfg.JWTSecret == "" {
		return nil, fmt.Errorf("JWT_SECRET is required")
	}
	if cfg.AuthServiceAddr == "" {
		return nil, fmt.Errorf("AUTH_SERVICE_ADDR is required")
	}
	if cfg.ItemServiceAddr == "" {
		return nil, fmt.Errorf("ITEM_SERVICE_ADDR is required")
	}
	if cfg.TransactionServiceAddr == "" {
		return nil, fmt.Errorf("TRANSACTION_SERVICE_ADDR is required")
	}

	return cfg, nil
}
