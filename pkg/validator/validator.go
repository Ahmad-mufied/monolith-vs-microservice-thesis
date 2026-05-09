package validator

import (
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	"github.com/google/uuid"
)

func IsValidUUID(s string) bool {
	_, err := uuid.Parse(s)
	return err == nil
}

func ValidateUUID(s string) error {
	if !IsValidUUID(s) {
		return pkgerrors.InvalidInput("invalid UUID")
	}
	return nil
}

func ValidateUUIDField(s, field string) error {
	if !IsValidUUID(s) {
		return pkgerrors.InvalidInputDetails("invalid request payload", map[string]string{
			field: "must be a valid UUID",
		})
	}
	return nil
}
