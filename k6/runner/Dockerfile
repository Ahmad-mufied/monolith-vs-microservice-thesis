FROM golang:1.26.2-alpine AS builder

ARG K6_BUILD_VERSION=v1.7.1
ARG XK6_VERSION=v1.2.3
ARG XK6_OUTPUT_STATSD_VERSION=v0.2.3

RUN apk add --no-cache git
RUN go install go.k6.io/xk6/cmd/xk6@${XK6_VERSION}
RUN xk6 build ${K6_BUILD_VERSION} \
  --with github.com/LeonAdato/xk6-output-statsd@${XK6_OUTPUT_STATSD_VERSION} \
  --output /tmp/k6

FROM alpine:3.22

USER root

RUN apk add --no-cache bash gzip jq curl ca-certificates aws-cli

COPY --from=builder /tmp/k6 /usr/bin/k6
COPY k6 /work/k6

RUN addgroup -g 10001 -S k6 && adduser -S -D -H -u 10001 -G k6 k6
RUN chmod +x /work/k6/runner/run-k6.sh \
  && mkdir -p /work/tmp \
  && chown -R k6:k6 /work

USER 10001:10001
WORKDIR /work
