package errors

import (
	"context"
	stderrors "errors"
	"testing"

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestToGRPCStatusNil(t *testing.T) {
	if got := ToGRPCStatus(nil); got != nil {
		t.Fatalf("expected nil, got %v", got)
	}
}

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
			name:     "failed precondition",
			err:      FailedPrecondition("requested amount exceeds available amount"),
			wantCode: codes.FailedPrecondition,
			wantMsg:  "requested amount exceeds available amount",
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
			name:     "unavailable",
			err:      Unavailable("item service unavailable"),
			wantCode: codes.Unavailable,
			wantMsg:  "item service unavailable",
		},
		{
			name:     "deadline exceeded",
			err:      DeadlineExceeded("item service request timed out"),
			wantCode: codes.DeadlineExceeded,
			wantMsg:  "item service request timed out",
		},
		{
			name:     "canceled",
			err:      Canceled("request canceled"),
			wantCode: codes.Canceled,
			wantMsg:  "request canceled",
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
	if !stderrors.Is(FailedPrecondition("requested amount exceeds available amount"), ErrFailedPrecondition) {
		t.Fatal("expected FailedPrecondition to match ErrFailedPrecondition")
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
	if !stderrors.Is(Unavailable("item service unavailable"), ErrUnavailable) {
		t.Fatal("expected Unavailable to match ErrUnavailable")
	}
	if !stderrors.Is(DeadlineExceeded("item service request timed out"), ErrDeadlineExceeded) {
		t.Fatal("expected DeadlineExceeded to match ErrDeadlineExceeded")
	}
	if !stderrors.Is(Canceled("request canceled"), ErrCanceled) {
		t.Fatal("expected Canceled to match ErrCanceled")
	}
}

func TestFromContext(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want error
	}{
		{name: "deadline exceeded", err: context.DeadlineExceeded, want: ErrDeadlineExceeded},
		{name: "canceled", err: context.Canceled, want: ErrCanceled},
		{name: "other", err: stderrors.New("driver error"), want: nil},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := FromContext(tt.err, "request timeout", "request canceled")
			if tt.want == nil {
				if got != nil {
					t.Fatalf("FromContext() = %v, want nil", got)
				}
				return
			}
			if !stderrors.Is(got, tt.want) {
				t.Fatalf("FromContext() = %v, want %v", got, tt.want)
			}
			if !stderrors.Is(got, tt.err) {
				t.Fatalf("FromContext() should preserve cause %v, got %v", tt.err, got)
			}
		})
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
