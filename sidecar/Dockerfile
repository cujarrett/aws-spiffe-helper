FROM golang:1.26-alpine AS builder

ARG HELPER_VERSION=v1.8.4

RUN apk add --no-cache build-base

RUN go install github.com/aws/rolesanywhere-credential-helper@${HELPER_VERSION} && \
    mv /go/bin/rolesanywhere-credential-helper /go/bin/aws_signing_helper

FROM alpine:3.24 AS spire

ARG SPIRE_VERSION=1.15.1
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    curl -sSL "https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/spire-${SPIRE_VERSION}-linux-${TARGETARCH}-musl.tar.gz" \
      -o /tmp/spire.tar.gz && \
    tar -xzf /tmp/spire.tar.gz -C /tmp && \
    mv /tmp/spire-${SPIRE_VERSION}/bin/spire-agent /usr/local/bin/spire-agent

FROM alpine:3.24

RUN apk add --no-cache jq openssl

COPY --from=builder /go/bin/aws_signing_helper /usr/local/bin/aws_signing_helper
COPY --from=spire /usr/local/bin/spire-agent /usr/local/bin/spire-agent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN addgroup -S app && adduser -S app -G app
USER app

ENTRYPOINT ["/entrypoint.sh"]
