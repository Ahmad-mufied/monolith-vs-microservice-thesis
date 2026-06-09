package config

import (
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type DBPoolConfig struct {
	MaxConns        int32
	MinConns        int32
	MaxConnLifetime time.Duration
	MaxConnIdleTime time.Duration
	PingTimeout     time.Duration
}

type HTTPServerConfig struct {
	ReadHeaderTimeout time.Duration
	ReadTimeout       time.Duration
	WriteTimeout      time.Duration
	IdleTimeout       time.Duration
	ShutdownTimeout   time.Duration
	MaxHeaderBytes    int
}

type Config struct {
	AppEnv         string
	AppPort        string
	ServiceName    string
	DatabaseURL    string
	DBPool         DBPoolConfig
	HTTPServer     HTTPServerConfig
	JWTSecret      string
	JWTTokenTTL    time.Duration
	BcryptCost     int
	DatadogEnabled bool
	// RequestTimeout is the application-level per-request deadline applied as a
	// context timeout inside the timeout middleware. This is distinct from the
	// HTTP server transport timeouts (HTTPServer.WriteTimeout etc.). It must be
	// smaller than HTTPServer.WriteTimeout so the app can write a proper error
	// response before the transport closes the connection.
	RequestTimeout time.Duration
}

func Load() (Config, error) {
	dbPool, err := loadDBPoolConfig()
	if err != nil {
		return Config{}, err
	}
	httpServer, err := loadHTTPServerConfig()
	if err != nil {
		return Config{}, err
	}
	bcryptCost, err := getEnvInt("BCRYPT_COST", bcrypt.DefaultCost)
	if err != nil {
		return Config{}, fmt.Errorf("BCRYPT_COST: %w", err)
	}

	requestTimeout, err := getEnvDuration("APP_REQUEST_TIMEOUT", 30*time.Second)
	if err != nil {
		return Config{}, fmt.Errorf("APP_REQUEST_TIMEOUT: %w", err)
	}
	if requestTimeout <= 0 {
		return Config{}, fmt.Errorf("APP_REQUEST_TIMEOUT must be greater than 0")
	}

	cfg := Config{
		AppEnv:         getEnv("APP_ENV", "development"),
		AppPort:        getEnv("APP_PORT", "8080"),
		ServiceName:    getEnv("SERVICE_NAME", "monolith"),
		DatabaseURL:    os.Getenv("DATABASE_URL"),
		DBPool:         dbPool,
		HTTPServer:     httpServer,
		JWTSecret:      os.Getenv("JWT_SECRET"),
		JWTTokenTTL:    24 * time.Hour,
		BcryptCost:     bcryptCost,
		DatadogEnabled: os.Getenv("DATADOG_ENABLED") == "true",
		RequestTimeout: requestTimeout,
	}

	if cfg.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.JWTSecret == "" {
		return Config{}, fmt.Errorf("JWT_SECRET is required")
	}
	if cfg.BcryptCost < bcrypt.MinCost || cfg.BcryptCost > bcrypt.MaxCost {
		return Config{}, fmt.Errorf("BCRYPT_COST must be between %d and %d", bcrypt.MinCost, bcrypt.MaxCost)
	}
	if cfg.RequestTimeout >= cfg.HTTPServer.WriteTimeout {
		return Config{}, fmt.Errorf("APP_REQUEST_TIMEOUT (%s) must be smaller than HTTP_WRITE_TIMEOUT (%s)", cfg.RequestTimeout, cfg.HTTPServer.WriteTimeout)
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

func loadHTTPServerConfig() (HTTPServerConfig, error) {
	readHeaderTimeout, err := getEnvDuration("HTTP_READ_HEADER_TIMEOUT", 5*time.Second)
	if err != nil {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_READ_HEADER_TIMEOUT: %w", err)
	}
	if readHeaderTimeout <= 0 {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_READ_HEADER_TIMEOUT must be greater than 0")
	}

	readTimeout, err := getEnvDuration("HTTP_READ_TIMEOUT", 15*time.Second)
	if err != nil {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_READ_TIMEOUT: %w", err)
	}
	if readTimeout <= 0 {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_READ_TIMEOUT must be greater than 0")
	}

	writeTimeout, err := getEnvDuration("HTTP_WRITE_TIMEOUT", 35*time.Second)
	if err != nil {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_WRITE_TIMEOUT: %w", err)
	}
	if writeTimeout <= 0 {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_WRITE_TIMEOUT must be greater than 0")
	}

	idleTimeout, err := getEnvDuration("HTTP_IDLE_TIMEOUT", time.Minute)
	if err != nil {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_IDLE_TIMEOUT: %w", err)
	}
	if idleTimeout <= 0 {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_IDLE_TIMEOUT must be greater than 0")
	}

	shutdownTimeout, err := getEnvDuration("HTTP_SHUTDOWN_TIMEOUT", 10*time.Second)
	if err != nil {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_SHUTDOWN_TIMEOUT: %w", err)
	}
	if shutdownTimeout <= 0 {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_SHUTDOWN_TIMEOUT must be greater than 0")
	}

	maxHeaderBytes, err := getEnvInt("HTTP_MAX_HEADER_BYTES", http.DefaultMaxHeaderBytes)
	if err != nil {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_MAX_HEADER_BYTES: %w", err)
	}
	if maxHeaderBytes <= 0 {
		return HTTPServerConfig{}, fmt.Errorf("HTTP_MAX_HEADER_BYTES must be greater than 0")
	}

	return HTTPServerConfig{
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		ShutdownTimeout:   shutdownTimeout,
		MaxHeaderBytes:    maxHeaderBytes,
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

func getEnvInt(key string, fallback int) (int, error) {
	value := os.Getenv(key)
	if value == "" {
		return fallback, nil
	}

	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("must be a valid integer: %w", err)
	}
	return parsed, nil
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
