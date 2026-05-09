package grpcserver

import (
	"context"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/domain"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/usecase"
	pkgerrors "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/errors"
	authv1 "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/auth/v1"
)

type AuthServer struct {
	authv1.UnimplementedAuthServiceServer
	uc *usecase.AuthUsecase
}

func NewAuthServer(uc *usecase.AuthUsecase) *AuthServer {
	return &AuthServer{uc: uc}
}

func (s *AuthServer) Register(ctx context.Context, req *authv1.RegisterRequest) (*authv1.RegisterResponse, error) {
	user, err := s.uc.Register(ctx, req.GetName(), req.GetEmail(), req.GetPassword())
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	return &authv1.RegisterResponse{
		User: domainUserToProtoSummary(user),
	}, nil
}

func (s *AuthServer) Login(ctx context.Context, req *authv1.LoginRequest) (*authv1.LoginResponse, error) {
	token, user, err := s.uc.Login(ctx, req.GetEmail(), req.GetPassword())
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	return &authv1.LoginResponse{
		Token: token,
		User:  domainUserToProtoSummary(user),
	}, nil
}

func (s *AuthServer) GetUserById(ctx context.Context, req *authv1.GetUserByIdRequest) (*authv1.GetUserByIdResponse, error) {
	user, err := s.uc.GetUserByID(ctx, req.GetUserId())
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	return &authv1.GetUserByIdResponse{
		User: domainUserToProtoSummary(user),
	}, nil
}

func (s *AuthServer) GetUsersByIds(ctx context.Context, req *authv1.GetUsersByIdsRequest) (*authv1.GetUsersByIdsResponse, error) {
	users, err := s.uc.GetUsersByIDs(ctx, req.GetUserIds())
	if err != nil {
		return nil, pkgerrors.ToGRPCStatus(err)
	}

	respUsers := make([]*authv1.UserSummary, 0, len(users))
	for _, user := range users {
		respUsers = append(respUsers, domainUserToProtoSummary(user))
	}

	return &authv1.GetUsersByIdsResponse{
		Users: respUsers,
	}, nil
}

func domainUserToProtoSummary(u *domain.User) *authv1.UserSummary {
	if u == nil {
		return nil
	}

	return &authv1.UserSummary{
		Id:    u.ID,
		Name:  u.Name,
		Email: u.Email,
	}
}
