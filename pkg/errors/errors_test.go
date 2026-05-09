package errors

import (
	stderrors "errors"
	"testing"

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestToGRPCStatus(t *testing.T) {
	tests := []struct {
		name        string
		err         error
		wantCode    codes.Code
		wantMsg     string
		wantDetails map[string]string
	}{
		{
			name:        "invalid input",
			err:         InvalidInputDetails("invalid request payload", map[string]string{"email": "must be a valid email"}),
			wantCode:    codes.InvalidArgument,
			wantMsg:     "invalid request payload",
			wantDetails: map[string]string{"email": "must be a valid email"},
		},
		{
			name:     "conflict",
			err:      Conflict("email already exists"),
			wantCode: codes.AlreadyExists,
			wantMsg:  "email already exists",
		},
		{
			name:     "invalid credentials",
			err:      InvalidCredentials("invalid email or password"),
			wantCode: codes.Unauthenticated,
			wantMsg:  "invalid email or password",
		},
		{
			name:     "not found",
			err:      NotFound("user not found"),
			wantCode: codes.NotFound,
			wantMsg:  "user not found",
		},
		{
			name:     "internal",
			err:      Internal("internal server error", stderrors.New("db timeout")),
			wantCode: codes.Internal,
			wantMsg:  "internal server error",
		},
		{
			name:     "raw internal fallback",
			err:      stderrors.New("driver detail leaked"),
			wantCode: codes.Internal,
			wantMsg:  "internal server error",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ToGRPCStatus(tt.err)
			st, ok := status.FromError(got)
			if !ok {
				t.Fatalf("expected gRPC status error, got %T", got)
			}
			if st.Code() != tt.wantCode {
				t.Fatalf("code = %s, want %s", st.Code(), tt.wantCode)
			}
			if st.Message() != tt.wantMsg {
				t.Fatalf("message = %q, want %q", st.Message(), tt.wantMsg)
			}
			assertGRPCFieldViolations(t, st, tt.wantDetails)
		})
	}
}

func TestTypedErrorsPreserveSentinelIdentity(t *testing.T) {
	if !stderrors.Is(InvalidInput("invalid request payload"), ErrInvalidInput) {
		t.Fatal("expected InvalidInput to match ErrInvalidInput")
	}
	if !stderrors.Is(Conflict("email already exists"), ErrConflict) {
		t.Fatal("expected Conflict to match ErrConflict")
	}
	if !stderrors.Is(InvalidCredentials("invalid email or password"), ErrInvalidCredentials) {
		t.Fatal("expected InvalidCredentials to match ErrInvalidCredentials")
	}
	if !stderrors.Is(NotFound("user not found"), ErrNotFound) {
		t.Fatal("expected NotFound to match ErrNotFound")
	}
	if !stderrors.Is(Internal("internal server error", stderrors.New("cause")), ErrInternal) {
		t.Fatal("expected Internal to match ErrInternal")
	}
}

func assertGRPCFieldViolations(t *testing.T, st *status.Status, want map[string]string) {
	t.Helper()

	if len(want) == 0 {
		if len(st.Details()) != 0 {
			t.Fatalf("details = %+v, want none", st.Details())
		}
		return
	}

	if len(st.Details()) != 1 {
		t.Fatalf("details count = %d, want 1", len(st.Details()))
	}

	badRequest, ok := st.Details()[0].(*errdetails.BadRequest)
	if !ok {
		t.Fatalf("detail type = %T, want *errdetails.BadRequest", st.Details()[0])
	}

	if len(badRequest.FieldViolations) != len(want) {
		t.Fatalf("violations count = %d, want %d", len(badRequest.FieldViolations), len(want))
	}

	for _, violation := range badRequest.FieldViolations {
		wantDescription, exists := want[violation.Field]
		if !exists {
			t.Fatalf("unexpected field violation %q", violation.Field)
		}
		if violation.Description != wantDescription {
			t.Fatalf("description for %q = %q, want %q", violation.Field, violation.Description, wantDescription)
		}
	}
}
