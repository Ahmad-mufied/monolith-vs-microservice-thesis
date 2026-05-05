package pagination

import (
	"strconv"

	"github.com/ahmadmufied/skripsi-benchmark/monolith/internal/shared/apperror"
	"github.com/labstack/echo/v4"
)

const (
	DefaultLimit  = 50
	MaxLimit      = 100
	DefaultOffset = 0
)

type Page struct {
	Limit  int
	Offset int
}

func FromContext(c echo.Context) (Page, error) {
	limit, err := parseInt(c.QueryParam("limit"), DefaultLimit)
	if err != nil || limit < 1 || limit > MaxLimit {
		return Page{}, apperror.BadRequest("invalid limit", map[string]any{"limit": "must be between 1 and 100"})
	}

	offset, err := parseInt(c.QueryParam("offset"), DefaultOffset)
	if err != nil || offset < 0 {
		return Page{}, apperror.BadRequest("invalid offset", map[string]any{"offset": "must be greater than or equal to 0"})
	}

	return Page{Limit: limit, Offset: offset}, nil
}

func parseInt(value string, defaultValue int) (int, error) {
	if value == "" {
		return defaultValue, nil
	}
	return strconv.Atoi(value)
}
