FROM golang:1.26.2-alpine AS builder

RUN apk add --no-cache ca-certificates git

WORKDIR /src
COPY seed/go.mod seed/go.sum ./seed/
WORKDIR /src/seed
RUN go mod download

WORKDIR /src
COPY seed ./seed
WORKDIR /src/seed
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/seed-runner ./cmd/seed-runner

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata
RUN addgroup -g 10001 -S app && adduser -S -D -H -u 10001 -G app app

WORKDIR /app
COPY --from=builder /out/seed-runner /usr/local/bin/seed-runner

USER 10001:10001
ENTRYPOINT ["/usr/local/bin/seed-runner"]
