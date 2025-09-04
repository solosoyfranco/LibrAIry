#!/usr/bin/env bash
set -euo pipefail
QUARANTINE_DIR="${QUARANTINE_DIR:-/data/quarantine/duplicates}"
RETENTION_DAYS="${QUARANTINE_RETENTION_DAYS:-30}"

[[ -d "$QUARANTINE_DIR" ]] || exit 0

echo "[purge] Removing quarantine older than ${RETENTION_DAYS} days in $QUARANTINE_DIR"
# remove top-level dated folders older than retention
find "$QUARANTINE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -print -exec rm -rf {} +