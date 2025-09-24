#!/usr/bin/env bash
set -euo pipefail
REPORTS_DIR="${REPORTS_DIR:-/data/reports}"
mkdir -p "$REPORTS_DIR"

INBOXES=(); LIBRARIES=(); MODE="inbox"
for a in "$@"; do
  if [[ "$a" == "--" ]]; then MODE="lib"; continue; fi
  if [[ "$MODE" == "inbox" ]]; then INBOXES+=("$a"); else LIBRARIES+=("$a"); fi
done

echo "[rmlint] INBOXES: ${INBOXES[*]}"
echo "[rmlint] LIBRARIES: ${LIBRARIES[*]}"

ARGS=("${INBOXES[@]}" "${LIBRARIES[@]}")

# write to /tmp first, then move (workaround for bind-mount oddities)
TMP_JSON="/tmp/rmlint.json"
TMP_SH="/tmp/rmlint_apply.sh"

rmlint "${ARGS[@]}" \
  --types=duplicates --hidden --xattr \
  -o json:"$TMP_JSON" \
  -o sh:"$TMP_SH"

mv -f "$TMP_JSON" "$REPORTS_DIR/rmlint.json"
mv -f "$TMP_SH"   "$REPORTS_DIR/rmlint_apply.sh"
echo "[rmlint] Wrote $REPORTS_DIR/rmlint.json and rmlint_apply.sh"
