package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type DBPoolConfig struct {
	MaxConns        int32
	MinConns        int32
	MaxConnLifetime time.Duration
	MaxConnIdleTime time.Duration
	PingTimeout     time.Duration
}

type Config struct {
	AppEnv         string
	AppPort        string
	ServiceName    string
	DatabaseURL    string
	DBPool         DBPoolConfig
	JWTSecret      string
	JWTTokenTTL    time.Duration
	DatadogEnabled bool
}

func Load() (Config, error) {
	dbPool, err := loadDBPoolConfig()
	if err != nil {
		return Config{}, err
	}

	cfg := Config{
		AppEnv:         getEnv("APP_ENV", "development"),
		AppPort:        getEnv("APP_PORT", "8080"),
		ServiceName:    getEnv("SERVICE_NAME", "monolith"),
		DatabaseURL:    os.Getenv("DATABASE_URL"),
		DBPool:         dbPool,
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

func loadDBPoolConfig() (DBPoolConfig, error) {
	maxConns, err := getEnvInt32("DB_POOL_MAX_CONNS", 25)
	if err != nil {
		return DBPoolConfig{}, fmt.Errorf("DB_POOL_MAX_CONNS: %w", err)
	}
	if maxConns <= 0 {
		return DBPoolConfig{}, fmt.Errorf("DB_POOL_MAX_CONNS must be greater than 0")
	}

	minConns, err := getEnvInt32("DB_POOL_MIN_CONNS", 2)
	if err != nil {
		return DBPoolConfig{}, fmt.Errorf("DB_POOL_MIN_CONNS: %w", err)
	}
	if minConns < 0 {
		return DBPoolConfig{}, fmt.Errorf("DB_POOL_MIN_CONNS must be greater than or equal to 0")
	}
	if minConns > maxConns {
		return DBPoolConfig{}, fmt.Errorf("DB_POOL_MIN_CONNS must not exceed DB_POOL_MAX_CONNS")
	}

	maxConnLifetime, err := getEnvDuration("DB_POOL_MAX_CONN_LIFETIME", 5*time.Minute)
	if err != nil {
		return DBPoolConfig{}, fmt.Errorf("DB_POOL_MAX_CONN_LIFETIME: %w", err)
	}
	if maxConnLifetime <= 0 {
		return DBPoolConfig{}, fmt.Errorf("DB_POOL_MAX_CONN_LIFETIME must be greater than 0")
	}

	maxConnIdleTime, err := getEnvDuration("DB_POOL_MAX_CONN_IDLE_TIME", time.Minute)
	if err != nil {
		return DBPoolConfig{}, fmt.Errorf("DB_POOL_MAX_CONN_IDLE_TIME: %w", err)
	}
	if maxConnIdleTime <= 0 {
		return DBPoolConfig{}, fmt.Errorf("DB_POOL_MAX_CONN_IDLE_TIME must be greater than 0")
	}

	pingTimeout, err := getEnvDuration("DB_PING_TIMEOUT", 5*time.Second)
	if err != nil {
		return DBPoolConfig{}, fmt.Errorf("DB_PING_TIMEOUT: %w", err)
	}
	if pingTimeout <= 0 {
		return DBPoolConfig{}, fmt.Errorf("DB_PING_TIMEOUT must be greater than 0")
	}

	return DBPoolConfig{
		MaxConns:        maxConns,
		MinConns:        minConns,
		MaxConnLifetime: maxConnLifetime,
		MaxConnIdleTime: maxConnIdleTime,
		PingTimeout:     pingTimeout,
	}, nil
}

func getEnv(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}

func getEnvInt32(key string, fallback int32) (int32, error) {
	value := os.Getenv(key)
	if value == "" {
		return fallback, nil
	}

	parsed, err := strconv.ParseInt(value, 10, 32)
	if err != nil {
		return 0, fmt.Errorf("must be a valid integer: %w", err)
	}
	return int32(parsed), nil
}

func getEnvDuration(key string, fallback time.Duration) (time.Duration, error) {
	value := os.Getenv(key)
	if value == "" {
		return fallback, nil
	}

	parsed, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("must be a valid duration: %w", err)
	}
	return parsed, nil
}
