package config

import (
	"fmt"
	"os"
	"time"

	pkgconfig "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/config"
	"golang.org/x/crypto/bcrypt"
)

type Config struct {
	GRPCPort    string
	DatabaseURL string
	JWTSecret   string
	JWTExpiry   time.Duration
	BcryptCost  int
}

func Load() (*Config, error) {
	cfg := &Config{
		GRPCPort:    pkgconfig.GetEnv("GRPC_PORT", "50051"),
		DatabaseURL: os.Getenv("DATABASE_URL"),
		JWTSecret:   os.Getenv("JWT_SECRET"),
		JWTExpiry:   pkgconfig.GetEnvDuration("JWT_EXPIRY", 24*time.Hour),
		BcryptCost:  pkgconfig.GetEnvInt("BCRYPT_COST", bcrypt.DefaultCost),
	}

	if cfg.DatabaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.JWTSecret == "" {
		return nil, fmt.Errorf("JWT_SECRET is required")
	}
	if cfg.JWTExpiry <= 0 {
		return nil, fmt.Errorf("JWT_EXPIRY must be a positive duration")
	}
	if cfg.BcryptCost < bcrypt.MinCost || cfg.BcryptCost > bcrypt.MaxCost {
		return nil, fmt.Errorf("BCRYPT_COST must be between %d and %d", bcrypt.MinCost, bcrypt.MaxCost)
	}

	return cfg, nil
}
