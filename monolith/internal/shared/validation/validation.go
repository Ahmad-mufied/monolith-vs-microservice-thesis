package validation

import (
	"errors"
	"fmt"
	"reflect"
	"strings"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/go-playground/validator/v10"
	"github.com/google/uuid"
)

var sharedValidator = newValidator()

func Struct(value any) error {
	if err := sharedValidator.Struct(value); err != nil {
		if validationErrs, ok := errors.AsType[validator.ValidationErrors](err); ok {
			field, message := firstViolation(validationErrs)
			return apperror.BadRequest("invalid request payload", map[string]any{field: message})
		}
		return apperror.BadRequest("invalid request payload", nil)
	}
	return nil
}

func ValidateUUIDField(value, field string) error {
	if _, err := uuid.Parse(value); err != nil {
		return apperror.BadRequest("invalid request payload", map[string]any{field: "must be a valid UUID"})
	}
	return nil
}

func newValidator() *validator.Validate {
	v := validator.New()
	v.RegisterTagNameFunc(func(field reflect.StructField) string {
		jsonTag := field.Tag.Get("json")
		if jsonTag == "" {
			return field.Name
		}
		name := strings.Split(jsonTag, ",")[0]
		if name == "" || name == "-" {
			return field.Name
		}
		return name
	})
	_ = v.RegisterValidation("uuid", func(level validator.FieldLevel) bool {
		value := level.Field().String()
		if value == "" {
			return false
		}
		_, err := uuid.Parse(value)
		return err == nil
	})
	return v
}

func firstViolation(validationErrs validator.ValidationErrors) (string, string) {
	if len(validationErrs) == 0 {
		return "body", "is invalid"
	}
	violation := validationErrs[0]
	field := violation.Field()
	if field == "" {
		field = violation.StructField()
	}
	return field, messageForViolation(violation)
}

func messageForViolation(violation validator.FieldError) string {
	switch violation.Tag() {
	case "required":
		if isSliceLike(violation.Kind()) {
			return "must contain at least one item"
		}
		return "is required"
	case "max":
		if isSliceLike(violation.Kind()) {
			return fmt.Sprintf("must contain at most %s items", violation.Param())
		}
		return fmt.Sprintf("must be at most %s characters", violation.Param())
	case "min":
		if isSliceLike(violation.Kind()) {
			return fmt.Sprintf("must contain at least %s items", violation.Param())
		}
		return fmt.Sprintf("must be at least %s characters", violation.Param())
	case "gte":
		return fmt.Sprintf("must be greater than or equal to %s", violation.Param())
	case "gt":
		return fmt.Sprintf("must be greater than %s", violation.Param())
	case "uuid":
		return "must be a valid UUID"
	default:
		return "is invalid"
	}
}

func isSliceLike(kind reflect.Kind) bool {
	return kind == reflect.Array || kind == reflect.Slice
}
