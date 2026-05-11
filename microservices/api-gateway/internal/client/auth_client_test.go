package client

import (
	"context"
	"net/http"
	"testing"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	authv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/auth/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// fakeAuthServiceClient implements authv1.AuthServiceClient for testing.
type fakeAuthServiceClient struct {
	registerFn      func(ctx context.Context, in *authv1.RegisterRequest, opts ...grpc.CallOption) (*authv1.RegisterResponse, error)
	loginFn         func(ctx context.Context, in *authv1.LoginRequest, opts ...grpc.CallOption) (*authv1.LoginResponse, error)
	getUserByIdFn   func(ctx context.Context, in *authv1.GetUserByIdRequest, opts ...grpc.CallOption) (*authv1.GetUserByIdResponse, error)
	getUsersByIdsFn func(ctx context.Context, in *authv1.GetUsersByIdsRequest, opts ...grpc.CallOption) (*authv1.GetUsersByIdsResponse, error)
}

func (f *fakeAuthServiceClient) Register(ctx context.Context, in *authv1.RegisterRequest, opts ...grpc.CallOption) (*authv1.RegisterResponse, error) {
	return f.registerFn(ctx, in, opts...)
}
func (f *fakeAuthServiceClient) Login(ctx context.Context, in *authv1.LoginRequest, opts ...grpc.CallOption) (*authv1.LoginResponse, error) {
	return f.loginFn(ctx, in, opts...)
}
func (f *fakeAuthServiceClient) GetUserById(ctx context.Context, in *authv1.GetUserByIdRequest, opts ...grpc.CallOption) (*authv1.GetUserByIdResponse, error) {
	return f.getUserByIdFn(ctx, in, opts...)
}
func (f *fakeAuthServiceClient) GetUsersByIds(ctx context.Context, in *authv1.GetUsersByIdsRequest, opts ...grpc.CallOption) (*authv1.GetUsersByIdsResponse, error) {
	return f.getUsersByIdsFn(ctx, in, opts...)
}

func TestAuthClient_Register(t *testing.T) {
	tests := []struct {
		name       string
		grpcResp   *authv1.RegisterResponse
		grpcErr    error
		wantStatus int
		wantName   string
	}{
		{
			name: "success maps user summary",
			grpcResp: &authv1.RegisterResponse{
				User: &authv1.UserSummary{Id: "uid-1", Name: "Ahmad", Email: "a@b.com"},
			},
			wantName: "Ahmad",
		},
		{
			name:       "AlreadyExists -> 409",
			grpcErr:    status.Error(codes.AlreadyExists, "email taken"),
			wantStatus: http.StatusConflict,
		},
		{
			name:       "InvalidArgument -> 400",
			grpcErr:    status.Error(codes.InvalidArgument, "bad input"),
			wantStatus: http.StatusBadRequest,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeAuthServiceClient{
				registerFn: func(_ context.Context, _ *authv1.RegisterRequest, _ ...grpc.CallOption) (*authv1.RegisterResponse, error) {
					return tt.grpcResp, tt.grpcErr
				},
			}
			c := NewAuthClient(fake)
			user, err := c.Register(context.Background(), "Ahmad", "a@b.com", "pass1234")

			if tt.wantStatus != 0 {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				ae, ok := err.(*httputil.AppError)
				if !ok {
					t.Fatalf("error type = %T, want *httputil.AppError", err)
				}
				if ae.Status != tt.wantStatus {
					t.Errorf("Status = %d, want %d", ae.Status, tt.wantStatus)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if user.Name != tt.wantName {
				t.Errorf("Name = %q, want %q", user.Name, tt.wantName)
			}
		})
	}
}

func TestAuthClient_Login(t *testing.T) {
	tests := []struct {
		name       string
		grpcResp   *authv1.LoginResponse
		grpcErr    error
		wantStatus int
		wantToken  string
	}{
		{
			name: "success maps token and user",
			grpcResp: &authv1.LoginResponse{
				Token: "tok123",
				User:  &authv1.UserSummary{Id: "uid-1", Name: "Ahmad", Email: "a@b.com"},
			},
			wantToken: "tok123",
		},
		{
			name:       "Unauthenticated -> 401",
			grpcErr:    status.Error(codes.Unauthenticated, "bad creds"),
			wantStatus: http.StatusUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeAuthServiceClient{
				loginFn: func(_ context.Context, _ *authv1.LoginRequest, _ ...grpc.CallOption) (*authv1.LoginResponse, error) {
					return tt.grpcResp, tt.grpcErr
				},
			}
			c := NewAuthClient(fake)
			token, user, err := c.Login(context.Background(), "a@b.com", "pass1234")

			if tt.wantStatus != 0 {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				ae, ok := err.(*httputil.AppError)
				if !ok {
					t.Fatalf("error type = %T, want *httputil.AppError", err)
				}
				if ae.Status != tt.wantStatus {
					t.Errorf("Status = %d, want %d", ae.Status, tt.wantStatus)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if token != tt.wantToken {
				t.Errorf("token = %q, want %q", token, tt.wantToken)
			}
			if user == nil {
				t.Fatalf("user is nil")
			}
		})
	}
}

func TestAuthClient_GetUsersByIDs(t *testing.T) {
	tests := []struct {
		name       string
		grpcResp   *authv1.GetUsersByIdsResponse
		grpcErr    error
		wantStatus int
		wantLen    int
	}{
		{
			name: "success returns user summaries",
			grpcResp: &authv1.GetUsersByIdsResponse{
				Users: []*authv1.UserSummary{
					{Id: "uid-1", Name: "Ahmad", Email: "a@b.com"},
				},
			},
			wantLen: 1,
		},
		{
			name:       "Unavailable -> 503",
			grpcErr:    status.Error(codes.Unavailable, "down"),
			wantStatus: http.StatusServiceUnavailable,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeAuthServiceClient{
				getUsersByIdsFn: func(_ context.Context, _ *authv1.GetUsersByIdsRequest, _ ...grpc.CallOption) (*authv1.GetUsersByIdsResponse, error) {
					return tt.grpcResp, tt.grpcErr
				},
			}
			c := NewAuthClient(fake)
			users, err := c.GetUsersByIDs(context.Background(), []string{"uid-1"})

			if tt.wantStatus != 0 {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				ae, ok := err.(*httputil.AppError)
				if !ok {
					t.Fatalf("error type = %T, want *httputil.AppError", err)
				}
				if ae.Status != tt.wantStatus {
					t.Errorf("Status = %d, want %d", ae.Status, tt.wantStatus)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(users) != tt.wantLen {
				t.Errorf("len(users) = %d, want %d", len(users), tt.wantLen)
			}
		})
	}
}
