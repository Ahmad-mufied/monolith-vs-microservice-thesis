package client

import (
	"net/http"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/httputil"
	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg/numconv"
)

// paginationToProto keeps HTTP pagination as int and narrows it only at the gRPC boundary.
func paginationToProto(limit, offset int) (int32, int32, error) {
	protoLimit, err := numconv.IntToInt32(limit, "limit")
	if err != nil {
		return 0, 0, &httputil.AppError{
			Status:  http.StatusBadRequest,
			Code:    "BAD_REQUEST",
			Message: err.Error(),
		}
	}

	protoOffset, err := numconv.IntToInt32(offset, "offset")
	if err != nil {
		return 0, 0, &httputil.AppError{
			Status:  http.StatusBadRequest,
			Code:    "BAD_REQUEST",
			Message: err.Error(),
		}
	}

	return protoLimit, protoOffset, nil
}
