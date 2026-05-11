FROM golang:1.26.2-alpine AS builder

RUN apk add --no-cache ca-certificates git

WORKDIR /src

COPY pkg/go.mod pkg/go.sum ./pkg/
COPY proto/gen/go.mod proto/gen/go.sum ./proto/gen/
COPY microservices/api-gateway/go.mod microservices/api-gateway/go.sum ./microservices/api-gateway/

WORKDIR /src/microservices/api-gateway
RUN GOWORK=off go mod download

WORKDIR /src
COPY pkg ./pkg
COPY proto/gen ./proto/gen
COPY microservices/api-gateway ./microservices/api-gateway

WORKDIR /src/microservices/api-gateway
RUN GOWORK=off CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/api-gateway ./cmd/server

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata

RUN addgroup -g 10001 -S app && adduser -S -D -H -u 10001 -G app app

WORKDIR /app

COPY --from=builder /out/api-gateway /usr/local/bin/api-gateway

USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/api-gateway"]
