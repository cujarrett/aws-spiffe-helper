FROM golang:1.26-alpine AS builder

ARG HELPER_VERSION=v1.8.4

RUN apk add --no-cache build-base

RUN go install github.com/aws/rolesanywhere-credential-helper@${HELPER_VERSION} && \
    mv /go/bin/rolesanywhere-credential-helper /go/bin/aws_signing_helper

FROM alpine:3.23

RUN apk add --no-cache jq

COPY --from=builder /go/bin/aws_signing_helper /usr/local/bin/aws_signing_helper

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN addgroup -S app && adduser -S app -G app
USER app

ENTRYPOINT ["/entrypoint.sh"]
