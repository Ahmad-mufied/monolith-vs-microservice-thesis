package errors

import (
	"context"
	stderrors "errors"
	"fmt"
	"sort"

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var (
	ErrNotFound           = stderrors.New("not found")
	ErrInvalidCredentials = stderrors.New("invalid credentials")
	ErrConflict           = stderrors.New("conflict")
	ErrFailedPrecondition = stderrors.New("failed precondition")
	ErrInvalidInput       = stderrors.New("invalid input")
	ErrUnavailable        = stderrors.New("unavailable")
	ErrDeadlineExceeded   = stderrors.New("deadline exceeded")
	ErrCanceled           = stderrors.New("canceled")
	ErrInternal           = stderrors.New("internal")
)

type Error struct {
	kind    error
	message string
	cause   error
	details map[string]string
}

func (e *Error) Error() string {
	if e.message != "" {
		return e.message
	}
	return e.kind.Error()
}

func (e *Error) Unwrap() error {
	return e.cause
}

func (e *Error) Is(target error) bool {
	return target == e.kind || stderrors.Is(e.cause, target)
}

func (e *Error) PublicMessage() string {
	return e.message
}

func (e *Error) PublicDetails() map[string]string {
	if len(e.details) == 0 {
		return nil
	}

	details := make(map[string]string, len(e.details))
	for field, description := range e.details {
		details[field] = description
	}
	return details
}

func InvalidInput(message string) error {
	return &Error{kind: ErrInvalidInput, message: message}
}

func InvalidInputDetails(message string, details map[string]string) error {
	return &Error{kind: ErrInvalidInput, message: message, details: cloneDetails(details)}
}

func Conflict(message string) error {
	return &Error{kind: ErrConflict, message: message}
}

func InvalidCredentials(message string) error {
	return &Error{kind: ErrInvalidCredentials, message: message}
}

func FailedPrecondition(message string) error {
	return &Error{kind: ErrFailedPrecondition, message: message}
}

func NotFound(message string) error {
	return &Error{kind: ErrNotFound, message: message}
}

func Unavailable(message string) error {
	return &Error{kind: ErrUnavailable, message: message}
}

func DeadlineExceeded(message string) error {
	return &Error{kind: ErrDeadlineExceeded, message: message}
}

func Canceled(message string) error {
	return &Error{kind: ErrCanceled, message: message}
}

func FromContext(err error, deadlineMessage, canceledMessage string) error {
	switch {
	case stderrors.Is(err, context.DeadlineExceeded):
		return &Error{kind: ErrDeadlineExceeded, message: deadlineMessage, cause: err}
	case stderrors.Is(err, context.Canceled):
		return &Error{kind: ErrCanceled, message: canceledMessage, cause: err}
	default:
		return nil
	}
}

func ContextError(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return FromContext(err, "request timeout", "request canceled")
	}
	return nil
}

func IsContext(err error) bool {
	return stderrors.Is(err, context.DeadlineExceeded) ||
		stderrors.Is(err, context.Canceled) ||
		stderrors.Is(err, ErrDeadlineExceeded) ||
		stderrors.Is(err, ErrCanceled)
}

func DoIfActive(ctx context.Context, fn func() error) error {
	if err := ContextError(ctx); err != nil {
		return err
	}
	if err := fn(); err != nil {
		return err
	}
	return ContextError(ctx)
}

func CallIfActive[T any](ctx context.Context, fn func() (T, error)) (T, error) {
	var zero T
	if err := ContextError(ctx); err != nil {
		return zero, err
	}
	value, err := fn()
	if err != nil {
		return zero, err
	}
	if err := ContextError(ctx); err != nil {
		return zero, err
	}
	return value, nil
}

func Internal(message string, cause error) error {
	return &Error{kind: ErrInternal, message: message, cause: cause}
}

func InternalFromContext(action string, err error) error {
	if ctxErr := FromContext(err, "request timeout", "request canceled"); ctxErr != nil {
		return ctxErr
	}
	return Internal("internal server error", fmt.Errorf("%s: %w", action, err))
}

func ToGRPCStatus(err error) error {
	if err == nil {
		return nil
	}

	message := publicMessage(err)

	code := codes.Internal
	switch {
	case stderrors.Is(err, ErrNotFound):
		code = codes.NotFound
	case stderrors.Is(err, ErrInvalidCredentials):
		code = codes.Unauthenticated
	case stderrors.Is(err, ErrConflict):
		code = codes.AlreadyExists
	case stderrors.Is(err, ErrFailedPrecondition):
		code = codes.FailedPrecondition
	case stderrors.Is(err, ErrInvalidInput):
		code = codes.InvalidArgument
	case stderrors.Is(err, ErrUnavailable):
		code = codes.Unavailable
	case stderrors.Is(err, ErrDeadlineExceeded):
		code = codes.DeadlineExceeded
	case stderrors.Is(err, ErrCanceled):
		code = codes.Canceled
	}

	st := status.New(code, message)

	if code == codes.InvalidArgument {
		if badRequest := badRequestDetails(err); badRequest != nil {
			withDetails, withDetailsErr := st.WithDetails(badRequest)
			if withDetailsErr == nil {
				return withDetails.Err()
			}
		}
	}

	return st.Err()
}

func publicMessage(err error) string {
	var publicErr interface{ PublicMessage() string }
	if stderrors.As(err, &publicErr) && publicErr.PublicMessage() != "" {
		return publicErr.PublicMessage()
	}

	switch {
	case stderrors.Is(err, ErrInvalidInput):
		return "invalid request payload"
	case stderrors.Is(err, ErrConflict):
		return "conflict"
	case stderrors.Is(err, ErrFailedPrecondition):
		return "failed precondition"
	case stderrors.Is(err, ErrInvalidCredentials):
		return "invalid credentials"
	case stderrors.Is(err, ErrNotFound):
		return "not found"
	case stderrors.Is(err, ErrUnavailable):
		return "service unavailable"
	case stderrors.Is(err, ErrDeadlineExceeded):
		return "request timeout"
	case stderrors.Is(err, ErrCanceled):
		return "request canceled"
	default:
		return "internal server error"
	}
}

func badRequestDetails(err error) *errdetails.BadRequest {
	var detailedErr interface{ PublicDetails() map[string]string }
	if !stderrors.As(err, &detailedErr) {
		return nil
	}

	details := detailedErr.PublicDetails()
	if len(details) == 0 {
		return nil
	}

	fields := make([]string, 0, len(details))
	for field := range details {
		fields = append(fields, field)
	}
	sort.Strings(fields)

	violations := make([]*errdetails.BadRequest_FieldViolation, 0, len(fields))
	for _, field := range fields {
		violations = append(violations, &errdetails.BadRequest_FieldViolation{
			Field:       field,
			Description: details[field],
		})
	}

	return &errdetails.BadRequest{FieldViolations: violations}
}

func cloneDetails(details map[string]string) map[string]string {
	if len(details) == 0 {
		return nil
	}

	cloned := make(map[string]string, len(details))
	for field, description := range details {
		cloned[field] = description
	}
	return cloned
}
