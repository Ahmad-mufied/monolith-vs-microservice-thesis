package jwtutil

import (
	"fmt"
	"time"

	"github.com/golang-jwt/jwt"
)

type Manager struct {
	secret []byte
	ttl    time.Duration
}

type Claims struct {
	jwt.StandardClaims
}

func NewManager(secret string, ttl time.Duration) *Manager {
	return &Manager{secret: []byte(secret), ttl: ttl}
}

func (m *Manager) Sign(userID string) (string, error) {
	now := time.Now().UTC()
	claims := Claims{
		StandardClaims: jwt.StandardClaims{
			Subject:   userID,
			IssuedAt:  now.Unix(),
			ExpiresAt: now.Add(m.ttl).Unix(),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := token.SignedString(m.secret)
	if err != nil {
		return "", fmt.Errorf("signing jwt: %w", err)
	}
	return signed, nil
}

func (m *Manager) Verify(tokenString string) (string, error) {
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (any, error) {
		if token.Method != jwt.SigningMethodHS256 {
			return nil, fmt.Errorf("unexpected signing method")
		}
		return m.secret, nil
	})
	if err != nil {
		return "", fmt.Errorf("parsing jwt: %w", err)
	}
	if !token.Valid {
		return "", fmt.Errorf("invalid jwt")
	}
	if claims.Subject == "" {
		return "", fmt.Errorf("jwt subject is required")
	}
	return claims.Subject, nil
}
