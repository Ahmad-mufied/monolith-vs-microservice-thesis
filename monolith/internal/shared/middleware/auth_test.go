package middleware

import (
	"errors"
	"testing"
)

type fakeVerifier struct {
	userID string
	err    error
}

func (f fakeVerifier) Verify(string) (string, error) {
	return f.userID, f.err
}

func TestUserIDFromBearer(t *testing.T) {
	tests := []struct {
		name      string
		header    string
		verifier  TokenVerifier
		want      string
		wantError bool
	}{
		{name: "valid bearer token", header: "Bearer token", verifier: fakeVerifier{userID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001"}, want: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001"},
		{name: "missing header", wantError: true},
		{name: "invalid scheme", header: "Basic token", wantError: true},
		{name: "verifier error", header: "Bearer token", verifier: fakeVerifier{err: errors.New("bad token")}, wantError: true},
		{name: "invalid subject", header: "Bearer token", verifier: fakeVerifier{userID: "not-a-uuid"}, wantError: true},
		{name: "nil verifier", header: "Bearer token", verifier: nil, wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := UserIDFromBearer(tt.header, tt.verifier)
			if tt.wantError {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Fatalf("userID = %q, want %q", got, tt.want)
			}
		})
	}
}
