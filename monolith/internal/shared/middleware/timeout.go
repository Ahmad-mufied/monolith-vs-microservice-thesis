package middleware

import (
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/labstack/echo/v4"
)

// ContextTimeoutErrorHandler adapts Echo's built-in ContextTimeout middleware
// to the repository's public error contract. Deadline-exceeded request contexts
// become 503 service-unavailable errors, while caller disconnects remain 499.
func ContextTimeoutErrorHandler(err error, c echo.Context) error {
	if ctxErr := apperror.FromContext(err, "service temporarily unavailable", "request canceled"); ctxErr != nil {
		return ctxErr
	}
	if ctxErr := apperror.ContextError(c.Request().Context()); ctxErr != nil {
		return ctxErr
	}
	return err
}
