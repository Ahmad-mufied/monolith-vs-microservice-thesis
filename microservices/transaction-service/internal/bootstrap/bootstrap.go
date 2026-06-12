package bootstrap

import (
	"context"
	"fmt"
	"log"
	"net"
	"os/signal"
	"syscall"
	"time"

	grpcclientadapter "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/adapter/grpcclient"
	grpcserveradapter "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/adapter/grpcserver"
	postgresadapter "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/adapter/postgres"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/config"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/usecase"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/grpcutil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/observability"
	pkgpostgres "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/postgres"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
	transactionv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/transaction/v1"
	grpctrace "github.com/DataDog/dd-trace-go/contrib/google.golang.org/grpc/v2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const grpcRoundRobinServiceConfig = `{"loadBalancingConfig":[{"round_robin":{}}]}`

// grpcShutdownTimeout is the maximum wait for graceful gRPC server stop.
// Intentionally not configurable — gRPC shutdown is independent of application
// request timeouts and kept simple.
const grpcShutdownTimeout = 10 * time.Second

func Run() error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	serviceName := observability.ServiceName("transaction-service")
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

	itemConn, err := grpc.NewClient(
		cfg.ItemServiceAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultServiceConfig(grpcRoundRobinServiceConfig),
		grpc.WithChainUnaryInterceptor(grpctrace.UnaryClientInterceptor(grpctrace.WithService(serviceName))),
		grpc.WithChainStreamInterceptor(grpctrace.StreamClientInterceptor(grpctrace.WithService(serviceName))),
	)
	if err != nil {
		return fmt.Errorf("dial item service: %w", err)
	}
	defer func() {
		if err := itemConn.Close(); err != nil {
			log.Printf("close item service client: %v", err)
		}
	}()

	repo := postgresadapter.NewTransactionRepository(pool)
	itemClient := grpcclientadapter.NewItemClient(itemv1.NewItemServiceClient(itemConn))
	uc := usecase.NewTransactionUsecase(repo, itemClient, cfg.ItemValidationTimeout)
	srv := grpcserveradapter.NewTransactionServer(uc)

	grpcServer := grpc.NewServer(grpcServerOptions(serviceName, cfg.GRPCRequestTimeout)...)
	transactionv1.RegisterTransactionServiceServer(grpcServer, srv)

	listener, err := net.Listen("tcp", ":"+cfg.GRPCPort)
	if err != nil {
		return fmt.Errorf("listen grpc port: %w", err)
	}

	serverErr := make(chan error, 1)
	go func() {
		serverErr <- grpcServer.Serve(listener)
	}()

	log.Printf(
		"transaction-service gRPC listening on :%s (grpc_request_timeout=%s item_validation_timeout=%s)",
		cfg.GRPCPort,
		cfg.GRPCRequestTimeout,
		cfg.ItemValidationTimeout,
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
		case <-time.After(grpcShutdownTimeout):
			log.Printf("transaction-service graceful shutdown timed out after %s; forcing stop", grpcShutdownTimeout)
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
