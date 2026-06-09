package client

import (
	"context"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/dto"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	authv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/auth/v1"
)

// AuthClient wraps the generated gRPC AuthServiceClient.
type AuthClient struct {
	grpc        authv1.AuthServiceClient
	grpcTimeout time.Duration
}

// NewAuthClient creates an AuthClient. grpcTimeout is applied as a
// context.WithTimeout deadline on every outbound RPC call, ensuring calls do
// not remain open-ended when the upstream is slow.
func NewAuthClient(grpc authv1.AuthServiceClient, grpcTimeout time.Duration) *AuthClient {
	return &AuthClient{grpc: grpc, grpcTimeout: grpcTimeout}
}

func (c *AuthClient) Register(ctx context.Context, name, email, password string) (*dto.UserSummary, error) {
	ctx, cancel := context.WithTimeout(ctx, c.grpcTimeout)
	defer cancel()
	resp, err := c.grpc.Register(ctx, &authv1.RegisterRequest{Name: name, Email: email, Password: password})
	if err != nil {
		return nil, httputil.FromGRPCError(err)
	}
	return protoUserSummaryToDTO(resp.GetUser()), nil
}

func (c *AuthClient) Login(ctx context.Context, email, password string) (string, *dto.UserSummary, error) {
	ctx, cancel := context.WithTimeout(ctx, c.grpcTimeout)
	defer cancel()
	resp, err := c.grpc.Login(ctx, &authv1.LoginRequest{Email: email, Password: password})
	if err != nil {
		return "", nil, httputil.FromGRPCError(err)
	}
	return resp.GetToken(), protoUserSummaryToDTO(resp.GetUser()), nil
}

func (c *AuthClient) GetUsersByIDs(ctx context.Context, ids []string) ([]*dto.UserSummary, error) {
	ctx, cancel := context.WithTimeout(ctx, c.grpcTimeout)
	defer cancel()
	resp, err := c.grpc.GetUsersByIds(ctx, &authv1.GetUsersByIdsRequest{UserIds: ids})
	if err != nil {
		return nil, httputil.FromGRPCError(err)
	}
	users := make([]*dto.UserSummary, 0, len(resp.GetUsers()))
	for _, u := range resp.GetUsers() {
		users = append(users, protoUserSummaryToDTO(u))
	}
	return users, nil
}

func protoUserSummaryToDTO(u *authv1.UserSummary) *dto.UserSummary {
	if u == nil {
		return nil
	}
	return &dto.UserSummary{ID: u.GetId(), Name: u.GetName(), Email: u.GetEmail()}
}
