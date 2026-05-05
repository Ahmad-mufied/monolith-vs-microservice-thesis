package auth

import (
	"errors"
	"fmt"

	"golang.org/x/crypto/bcrypt"
)

var ErrPasswordMismatch = errors.New("password mismatch")

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
		if errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
			return ErrPasswordMismatch
		}
		return fmt.Errorf("comparing password: %w", err)
	}
	return nil
}
