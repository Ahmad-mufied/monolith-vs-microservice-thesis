package router

import (
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/handler"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/middleware"
	"github.com/labstack/echo/v4"
)

// New creates and configures an Echo router and registers public and protected API routes.
// 
// Public routes registered:
//   - GET  /healthz                   -> health.Handle
//   - POST /api/v1/auth/register      -> auth.Register
//   - POST /api/v1/auth/login         -> auth.Login
//
// Protected routes are mounted under /api/v1 and secured with middleware.Auth(jwtSecret):
//   - GET  /items                      -> item.ListItems
//   - PUT  /items                      -> item.SyncItems
//   - GET  /items/:item_id             -> item.GetItemByID
//   - POST /transactions               -> tx.CreateTransaction
//   - GET  /transactions               -> tx.GetOwnTransactions
//   - GET  /transactions/:transaction_id -> tx.GetTransactionByID
//   - GET  /admin/transactions         -> tx.GetAllEnriched
//
// It returns the configured *echo.Echo router.
func New(
	health *handler.HealthHandler,
	auth *handler.AuthHandler,
	item *handler.ItemHandler,
	tx *handler.TransactionHandler,
	jwtSecret string,
) *echo.Echo {
	e := echo.New()
	e.HideBanner = true

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
