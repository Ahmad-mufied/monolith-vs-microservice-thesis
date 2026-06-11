package bootstrap

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os/signal"
	"syscall"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/client"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/config"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/handler"
	mware "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/middleware"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/router"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/observability"
	authv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/auth/v1"
	itemv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/item/v1"
	transactionv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/transaction/v1"
	grpctrace "github.com/DataDog/dd-trace-go/contrib/google.golang.org/grpc/v2"
	echotrace "github.com/DataDog/dd-trace-go/contrib/labstack/echo.v4/v2"
	"github.com/labstack/echo/v4"
	echomw "github.com/labstack/echo/v4/middleware"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

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

	// Instantiate clients with the configured gRPC call timeout. Each client
	// will wrap every outbound context with this deadline before the RPC call.
	authClient := client.NewAuthClient(authv1.NewAuthServiceClient(authConn), cfg.GRPCCallTimeout)
	itemClient := client.NewItemClient(itemv1.NewItemServiceClient(itemConn), cfg.GRPCCallTimeout)
	txClient := client.NewTransactionClient(transactionv1.NewTransactionServiceClient(txConn), cfg.GRPCCallTimeout)

	// Instantiate handlers.
	healthH := handler.NewHealthHandler()
	authH := handler.NewAuthHandler(authClient)
	itemH := handler.NewItemHandler(itemClient)
	txH := handler.NewTransactionHandler(txClient, authClient, itemClient)

	// Setup router.
	e := echotrace.Wrap(echo.New(), echotrace.WithService(serviceName))
	// Use Echo's built-in context-timeout middleware so handlers receive a
	// deadline-aware request context. The custom error handler preserves the
	// public timeout contract: deadline reached -> 503, caller canceled -> 499.
	// This ensures multi-call handlers (e.g. GetAllEnriched) have an overall
	// deadline and do not exceed the HTTP WriteTimeout.
	e.Use(echomw.ContextTimeoutWithConfig(echomw.ContextTimeoutConfig{
		Timeout:      cfg.RequestTimeout,
		ErrorHandler: mware.ContextTimeoutErrorHandler,
	}))
	router.RegisterRoutes(e, healthH, authH, itemH, txH, cfg.JWTSecret)

	// Start HTTP server with explicit transport timeouts from config.
	// WriteTimeout is intentionally larger than GRPCCallTimeout so the gateway
	// can write a proper 503/499 response before the transport closes the
	// connection.
	addr := ":" + cfg.HTTPPort
	server := &http.Server{
		Addr:              addr,
		Handler:           e,
		ReadHeaderTimeout: cfg.HTTPServer.ReadHeaderTimeout,
		ReadTimeout:       cfg.HTTPServer.ReadTimeout,
		WriteTimeout:      cfg.HTTPServer.WriteTimeout,
		IdleTimeout:       cfg.HTTPServer.IdleTimeout,
	}

	serverErr := make(chan error, 1)
	go func() {
		log.Printf("api-gateway HTTP listening on %s (request_timeout=%s grpc_call_timeout=%s)", addr, cfg.RequestTimeout, cfg.GRPCCallTimeout)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErr <- err
		}
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.HTTPServer.ShutdownTimeout)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
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
