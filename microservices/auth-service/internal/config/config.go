package config

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/admission"
	pkgconfig "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/config"
	"golang.org/x/crypto/bcrypt"
)

type Config struct {
	GRPCPort           string
	DatabaseURL        string
	JWTSecret          string
	JWTExpiry          time.Duration
	BcryptCost         int
	GRPCRequestTimeout time.Duration
	LoginAdmission     admission.Config
}

func Load() (*Config, error) {
	grpcRequestTimeout, err := getEnvDuration("GRPC_REQUEST_TIMEOUT", 30*time.Second)
	if err != nil {
		return nil, fmt.Errorf("GRPC_REQUEST_TIMEOUT: %w", err)
	}
	if grpcRequestTimeout <= 0 {
		return nil, fmt.Errorf("GRPC_REQUEST_TIMEOUT must be greater than 0")
	}

	loginAdmissionEnabled, err := getEnvBool("LOGIN_ADMISSION_ENABLED", true)
	if err != nil {
		return nil, fmt.Errorf("LOGIN_ADMISSION_ENABLED: %w", err)
	}
	loginAdmission := admission.Config{Enabled: loginAdmissionEnabled}
	if loginAdmissionEnabled {
		loginMaxConcurrency, err := getEnvInt("LOGIN_MAX_CONCURRENCY", 2)
		if err != nil {
			return nil, fmt.Errorf("LOGIN_MAX_CONCURRENCY: %w", err)
		}
		loginQueueTimeout, err := getEnvDuration("LOGIN_QUEUE_TIMEOUT", 2*time.Second)
		if err != nil {
			return nil, fmt.Errorf("LOGIN_QUEUE_TIMEOUT: %w", err)
		}
		loginAdmission.MaxConcurrency = loginMaxConcurrency
		loginAdmission.QueueTimeout = loginQueueTimeout
	}

	cfg := &Config{
		GRPCPort:           pkgconfig.GetEnv("GRPC_PORT", "50051"),
		DatabaseURL:        os.Getenv("DATABASE_URL"),
		JWTSecret:          os.Getenv("JWT_SECRET"),
		JWTExpiry:          pkgconfig.GetEnvDuration("JWT_EXPIRY", 24*time.Hour),
		BcryptCost:         pkgconfig.GetEnvInt("BCRYPT_COST", bcrypt.DefaultCost),
		GRPCRequestTimeout: grpcRequestTimeout,
		LoginAdmission:     loginAdmission,
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

func getEnvInt(key string, fallback int) (int, error) {
	v := os.Getenv(key)
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("must be a valid integer: %w", err)
	}
	return n, nil
}

func getEnvBool(key string, fallback bool) (bool, error) {
	v := os.Getenv(key)
	if v == "" {
		return fallback, nil
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return false, fmt.Errorf("must be a valid boolean: %w", err)
	}
	return b, nil
}
