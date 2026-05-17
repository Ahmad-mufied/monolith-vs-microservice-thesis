package router

import (
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/handler"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/middleware"
	"github.com/labstack/echo/v4"
	echomiddleware "github.com/labstack/echo/v4/middleware"
)

// New creates and configures the Echo router with all routes.
func New(
	health *handler.HealthHandler,
	auth *handler.AuthHandler,
	item *handler.ItemHandler,
	tx *handler.TransactionHandler,
	jwtSecret string,
) *echo.Echo {
	e := echo.New()
	e.HideBanner = true
	e.HTTPErrorHandler = httputil.HTTPErrorHandler
	e.Use(echomiddleware.Recover())

	// Public routes.
	e.GET("/healthz", health.Handle)
	e.POST("/api/v1/auth/register", auth.Register)
	e.POST("/api/v1/auth/login", auth.Login)

	// Protected routes.
	protected := e.Group("/api/v1", middleware.Auth(jwtSecret))
	protected.GET("/items", item.ListItems)
	protected.PUT("/items", item.SyncItems)
	protected.GET("/items/:item_id", item.GetItemByID)
	protected.POST("/transactions", tx.CreateTransaction)
	protected.GET("/transactions", tx.GetOwnTransactions)
	protected.GET("/transactions/:transaction_id", tx.GetTransactionByID)
	protected.GET("/admin/transactions", tx.GetAllEnriched)

	return e
}
