FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    git \
    github-cli

# Non-root user matching the securityContext
RUN addgroup -g 1000 triage && adduser -u 1000 -G triage -D -h /home/triage triage

# Copy triage script
COPY triage.sh /app/triage.sh
RUN chmod +x /app/triage.sh

USER 1000:1000
WORKDIR /home/triage
