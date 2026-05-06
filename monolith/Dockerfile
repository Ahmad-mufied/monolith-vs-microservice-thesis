FROM golang:1.26-alpine AS builder

RUN apk add --no-cache ca-certificates git

WORKDIR /src

COPY monolith/go.mod monolith/go.sum ./monolith/

WORKDIR /src/monolith
RUN go mod download
RUN go install github.com/pressly/goose/v3/cmd/goose@latest

WORKDIR /src
COPY monolith ./monolith

WORKDIR /src/monolith
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/monolith ./cmd/server

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata

RUN addgroup -S app && adduser -S app -G app

WORKDIR /app

COPY --from=builder /out/monolith /usr/local/bin/monolith
COPY --from=builder /go/bin/goose /usr/local/bin/goose
COPY monolith/migrations ./migrations

USER app

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/monolith"]

