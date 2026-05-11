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
	pkgpostgres "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/postgres"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
	transactionv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/transaction/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const shutdownTimeout = 10 * time.Second

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

	itemConn, err := grpc.NewClient(
		cfg.ItemServiceAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return fmt.Errorf("dial item service: %w", err)
	}
	defer itemConn.Close()

	repo := postgresadapter.NewTransactionRepository(pool)
	itemClient := grpcclientadapter.NewItemClient(itemv1.NewItemServiceClient(itemConn))
	uc := usecase.NewTransactionUsecase(repo, itemClient)
	srv := grpcserveradapter.NewTransactionServer(uc)

	grpcServer := grpc.NewServer()
	transactionv1.RegisterTransactionServiceServer(grpcServer, srv)

	listener, err := net.Listen("tcp", ":"+cfg.GRPCPort)
	if err != nil {
		return fmt.Errorf("listen grpc port: %w", err)
	}

	serverErr := make(chan error, 1)
	go func() {
		serverErr <- grpcServer.Serve(listener)
	}()

	log.Printf("transaction-service gRPC listening on :%s", cfg.GRPCPort)

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
			log.Printf("transaction-service graceful shutdown timed out after %s; forcing stop", shutdownTimeout)
			grpcServer.Stop()
		}

		return nil
	case err := <-serverErr:
		return fmt.Errorf("serve grpc: %w", err)
	}
}
