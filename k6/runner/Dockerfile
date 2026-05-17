FROM grafana/k6:0.52.0

USER root

RUN apk add --no-cache bash gzip jq curl ca-certificates aws-cli

USER k6
WORKDIR /work
