package middleware

import (
	"strings"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/httputil"
	"github.com/google/uuid"
	"github.com/labstack/echo/v4"
)

const UserIDKey = "user_id"

type TokenVerifier interface {
	Verify(tokenString string) (string, error)
}

func Auth(verifier TokenVerifier) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			userID, err := UserIDFromBearer(c.Request().Header.Get("Authorization"), verifier)
			if err != nil {
				return httputil.Error(c, err)
			}
			c.Set(UserIDKey, userID)
			return next(c)
		}
	}
}

func UserID(c echo.Context) (string, error) {
	userID, ok := c.Get(UserIDKey).(string)
	if !ok || userID == "" {
		return "", apperror.Unauthorized("missing authenticated user")
	}
	return userID, nil
}

func UserIDFromBearer(header string, verifier TokenVerifier) (string, error) {
	if verifier == nil {
		return "", apperror.Internal("authentication verifier is not configured", nil)
	}
	if header == "" {
		return "", apperror.Unauthorized("missing authorization header")
	}

	parts := strings.Fields(header)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return "", apperror.Unauthorized("invalid authorization header")
	}

	userID, err := verifier.Verify(parts[1])
	if err != nil {
		return "", apperror.Unauthorized("invalid token")
	}
	if _, err := uuid.Parse(userID); err != nil {
		return "", apperror.Unauthorized("invalid token subject")
	}

	return userID, nil
}
