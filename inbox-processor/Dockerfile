FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive TZ=America/New_York
RUN apt-get update && apt-get install -y --no-install-recommends \
      rmlint jq gawk curl ca-certificates coreutils findutils procps bash \
      python3 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/inbox
COPY scripts/ /opt/inbox/
RUN chmod +x /opt/inbox/*.sh

# Defaults (override at runtime)
ENV INBOX_DIRS="/data/inbox" \
    LIBRARY_DIRS="/data/library" \
    REPORTS_DIR="/data/reports" \
    LOGS_DIR="/data/logs" \
    ACTION="plan" \
    QUARANTINE_DIR="/data/quarantine/duplicates" \
    QUARANTINE_RETENTION_DAYS="30" \
    DELETE_INSTEAD_OF_QUARANTINE="false" \
    DISCORD_WEBHOOK_URL=""

ENTRYPOINT ["/opt/inbox/pipeline.sh"]