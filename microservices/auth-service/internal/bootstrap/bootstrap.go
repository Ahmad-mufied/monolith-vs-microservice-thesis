package bootstrap

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	grpcserveradapter "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/adapter/grpcserver"
	postgresadapter "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/adapter/postgres"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/config"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/usecase"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/admission"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/grpcutil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/logger"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/observability"
	pkgpostgres "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/postgres"
	authv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/auth/v1"
	grpctrace "github.com/DataDog/dd-trace-go/contrib/google.golang.org/grpc/v2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/keepalive"
)

const shutdownTimeout = 10 * time.Second

func Run() error {
	slog.SetDefault(logger.New(os.Getenv("LOG_LEVEL")).With("service", "auth-service"))

	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	serviceName := observability.ServiceName("auth-service")
	stopObservability, err := observability.Start(serviceName)
	if err != nil {
		return fmt.Errorf("start observability: %w", err)
	}
	defer stopObservability()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := pkgpostgres.Connect(ctx, cfg.DatabaseURL, cfg.DBPool)
	if err != nil {
		return fmt.Errorf("connect postgres: %w", err)
	}
	defer pool.Close()

	repo := postgresadapter.NewUserRepository(pool)

	loginLimiter, err := admission.NewLimiter(cfg.LoginAdmission)
	if err != nil {
		return fmt.Errorf("create login limiter: %w", err)
	}

	uc := usecase.NewAuthUsecase(repo, cfg.JWTSecret, cfg.JWTExpiry, cfg.BcryptCost, loginLimiter)
	srv := grpcserveradapter.NewAuthServer(uc)

	grpcServer := grpc.NewServer(grpcServerOptions(serviceName, cfg.GRPCRequestTimeout)...)
	authv1.RegisterAuthServiceServer(grpcServer, srv)

	listener, err := net.Listen("tcp", ":"+cfg.GRPCPort)
	if err != nil {
		return fmt.Errorf("listen grpc port: %w", err)
	}

	serverErr := make(chan error, 1)
	go func() {
		serverErr <- grpcServer.Serve(listener)
	}()

	slog.Info("auth-service gRPC listening",
		"grpc_port", cfg.GRPCPort,
		"grpc_request_timeout", cfg.GRPCRequestTimeout.String(),
		"login_admission_enabled", cfg.LoginAdmission.Enabled,
		"login_max_concurrency", cfg.LoginAdmission.MaxConcurrency,
	)

	select {
	case <-ctx.Done():
		stopped := make(chan struct{})
		go func() {
			grpcServer.GracefulStop()
			close(stopped)
		}()

		select {
		case <-stopped:
		case <-time.After(shutdownTimeout):
			slog.Warn("auth-service graceful shutdown timed out; forcing stop", "shutdown_timeout", shutdownTimeout.String())
			grpcServer.Stop()
		}

		return nil
	case err := <-serverErr:
		return fmt.Errorf("serve grpc: %w", err)
	}
}

func grpcServerOptions(serviceName string, requestTimeout time.Duration) []grpc.ServerOption {
	opts := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(
			grpcutil.UnaryServerTimeout(requestTimeout),
			grpctrace.UnaryServerInterceptor(grpctrace.WithService(serviceName)),
		),
		grpc.ChainStreamInterceptor(grpctrace.StreamServerInterceptor(grpctrace.WithService(serviceName))),
	}

	if maxAgeStr := os.Getenv("GRPC_MAX_CONNECTION_AGE"); maxAgeStr != "" {
		if d, err := time.ParseDuration(maxAgeStr); err == nil && d > 0 {
			opts = append(opts, grpc.KeepaliveParams(keepalive.ServerParameters{
				MaxConnectionAge:      d,
				MaxConnectionAgeGrace: 5 * time.Second,
			}))
		}
	}

	return opts
}
