#!/usr/bin/env bash
set -euo pipefail
REPORTS_DIR="${REPORTS_DIR:-/data/reports}"
LOGS_DIR="${LOGS_DIR:-/data/logs}"
mkdir -p "$LOGS_DIR"

if [[ ! -f "$REPORTS_DIR/rmlint_apply.sh" ]]; then
  echo "No rmlint_apply.sh present in $REPORTS_DIR"; exit 1
fi

bash "$REPORTS_DIR/rmlint_apply.sh" | tee -a "$LOGS_DIR/rmlint_apply.log"
