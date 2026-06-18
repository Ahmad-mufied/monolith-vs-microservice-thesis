package config

import (
	"fmt"
	"os"
	"time"

	pkgconfig "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/config"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/postgres"
)

type Config struct {
	GRPCPort           string
	DatabaseURL        string
	GRPCRequestTimeout time.Duration
	DBPool             *postgres.PoolConfig
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
		DBPool:             loadDBPoolConfig(),
	}

	if cfg.DatabaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}

	return cfg, nil
}

func loadDBPoolConfig() *postgres.PoolConfig {
	maxConns := pkgconfig.GetEnvInt32("DB_POOL_MAX_CONNS", 10)
	minConns := pkgconfig.GetEnvInt32("DB_POOL_MIN_CONNS", 1)
	maxConnLifetime := pkgconfig.GetEnvDuration("DB_POOL_MAX_CONN_LIFETIME", 15*time.Minute)
	maxConnIdleTime := pkgconfig.GetEnvDuration("DB_POOL_MAX_CONN_IDLE_TIME", time.Minute)
	pingTimeout := pkgconfig.GetEnvDuration("DB_PING_TIMEOUT", 5*time.Second)
	return &postgres.PoolConfig{
		MaxConns:        maxConns,
		MinConns:        minConns,
		MaxConnLifetime: maxConnLifetime,
		MaxConnIdleTime: maxConnIdleTime,
		PingTimeout:     pingTimeout,
	}
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
