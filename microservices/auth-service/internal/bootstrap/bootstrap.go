package bootstrap

import (
	"context"
	"fmt"
	"log"
	"net"
	"os/signal"
	"syscall"

	grpcserveradapter "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/adapter/grpcserver"
	postgresadapter "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/adapter/postgres"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/config"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/usecase"
	pkgpostgres "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/postgres"
	authv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/auth/v1"
	"google.golang.org/grpc"
)

func Run() error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := pkgpostgres.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("connect postgres: %w", err)
	}
	defer pool.Close()

	repo := postgresadapter.NewUserRepository(pool)
	uc := usecase.NewAuthUsecase(repo, cfg.JWTSecret, cfg.JWTExpiry, cfg.BcryptCost)
	srv := grpcserveradapter.NewAuthServer(uc)

	grpcServer := grpc.NewServer()
	authv1.RegisterAuthServiceServer(grpcServer, srv)

	listener, err := net.Listen("tcp", ":"+cfg.GRPCPort)
	if err != nil {
		return fmt.Errorf("listen grpc port: %w", err)
	}

	serverErr := make(chan error, 1)
	go func() {
		serverErr <- grpcServer.Serve(listener)
	}()

	log.Printf("auth-service gRPC listening on :%s", cfg.GRPCPort)

	select {
	case <-ctx.Done():
		grpcServer.GracefulStop()
		return nil
	case err := <-serverErr:
		return fmt.Errorf("serve grpc: %w", err)
	}
}
