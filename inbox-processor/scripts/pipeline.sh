#!/usr/bin/env bash
set -euo pipefail

: "${INBOX_DIRS:=/data/inbox}"
: "${LIBRARY_DIRS:=/data/library}"
: "${REPORTS_DIR:=/data/reports}"
: "${LOGS_DIR:=/data/logs}"
: "${ACTION:=plan}"
: "${DISCORD_WEBHOOK_URL:=}"

mkdir -p "$REPORTS_DIR" "$LOGS_DIR"

# Split envs into arrays (comma OR colon separated)
IFS=',:' read -r -a INBOX_ARR <<< "$INBOX_DIRS"
IFS=',:' read -r -a LIB_ARR   <<< "$LIBRARY_DIRS"

echo "[inbox-processor] ACTION=$ACTION"
echo "[inbox-processor] INBOX_DIRS=${INBOX_ARR[*]}"
echo "[inbox-processor] LIBRARY_DIRS=${LIB_ARR[*]}"
echo "[inbox-processor] REPORTS_DIR=$REPORTS_DIR LOGS_DIR=$LOGS_DIR"

case "$ACTION" in
  plan)
    /opt/inbox/plan_rmlint.sh "${INBOX_ARR[@]}" -- "${LIB_ARR[@]}"
    /opt/inbox/summarize_reports.sh || true
    ;;
  apply)
    /opt/inbox/apply_rmlint.sh
    ;;
  dedupe)
    # always (re)plan first so we act on fresh data
    /opt/inbox/plan_rmlint.sh "${INBOX_ARR[@]}" -- "${LIB_ARR[@]}"
    /opt/inbox/apply_exact_dupes.sh
    /opt/inbox/purge_quarantine.sh || true
    /opt/inbox/summarize_reports.sh || true
    ;;
  *)
    echo "Unknown ACTION=$ACTION"; exit 2;;
    
esac
