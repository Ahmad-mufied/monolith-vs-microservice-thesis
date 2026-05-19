package numconv

import (
	"math"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestIntToInt32WithinRange(t *testing.T) {
	value, err := IntToInt32(123, "amount")

	require.NoError(t, err)
	require.Equal(t, int32(123), value)
}

func TestIntToInt32OutOfRange(t *testing.T) {
	_, err := IntToInt32(int64(math.MaxInt32)+1, "amount")

	require.EqualError(t, err, "amount exceeds supported int32 range: 2147483648")
}
