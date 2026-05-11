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

// Auth returns an Echo middleware that validates JWT Bearer tokens.
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

// UserIDFromBearer extracts and validates the user ID from an Authorization header.
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

// UserIDFromContext retrieves the authenticated user ID from Echo context.
func UserIDFromContext(c echo.Context) (string, error) {
	userID, ok := c.Get(userIDKey).(string)
	if !ok || userID == "" {
		return "", unauthorized("missing authenticated user")
	}
	return userID, nil
}

func unauthorized(message string) *httputil.AppError {
	return &httputil.AppError{Status: http.StatusUnauthorized, Code: "UNAUTHORIZED", Message: message}
}
