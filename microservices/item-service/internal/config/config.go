package config

import (
	"fmt"
	"os"
	"strconv"
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
	maxConns := getEnvInt32("DB_POOL_MAX_CONNS", 6)
	minConns := getEnvInt32("DB_POOL_MIN_CONNS", 1)
	maxConnLifetime := getEnvDurationOr("DB_POOL_MAX_CONN_LIFETIME", 15*time.Minute)
	maxConnIdleTime := getEnvDurationOr("DB_POOL_MAX_CONN_IDLE_TIME", time.Minute)
	pingTimeout := getEnvDurationOr("DB_PING_TIMEOUT", 5*time.Second)
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

func getEnvInt32(key string, fallback int32) int32 {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.ParseInt(v, 10, 32)
	if err != nil {
		return fallback
	}
	return int32(n)
}

func getEnvDurationOr(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return fallback
	}
	return d
}
