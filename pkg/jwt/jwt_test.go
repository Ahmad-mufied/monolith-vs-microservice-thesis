package jwt

import (
	"testing"
	"time"
)

func TestSignAndVerifyUsesSubjectForUserID(t *testing.T) {
	token, err := Sign("01968ad4-98b1-79c8-a6f0-ec21f8f434c6", "ahmad@example.com", "secret", time.Hour)
	if err != nil {
		t.Fatalf("Sign() error = %v", err)
	}

	claims, err := Verify(token, "secret")
	if err != nil {
		t.Fatalf("Verify() error = %v", err)
	}

	if claims.Subject != "01968ad4-98b1-79c8-a6f0-ec21f8f434c6" {
		t.Fatalf("subject = %q, want user id", claims.Subject)
	}
	if claims.Email != "ahmad@example.com" {
		t.Fatalf("email = %q, want ahmad@example.com", claims.Email)
	}
}
