module github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service

go 1.26.2

require (
	github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg v0.0.0
	github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen v0.0.0
	github.com/jackc/pgx/v5 v5.9.2
	golang.org/x/crypto v0.50.0
	google.golang.org/grpc v1.81.0
)

require (
	github.com/golang-jwt/jwt/v5 v5.3.1 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	golang.org/x/net v0.53.0 // indirect
	golang.org/x/sync v0.20.0 // indirect
	golang.org/x/sys v0.44.0 // indirect
	golang.org/x/text v0.37.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260504160031-60b97b32f348 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)

replace github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg => ../../pkg

replace github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen => ../../proto/gen
