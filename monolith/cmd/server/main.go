package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/auth"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/health"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/item"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/config"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/db"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/httputil"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/jwtutil"
	authmw "github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/middleware"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/transaction"
	"github.com/labstack/echo/v4"
	echomw "github.com/labstack/echo/v4/middleware"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := config.Load()
	if err != nil {
		logger.Error("load config", slog.String("error", err.Error()))
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	connectCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	pool, err := db.Connect(connectCtx, cfg.DatabaseURL, cfg.DBPool)
	if err != nil {
		logger.Error("connect database", slog.String("error", err.Error()))
		os.Exit(1)
	}
	defer pool.Close()

	e := echo.New()
	e.HideBanner = true
	e.HidePort = true
	e.Use(echomw.Recover())
	e.HTTPErrorHandler = func(err error, c echo.Context) {
		if c.Response().Committed {
			return
		}
		if httpErr, ok := errors.AsType[*echo.HTTPError](err); ok {
			if httpErr.Code == http.StatusNotFound {
				_ = httputil.Error(c, apperror.NotFound("resource not found"))
				return
			}
			_ = httputil.Error(c, apperror.FromHTTPStatus(httpErr.Code, httpErrorMessage(httpErr)))
			return
		}
		_ = httputil.Error(c, apperror.Internal("internal server error", err))
	}

	jwtManager := jwtutil.NewManager(cfg.JWTSecret, cfg.JWTTokenTTL)

	authRepo := auth.NewPostgresRepository(pool)
	authService := auth.NewService(authRepo, auth.BcryptHasher{}, jwtManager)
	auth.NewHandler(authService).RegisterRoutes(e)

	health.NewHandler(cfg.ServiceName).Register(e)

	itemRepo := item.NewPostgresRepository(pool)
	itemService := item.NewService(itemRepo)

	transactionRepo := transaction.NewPostgresRepository(pool)
	transactionService := transaction.NewService(transactionRepo)

	api := e.Group("/api/v1", authmw.Auth(jwtManager))
	item.NewHandler(itemService).RegisterRoutes(api)
	transaction.NewHandler(transactionService).RegisterRoutes(api)

	addr := ":" + cfg.AppPort
	server := &http.Server{
		Addr:              addr,
		Handler:           e,
		ReadHeaderTimeout: cfg.HTTPServer.ReadHeaderTimeout,
		ReadTimeout:       cfg.HTTPServer.ReadTimeout,
		WriteTimeout:      cfg.HTTPServer.WriteTimeout,
		IdleTimeout:       cfg.HTTPServer.IdleTimeout,
		MaxHeaderBytes:    cfg.HTTPServer.MaxHeaderBytes,
	}

	serverErrCh := make(chan error, 1)
	go func() {
		logger.Info("starting monolith", slog.String("addr", addr), slog.String("env", cfg.AppEnv))
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErrCh <- err
		}
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), cfg.HTTPServer.ShutdownTimeout)
		defer shutdownCancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			logger.Error("shutdown http server", slog.String("error", err.Error()))
		}
	case err := <-serverErrCh:
		logger.Error("http server error", slog.String("error", err.Error()))
		os.Exit(1)
	}
}

func httpErrorMessage(err *echo.HTTPError) string {
	if message, ok := err.Message.(string); ok {
		return message
	}
	return http.StatusText(err.Code)
}
