FROM golang:1.26.2-alpine AS builder

ARG GOOSE_VERSION=v3.27.1

RUN apk add --no-cache ca-certificates git

WORKDIR /src

COPY pkg/go.mod pkg/go.sum ./pkg/
COPY proto/gen/go.mod proto/gen/go.sum ./proto/gen/
COPY microservices/auth-service/go.mod microservices/auth-service/go.sum ./microservices/auth-service/

WORKDIR /src/microservices/auth-service
RUN GOWORK=off go mod download
RUN go install github.com/pressly/goose/v3/cmd/goose@${GOOSE_VERSION}

WORKDIR /src
COPY pkg ./pkg
COPY proto/gen ./proto/gen
COPY microservices/auth-service ./microservices/auth-service

WORKDIR /src/microservices/auth-service
RUN GOWORK=off CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/auth-service ./cmd/server

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata

RUN addgroup -g 10001 -S app && adduser -S -D -H -u 10001 -G app app

WORKDIR /app

COPY --from=builder /out/auth-service /usr/local/bin/auth-service
COPY --from=builder /go/bin/goose /usr/local/bin/goose
COPY microservices/auth-service/migrations ./migrations

USER 10001:10001

EXPOSE 50051

ENTRYPOINT ["/usr/local/bin/auth-service"]
