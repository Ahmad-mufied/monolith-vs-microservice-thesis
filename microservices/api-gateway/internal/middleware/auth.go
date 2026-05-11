package middleware

import (
	"net/http"
	"strings"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	pkgjwt "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/jwt"
	"github.com/labstack/echo/v4"
)

const userIDKey = "user_id"

// UserIDContextKey is the exported key used to store user_id in Echo context.
const UserIDContextKey = userIDKey

// Auth returns an Echo middleware that validates JWT bearer tokens from the
// Authorization header. On successful validation it stores the token subject as
// the authenticated user ID in the Echo context under userIDKey and calls the
// next handler; on validation error it responds with the standardized
// unauthorized error via httputil.Error.
func Auth(secret string) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			userID, err := UserIDFromBearer(c.Request().Header.Get("Authorization"), secret)
			if err != nil {
				return httputil.Error(c, err)
			}
			c.Set(userIDKey, userID)
			return next(c)
		}
	}
}

// UserIDFromBearer extracts the authenticated user ID from an HTTP Authorization header containing a JWT Bearer token.
// It validates that the header is present and formatted as "Bearer <token>", verifies the token with the provided secret,
// and returns the token's subject on success. It returns an unauthorized AppError when the header is missing or malformed,
// the token is invalid, or the token subject is empty.
func UserIDFromBearer(header, secret string) (string, error) {
	if header == "" {
		return "", unauthorized("missing authorization header")
	}

	parts := strings.Fields(header)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return "", unauthorized("invalid authorization header")
	}

	claims, err := pkgjwt.Verify(parts[1], secret)
	if err != nil {
		return "", unauthorized("invalid token")
	}

	if claims.Subject == "" {
		return "", unauthorized("invalid token subject")
	}

	return claims.Subject, nil
}

// UserIDFromContext retrieves the authenticated user ID stored in the Echo context.
// It returns the user ID string, or an `httputil.AppError` (HTTP 401) when no valid authenticated user is present.
func UserIDFromContext(c echo.Context) (string, error) {
	userID, ok := c.Get(userIDKey).(string)
	if !ok || userID == "" {
		return "", unauthorized("missing authenticated user")
	}
	return userID, nil
}

// unauthorized constructs an *httputil.AppError with HTTP 401 status, code "UNAUTHORIZED", and the provided message.
func unauthorized(message string) *httputil.AppError {
	return &httputil.AppError{Status: http.StatusUnauthorized, Code: "UNAUTHORIZED", Message: message}
}
