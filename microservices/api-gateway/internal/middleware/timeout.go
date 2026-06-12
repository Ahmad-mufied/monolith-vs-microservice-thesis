package middleware

import (
	"context"
	"errors"
	"net/http"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/labstack/echo/v4"
)

// ContextTimeoutErrorHandler adapts Echo's built-in ContextTimeout middleware
// to the API Gateway's public error contract. Deadline-exceeded request contexts
// become 503 service-unavailable errors, while caller disconnects remain 499.
func ContextTimeoutErrorHandler(err error, c echo.Context) error {
	if ctxErr := fromContextError(err); ctxErr != nil {
		return ctxErr
	}
	if ctxErr := contextError(c.Request().Context()); ctxErr != nil {
		return ctxErr
	}
	return err
}

// fromContextError maps context.DeadlineExceeded and context.Canceled errors
// to AppError with appropriate HTTP status codes.
func fromContextError(err error) *httputil.AppError {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return &httputil.AppError{
			Status:  http.StatusServiceUnavailable,
			Code:    "SERVICE_UNAVAILABLE",
			Message: "service temporarily unavailable",
		}
	case errors.Is(err, context.Canceled):
		return &httputil.AppError{
			Status:  499,
			Code:    "CLIENT_CANCELED",
			Message: "request canceled",
		}
	default:
		return nil
	}
}

// contextError checks the context for cancellation or deadline and returns
// an AppError if applicable.
func contextError(ctx context.Context) *httputil.AppError {
	if err := ctx.Err(); err != nil {
		return fromContextError(err)
	}
	return nil
}
