module github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway

go 1.26.2

replace github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg => ../../pkg

replace github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen => ../../proto/gen

require (
	github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg v0.0.0-00010101000000-000000000000
	github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen v0.0.0-00010101000000-000000000000
	github.com/labstack/echo/v4 v4.15.2
	google.golang.org/grpc v1.81.0
)

require (
	github.com/golang-jwt/jwt/v5 v5.3.1 // indirect
	github.com/labstack/gommon v0.5.0 // indirect
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.22 // indirect
	github.com/valyala/bytebufferpool v1.0.0 // indirect
	github.com/valyala/fasttemplate v1.2.2 // indirect
	golang.org/x/crypto v0.50.0 // indirect
	golang.org/x/net v0.53.0 // indirect
	golang.org/x/sys v0.44.0 // indirect
	golang.org/x/text v0.37.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260504160031-60b97b32f348 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)
