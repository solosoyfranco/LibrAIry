#!/usr/bin/env bash
set -euo pipefail

# ---- paths & inputs
REPORTS_DIR="${REPORTS_DIR:-/data/reports}"          # your binds decide the real host paths
LOGS_DIR="${LOGS_DIR:-/data/logs}"
JSON="${REPORTS_DIR}/rmlint.json"

# ---- policy / safety
QUARANTINE_DIR="${QUARANTINE_DIR:-/data/quarantine/duplicates}"
RETENTION_DAYS="${QUARANTINE_RETENTION_DAYS:-30}"
DELETE_INSTEAD="${DELETE_INSTEAD_OF_QUARANTINE:-false}"
ONLY_MOVE_FROM_INBOX="${ONLY_MOVE_FROM_INBOX:-true}"   # protect library by default
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

# ---- dirs from pipeline (used to decide keeper + protection)
INBOX_DIRS="${INBOX_DIRS:-/inbox}"
LIBRARY_DIRS="${LIBRARY_DIRS:-/library}"

mkdir -p "$REPORTS_DIR" "$LOGS_DIR" "$QUARANTINE_DIR"
[[ -f "$JSON" ]] || { echo "[phase1] No rmlint.json at $JSON. Run ACTION=plan first."; exit 1; }

# split env lists by comma or colon
IFS=',:' read -r -a INBOX_ARR <<< "$INBOX_DIRS"
IFS=',:' read -r -a LIB_ARR   <<< "$LIBRARY_DIRS"

# helper: path under any prefix?
in_any_prefix() {
  local p="$1"; shift
  local arr=("$@")
  for base in "${arr[@]}"; do
    case "$p" in
      "$base"|"$base"/*) return 0 ;;
    esac
  done
  return 1
}

# helper: strip a leading /data for nicer quarantine tree
strip_data_prefix() {
  local p="$1"
  [[ "$p" == /data/* ]] && printf "%s" "${p#/data}" || printf "%s" "$p"
}

TODAY="$(date +%F)"
DEST_ROOT="${QUARANTINE_DIR}/${TODAY}"
mkdir -p "$DEST_ROOT"

# ---------------- stats ----------------
moved=0
deleted=0
skipped_missing=0
protected_skipped=0
kept_groups=0

# Precompute high-level numbers from rmlint JSON (flat schema)
files_in_dup_sets=$(jq '[ .[] | select(.type=="duplicate_file") ] | length' "$JSON")
dup_sets=$(jq '[ .[] | select(.type=="duplicate_file") | .checksum ] | unique | length' "$JSON")
remove_candidates_total=$(jq '[ .[] | select(.type=="duplicate_file" and (.is_original==false)) ] | length' "$JSON")

# ---------------- process groups ----------------
while read -r grp_b64; do
  grp_json="$(echo "$grp_b64" | base64 -d)"

  # Extract members
  mapfile -t PATHS < <(echo "$grp_json" | jq -r '.members[].path')
  mapfile -t ORIGS < <(echo "$grp_json" | jq -r '.members[].is_original')

  # Choose keeper by policy (prefer library, else is_original, else first)
  keeper=""
  for i in "${!PATHS[@]}"; do
    p="${PATHS[$i]}"
    if in_any_prefix "$p" "${LIB_ARR[@]}"; then keeper="$p"; break; fi
  done
  if [[ -z "$keeper" ]]; then
    for i in "${!PATHS[@]}"; do
      [[ "${ORIGS[$i]}" == "true" ]] && keeper="${PATHS[$i]}" && break
    done
  fi
  [[ -z "$keeper" ]] && keeper="${PATHS[0]}"

  echo "[phase1] KEEPER: $keeper" | tee -a "$LOGS_DIR/dedupe.log"
  ((kept_groups++)) || true

  # Act on non-keepers
  for i in "${!PATHS[@]}"; do
    src="${PATHS[$i]}"
    [[ "$src" == "$keeper" ]] && continue

    # Protect anything not in INBOX (e.g., library) when ONLY_MOVE_FROM_INBOX=true
    if [[ "${ONLY_MOVE_FROM_INBOX,,}" == "true" ]] && ! in_any_prefix "$src" "${INBOX_ARR[@]}"; then
      echo "[phase1] SKIP (protected, not in INBOX): $src" | tee -a "$LOGS_DIR/dedupe.log"
      ((protected_skipped++)) || true
      continue
    fi

    if [[ ! -e "$src" ]]; then
      echo "[phase1] SKIP (missing): $src" | tee -a "$LOGS_DIR/dedupe.log"
      ((skipped_missing++)) || true
      continue
    fi

    if [[ "${DELETE_INSTEAD,,}" == "true" ]]; then
      rm -f -- "$src" && echo "[phase1] DELETE: $src" | tee -a "$LOGS_DIR/dedupe.log"
      ((deleted++)) || true
    else
      # quarantine path mirrors original (without /data prefix)
      rel="$(strip_data_prefix "$src")"
      qdst="${DEST_ROOT}${rel}"
      qdir="$(dirname "$qdst")"
      mkdir -p "$qdir"
      if mv -n -- "$src" "$qdst" 2>/dev/null; then
        echo "[phase1] QUARANTINE: $src -> $qdst" | tee -a "$LOGS_DIR/dedupe.log"
        ((moved++)) || true
      else
        i2=1; while [[ -e "$qdst.$i2" ]]; do ((i2++)); done
        mv -- "$src" "$qdst.$i2"
        echo "[phase1] QUARANTINE: $src -> $qdst.$i2" | tee -a "$LOGS_DIR/dedupe.log"
        ((moved++)) || true
      fi
    fi
  done
done < <( jq -r '
  [ .[] | select(.type=="duplicate_file") ]
  | group_by(.checksum)
  | map({ checksum: (.[0].checksum), members: [ .[] | {path, is_original} ] })
  | .[]
  | @base64
' "$JSON" )

# ---------------- pretty summary ----------------
echo >> "$LOGS_DIR/dedupe.log"

# Build a single summary block (used both for log and Discord)
summary_block="$(cat <<EOF
================ Phase 1 — Deduplication Report ================
Date: $(date)
📂 Inbox:  ${INBOX_DIRS}
📚 Library: ${LIBRARY_DIRS}

Files found:                 ${files_in_dup_sets}
Duplicates found:            ${dup_sets}
Candidates to quarantine:    ${remove_candidates_total}

Moved to quarantine:         ${moved}
Skipped (missing):           ${skipped_missing}

Quarantine path:             ${QUARANTINE_DIR}
Retention:                   ${RETENTION_DAYS} days
Mode:                        $( [[ "${DELETE_INSTEAD,,}" == "true" ]] && echo "DELETE" || echo "QUARANTINE" )
================================================================
EOF
)"

# Print the summary into the log
printf "%s\n" "$summary_block" | tee -a "$LOGS_DIR/dedupe.log"

# ---------------- Discord webhook (send only pretty summary) ----------------
if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
  text="$summary_block"

  # Trim to stay under Discord's limit (room for code fences)
  max=1800
  if [ "${#text}" -gt "$max" ]; then
    text="(truncated)\n${text:0:$max}"
  fi

  # Wrap in code fences and build JSON safely
  wrapped="$(printf '```\n%s\n```' "$text")"
  if ! payload="$(jq -n --arg content "$wrapped" '{content: $content}')" ; then
    echo "[discord] failed to build JSON payload with jq" | tee -a "$LOGS_DIR/dedupe.log"
  else
    attempt=1
    while : ; do
      http_body="$(mktemp)"; trap 'rm -f "$http_body"' RETURN
      http_code=$(curl -sS -o "$http_body" -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -H "User-Agent: LibrAIry/1.0" \
        --data-binary "$payload" \
        "$DISCORD_WEBHOOK_URL" || echo "000")

      if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        echo "[discord] sent (HTTP $http_code)" | tee -a "$LOGS_DIR/dedupe.log"
        rm -f "$http_body"; trap - RETURN
        break
      fi

      echo "[discord] attempt $attempt failed (HTTP $http_code): $(cat "$http_body")" | tee -a "$LOGS_DIR/dedupe.log"
      rm -f "$http_body"; trap - RETURN

      if (( attempt >= 3 )); then
        echo "[discord] giving up after $attempt attempts" | tee -a "$LOGS_DIR/dedupe.log"
        break
      fi
      attempt=$((attempt+1))
      sleep 1
    done
  fi
else
  echo "[discord] DISCORD_WEBHOOK_URL not set; skipping" | tee -a "$LOGS_DIR/dedupe.log"
fi
