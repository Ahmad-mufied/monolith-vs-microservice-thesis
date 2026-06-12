package bootstrap

import (
	"context"
	"fmt"
	"log"
	"net"
	"os/signal"
	"syscall"
	"time"

	grpcserveradapter "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/adapter/grpcserver"
	postgresadapter "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/adapter/postgres"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/config"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/usecase"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/grpcutil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/observability"
	pkgpostgres "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/postgres"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
	grpctrace "github.com/DataDog/dd-trace-go/contrib/google.golang.org/grpc/v2"
	"google.golang.org/grpc"
)

const shutdownTimeout = 10 * time.Second

func Run() error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	serviceName := observability.ServiceName("item-service")
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

	repo := postgresadapter.NewItemRepository(pool)
	uc := usecase.NewItemUsecase(repo)
	srv := grpcserveradapter.NewItemServer(uc)

	grpcServer := grpc.NewServer(grpcServerOptions(serviceName, cfg.GRPCRequestTimeout)...)
	itemv1.RegisterItemServiceServer(grpcServer, srv)

	listener, err := net.Listen("tcp", ":"+cfg.GRPCPort)
	if err != nil {
		return fmt.Errorf("listen grpc port: %w", err)
	}

	serverErr := make(chan error, 1)
	go func() {
		serverErr <- grpcServer.Serve(listener)
	}()

	log.Printf("item-service gRPC listening on :%s (grpc_request_timeout=%s)", cfg.GRPCPort, cfg.GRPCRequestTimeout)

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
			log.Printf("item-service graceful shutdown timed out after %s; forcing stop", shutdownTimeout)
			grpcServer.Stop()
		}

		return nil
	case err := <-serverErr:
		return fmt.Errorf("serve grpc: %w", err)
	}
}

func grpcServerOptions(serviceName string, requestTimeout time.Duration) []grpc.ServerOption {
	return []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(
			grpcutil.UnaryServerTimeout(requestTimeout),
			grpctrace.UnaryServerInterceptor(grpctrace.WithService(serviceName)),
		),
		grpc.ChainStreamInterceptor(grpctrace.StreamServerInterceptor(grpctrace.WithService(serviceName))),
	}
}
