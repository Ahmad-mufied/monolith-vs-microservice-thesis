package numconv

import (
	"fmt"
	"math"
)

type signedInteger interface {
	~int | ~int32 | ~int64
}

func IntToInt32[T signedInteger](value T, field string) (int32, error) {
	if value < T(math.MinInt32) || value > T(math.MaxInt32) {
		return 0, fmt.Errorf("%s exceeds supported int32 range: %d", field, value)
	}

	return int32(value), nil
}
