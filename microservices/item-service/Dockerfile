FROM golang:1.26.2-alpine AS builder

ARG GOOSE_VERSION=v3.27.1

RUN apk add --no-cache ca-certificates git

WORKDIR /src

COPY pkg/go.mod pkg/go.sum ./pkg/
COPY proto/gen/go.mod proto/gen/go.sum ./proto/gen/
COPY microservices/item-service/go.mod microservices/item-service/go.sum ./microservices/item-service/

WORKDIR /src/microservices/item-service
RUN GOWORK=off go mod download
RUN go install github.com/pressly/goose/v3/cmd/goose@${GOOSE_VERSION}

WORKDIR /src
COPY pkg ./pkg
COPY proto/gen ./proto/gen
COPY microservices/item-service ./microservices/item-service

WORKDIR /src/microservices/item-service
RUN GOWORK=off CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/item-service ./cmd/server

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata

RUN addgroup -g 10001 -S app && adduser -S -D -H -u 10001 -G app app

WORKDIR /app

COPY --from=builder /out/item-service /usr/local/bin/item-service
COPY --from=builder /go/bin/goose /usr/local/bin/goose
COPY microservices/item-service/migrations ./migrations

USER 10001:10001

EXPOSE 50052

ENTRYPOINT ["/usr/local/bin/item-service"]
