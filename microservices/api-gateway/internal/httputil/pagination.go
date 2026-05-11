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
	lim, e := parseInt32Param(c.QueryParam("limit"), defaultLimit)
	if e != nil || lim < 1 || lim > maxLimit {
		return 0, 0, &AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: "limit must be between 1 and 100"}
	}

	off, e := parseInt32Param(c.QueryParam("offset"), defaultOffset)
	if e != nil || off < 0 {
		return 0, 0, &AppError{Status: http.StatusBadRequest, Code: "BAD_REQUEST", Message: "offset must be >= 0"}
	}

	return lim, off, nil
}

func parseInt32Param(v string, def int32) (int32, error) {
	if v == "" {
		return def, nil
	}
	n, err := strconv.ParseInt(v, 10, 32)
	if err != nil {
		return 0, err
	}
	return int32(n), nil //nolint:gosec // safe: ParseInt with bitSize=32 guarantees int32 range
}
