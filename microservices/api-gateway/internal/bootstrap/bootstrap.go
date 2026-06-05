package bootstrap

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/client"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/config"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/handler"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/router"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/observability"
	authv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/auth/v1"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
	transactionv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/transaction/v1"
	grpctrace "github.com/DataDog/dd-trace-go/contrib/google.golang.org/grpc/v2"
	echotrace "github.com/DataDog/dd-trace-go/contrib/labstack/echo.v4/v2"
	"github.com/labstack/echo/v4"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const shutdownTimeout = 10 * time.Second
const grpcRoundRobinServiceConfig = `{"loadBalancingConfig":[{"round_robin":{}}]}`

func Run() error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	serviceName := observability.ServiceName("api-gateway")
	stopObservability, err := observability.Start(serviceName)
	if err != nil {
		return fmt.Errorf("start observability: %w", err)
	}
	defer stopObservability()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Dial gRPC connections.
	authConn, err := grpc.NewClient(cfg.AuthServiceAddr, grpcClientOptions(serviceName)...)
	if err != nil {
		return fmt.Errorf("dial auth service: %w", err)
	}
	defer closeConn(authConn, "auth")

	itemConn, err := grpc.NewClient(cfg.ItemServiceAddr, grpcClientOptions(serviceName)...)
	if err != nil {
		return fmt.Errorf("dial item service: %w", err)
	}
	defer closeConn(itemConn, "item")

	txConn, err := grpc.NewClient(cfg.TransactionServiceAddr, grpcClientOptions(serviceName)...)
	if err != nil {
		return fmt.Errorf("dial transaction service: %w", err)
	}
	defer closeConn(txConn, "transaction")

	// Instantiate clients.
	authClient := client.NewAuthClient(authv1.NewAuthServiceClient(authConn))
	itemClient := client.NewItemClient(itemv1.NewItemServiceClient(itemConn))
	txClient := client.NewTransactionClient(transactionv1.NewTransactionServiceClient(txConn))

	// Instantiate handlers.
	healthH := handler.NewHealthHandler()
	authH := handler.NewAuthHandler(authClient)
	itemH := handler.NewItemHandler(itemClient)
	txH := handler.NewTransactionHandler(txClient, authClient, itemClient)

	// Setup router.
	e := echotrace.Wrap(echo.New(), echotrace.WithService(serviceName))
	defer closeEcho(e)
	router.RegisterRoutes(e, healthH, authH, itemH, txH, cfg.JWTSecret)

	// Start HTTP server.
	serverErr := make(chan error, 1)
	go func() {
		log.Printf("api-gateway HTTP listening on :%s", cfg.HTTPPort)
		serverErr <- e.Start(":" + cfg.HTTPPort)
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		if err := e.Shutdown(shutdownCtx); err != nil {
			log.Printf("api-gateway graceful shutdown error: %v", err)
		}
		return nil
	case err := <-serverErr:
		return fmt.Errorf("serve http: %w", err)
	}
}

func grpcClientOptions(serviceName string) []grpc.DialOption {
	return []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultServiceConfig(grpcRoundRobinServiceConfig),
		grpc.WithChainUnaryInterceptor(grpctrace.UnaryClientInterceptor(grpctrace.WithService(serviceName))),
		grpc.WithChainStreamInterceptor(grpctrace.StreamClientInterceptor(grpctrace.WithService(serviceName))),
	}
}

func closeConn(conn *grpc.ClientConn, name string) {
	if err := conn.Close(); err != nil {
		log.Printf("close %s service conn: %v", name, err)
	}
}

func closeEcho(e *echo.Echo) {
	if err := e.Close(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Printf("close api-gateway echo server: %v", err)
	}
}
