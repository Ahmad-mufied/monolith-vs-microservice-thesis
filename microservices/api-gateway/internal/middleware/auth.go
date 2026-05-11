package middleware

import (
	"fmt"
	"net/http"
	"strings"

	pkgjwt "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/jwt"
	"github.com/labstack/echo/v4"
)

const userIDKey = "user_id"

// UserIDContextKey is the exported key used to store user_id in Echo context.
const UserIDContextKey = userIDKey

// authError is a simple HTTP error used by this middleware.
type authError struct {
	status  int
	message string
}

func (e *authError) Error() string { return e.message }

// Auth returns an Echo middleware that validates JWT Bearer tokens.
func Auth(secret string) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			userID, err := UserIDFromBearer(c.Request().Header.Get("Authorization"), secret)
			if err != nil {
				return writeAuthError(c, err)
			}
			c.Set(userIDKey, userID)
			return next(c)
		}
	}
}

// UserIDFromBearer extracts and validates the user ID from an Authorization header.
func UserIDFromBearer(header, secret string) (string, error) {
	if header == "" {
		return "", &authError{status: http.StatusUnauthorized, message: "missing authorization header"}
	}

	parts := strings.Fields(header)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return "", &authError{status: http.StatusUnauthorized, message: "invalid authorization header"}
	}

	claims, err := pkgjwt.Verify(parts[1], secret)
	if err != nil {
		return "", &authError{status: http.StatusUnauthorized, message: "invalid token"}
	}

	if claims.Subject == "" {
		return "", &authError{status: http.StatusUnauthorized, message: "invalid token subject"}
	}

	return claims.Subject, nil
}

// UserIDFromContext retrieves the authenticated user ID from Echo context.
func UserIDFromContext(c echo.Context) (string, error) {
	userID, ok := c.Get(userIDKey).(string)
	if !ok || userID == "" {
		return "", &authError{status: http.StatusUnauthorized, message: "missing authenticated user"}
	}
	return userID, nil
}

func writeAuthError(c echo.Context, err error) error {
	ae, ok := err.(*authError)
	if !ok {
		ae = &authError{status: http.StatusUnauthorized, message: fmt.Sprintf("%v", err)}
	}
	return c.JSON(ae.status, map[string]any{
		"error": map[string]any{
			"code":    "UNAUTHORIZED",
			"message": ae.message,
			"details": nil,
		},
	})
}
