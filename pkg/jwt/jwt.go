package jwt

import (
	"fmt"
	"time"

	jwtv5 "github.com/golang-jwt/jwt/v5"
)

type Claims struct {
	Email string `json:"email"`
	jwtv5.RegisteredClaims
}

func Sign(userID, email, secret string, expiry time.Duration) (string, error) {
	now := time.Now().UTC()
	claims := Claims{
		Email: email,
		RegisteredClaims: jwtv5.RegisteredClaims{
			Subject:   userID,
			IssuedAt:  jwtv5.NewNumericDate(now),
			ExpiresAt: jwtv5.NewNumericDate(now.Add(expiry)),
		},
	}

	token := jwtv5.NewWithClaims(jwtv5.SigningMethodHS256, claims)
	signed, err := token.SignedString([]byte(secret))
	if err != nil {
		return "", fmt.Errorf("sign token: %w", err)
	}
	return signed, nil
}

func Verify(tokenString, secret string) (*Claims, error) {
	token, err := jwtv5.ParseWithClaims(tokenString, &Claims{}, func(token *jwtv5.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwtv5.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return []byte(secret), nil
	})
	if err != nil {
		return nil, fmt.Errorf("parse token: %w", err)
	}

	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, fmt.Errorf("invalid token")
	}
	if claims.Subject == "" {
		return nil, fmt.Errorf("token subject is required")
	}

	return claims, nil
}
