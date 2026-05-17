module github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway

go 1.26.2

replace github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg => ../../pkg

replace github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen => ../../proto/gen

require (
	github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pkg v0.0.0-20260517080655-aa9c3384a782
	github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen v0.0.0-20260517080655-aa9c3384a782
	github.com/labstack/echo/v4 v4.15.2
	golang.org/x/sync v0.20.0
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260511170946-3700d4141b60
	google.golang.org/grpc v1.81.1
)

require (
	github.com/golang-jwt/jwt/v5 v5.3.1 // indirect
	github.com/labstack/gommon v0.5.0 // indirect
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.22 // indirect
	github.com/valyala/bytebufferpool v1.0.0 // indirect
	github.com/valyala/fasttemplate v1.2.2 // indirect
	golang.org/x/crypto v0.51.0 // indirect
	golang.org/x/net v0.54.0 // indirect
	golang.org/x/sys v0.44.0 // indirect
	golang.org/x/text v0.37.0 // indirect
	golang.org/x/time v0.15.0 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)
