package jwtutil

import (
	"testing"
	"time"
)

func TestManagerSignVerify(t *testing.T) {
	tests := []struct {
		name      string
		ttl       time.Duration
		token     string
		wantError bool
	}{
		{name: "valid signed token", ttl: time.Hour},
		{name: "expired signed token", ttl: -time.Hour, wantError: true},
		{name: "malformed token", ttl: time.Hour, token: "not-a-token", wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			manager := NewManager("secret", tt.ttl)
			token := tt.token
			if token == "" {
				var err error
				token, err = manager.Sign("018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001")
				if err != nil {
					t.Fatalf("Sign() error: %v", err)
				}
			}

			got, err := manager.Verify(token)
			if tt.wantError {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("Verify() error: %v", err)
			}
			if got != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f0001" {
				t.Fatalf("subject = %q", got)
			}
		})
	}
}
