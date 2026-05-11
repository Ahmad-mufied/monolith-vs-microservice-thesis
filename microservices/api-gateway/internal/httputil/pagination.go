package httputil

import (
	"net/http"
	"strconv"

	"github.com/labstack/echo/v4"
)

const (
	defaultLimit  = 50
	maxLimit      = 100
	defaultOffset = 0
)

// ParsePage parses limit and offset query params.
func ParsePage(c echo.Context) (limit, offset int32, err error) {
	lim, e := parseIntParam(c.QueryParam("limit"), defaultLimit)
	if e != nil || lim < 1 || lim > maxLimit {
		return 0, 0, &AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: "limit must be between 1 and 100"}
	}

	off, e := parseIntParam(c.QueryParam("offset"), defaultOffset)
	if e != nil || off < 0 {
		return 0, 0, &AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: "offset must be >= 0"}
	}

	return int32(lim), int32(off), nil
}

func parseIntParam(v string, def int) (int, error) {
	if v == "" {
		return def, nil
	}
	return strconv.Atoi(v)
}
