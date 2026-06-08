package config

import (
	"fmt"
	"os"
	"time"

	pkgconfig "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/config"
)

// HTTPServerConfig holds transport-level timeout settings for the API Gateway's
// HTTP server. These are distinct from the application-level gRPC call timeout.
type HTTPServerConfig struct {
	ReadHeaderTimeout time.Duration
	ReadTimeout       time.Duration
	// WriteTimeout must be greater than GRPCCallTimeout so the app can write
	// a proper error response (503/499) before the transport closes the
	// connection.
	WriteTimeout    time.Duration
	IdleTimeout     time.Duration
	ShutdownTimeout time.Duration
}

type Config struct {
	HTTPPort               string
	JWTSecret              string
	AuthServiceAddr        string
	ItemServiceAddr        string
	TransactionServiceAddr string
	HTTPServer             HTTPServerConfig
	// GRPCCallTimeout is the application-level per-call deadline applied to
	// every outbound gRPC request made by the API Gateway. It must be smaller
	// than HTTPServer.WriteTimeout so the gateway has time to translate the
	// deadline error into a 503 response before the transport cuts off.
	GRPCCallTimeout time.Duration
}

func Load() (*Config, error) {
	httpServer, err := loadHTTPServerConfig()
	if err != nil {
		return nil, err
	}

	grpcCallTimeout, err := getEnvDuration("GRPC_CALL_TIMEOUT", 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("GRPC_CALL_TIMEOUT: %w", err)
	}
	if grpcCallTimeout <= 0 {
		return nil, fmt.Errorf("GRPC_CALL_TIMEOUT must be greater than 0")
	}

	cfg := &Config{
		HTTPPort:               pkgconfig.GetEnv("HTTP_PORT", "8080"),
		JWTSecret:              os.Getenv("JWT_SECRET"),
		AuthServiceAddr:        os.Getenv("AUTH_SERVICE_ADDR"),
		ItemServiceAddr:        os.Getenv("ITEM_SERVICE_ADDR"),
		TransactionServiceAddr: os.Getenv("TRANSACTION_SERVICE_ADDR"),
		HTTPServer:             httpServer,
		GRPCCallTimeout:        grpcCallTimeout,
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
	if cfg.GRPCCallTimeout >= cfg.HTTPServer.WriteTimeout {
		return nil, fmt.Errorf("GRPC_CALL_TIMEOUT (%s) must be smaller than HTTP_WRITE_TIMEOUT (%s)", cfg.GRPCCallTimeout, cfg.HTTPServer.WriteTimeout)
	}

	return cfg, nil
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

	writeTimeout, err := getEnvDuration("HTTP_WRITE_TIMEOUT", 15*time.Second)
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

	return HTTPServerConfig{
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		ShutdownTimeout:   shutdownTimeout,
	}, nil
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
