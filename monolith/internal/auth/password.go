package auth

import (
	"fmt"

	"golang.org/x/crypto/bcrypt"
)

type BcryptHasher struct{}

func (BcryptHasher) Hash(password string) (string, error) {
	hashed, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", fmt.Errorf("hashing password: %w", err)
	}
	return string(hashed), nil
}

func (BcryptHasher) Compare(hash, password string) error {
	if err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)); err != nil {
		return fmt.Errorf("comparing password: %w", err)
	}
	return nil
}
