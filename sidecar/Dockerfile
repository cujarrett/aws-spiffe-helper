FROM alpine:3.21

RUN apk add --no-cache curl jq

RUN curl -fsSL \
      "https://rolesanywhere.amazonaws.com/releases/1.8.4/Aarch64/Linux/aws_signing_helper" \
      -o /usr/local/bin/aws_signing_helper && \
    chmod +x /usr/local/bin/aws_signing_helper

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN addgroup -S app && adduser -S app -G app
USER app

ENTRYPOINT ["/entrypoint.sh"]
