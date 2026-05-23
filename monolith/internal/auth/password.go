package auth

import (
	"errors"
	"fmt"

	"golang.org/x/crypto/bcrypt"
)

var ErrPasswordMismatch = errors.New("password mismatch")

type BcryptHasher struct {
	Cost int
}

func (h BcryptHasher) cost() int {
	if h.Cost == 0 {
		return bcrypt.DefaultCost
	}
	return h.Cost
}

func (h BcryptHasher) Hash(password string) (string, error) {
	hashed, err := bcrypt.GenerateFromPassword([]byte(password), h.cost())
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
