#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 🪶 STEP 2 — Duplicate quarantine using czkawka_cli
# ============================================================

INBOX_DIRS="${INBOX_DIRS:-/data/inbox}"
LIBRARY_DIRS="${LIBRARY_DIRS:-/data/library}"
QUARANTINE_DIR="${QUARANTINE_DIR:-/data/quarantine}"
REPORTS_DIR="${REPORTS_DIR:-/data/reports}"
LOG_FILE="${LOG_FILE:-/tmp/step2.log}"

DATE_TAG=$(date +%Y-%m-%d)
QUARANTINE_TODAY="${QUARANTINE_DIR}/${DATE_TAG}"
REPORT_JSON="${REPORTS_DIR}/step2_summary.json"
TEMP_REPORT="${REPORTS_DIR}/step2_duplicates_${DATE_TAG}.txt"

ALLOWED_EXT="jpg,png,jpeg,gif,bmp,heic,avif,mp4,mkv,mov,avi,mp3,flac,wav,ogg,txt,pdf,docx"

mkdir -p "$REPORTS_DIR" "$QUARANTINE_TODAY"

echo "============================================================" | tee -a "$LOG_FILE"
echo "🪶 [step2] Starting media duplicate quarantine scan at $(date)" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

if ! command -v czkawka_cli >/dev/null 2>&1; then
  echo "[step2] ❌ ERROR: czkawka_cli not found." | tee -a "$LOG_FILE"
  jq -n '{error:"czkawka_cli_not_found"}' > "$REPORT_JSON"
  exit 1
fi

echo "[step2] ▶ Running czkawka_cli dup scan..." | tee -a "$LOG_FILE"
czkawka_cli dup -d "$INBOX_DIRS" -d "$LIBRARY_DIRS" \
  --allowed-extensions "$ALLOWED_EXT" \
  -f "$TEMP_REPORT" 2>>"$LOG_FILE" || true

if [[ ! -s "$TEMP_REPORT" ]]; then
  echo "[step2] ✅ No duplicates found." | tee -a "$LOG_FILE"
  jq -n --arg date "$(date -Iseconds)" \
    '{timestamp:$date, duplicates_found:0, files_quarantined:0, quarantine_dir:null, note:"No duplicates found"}' \
    > "$REPORT_JSON"
  echo "[step2] 🧾 Empty summary written to $REPORT_JSON" | tee -a "$LOG_FILE"
  exit 0
fi

sed -i 's/\r$//' "$TEMP_REPORT"
dupes_count=$(grep -cE '^---- Size' "$TEMP_REPORT" | tr -dc '0-9' || echo 0)
echo "[step2] Found $dupes_count duplicate entries." | tee -a "$LOG_FILE"

moved=0
inbox_files_to_move=()

while IFS= read -r line; do
  [[ "$line" =~ ^\"(.*)\"$ ]] || continue
  file="${BASH_REMATCH[1]}"
  [[ "$file" == "$INBOX_DIRS"* && -f "$file" ]] && inbox_files_to_move+=("$file")
done < "$TEMP_REPORT"

echo "[step2] 📝 Found ${#inbox_files_to_move[@]} inbox files to move" | tee -a "$LOG_FILE"

for file in "${inbox_files_to_move[@]}"; do
  [[ ! -f "$file" ]] && continue
  base="$(basename "$file")"
  dest="$QUARANTINE_TODAY/$base"
  counter=1
  while [[ -e "$dest" ]]; do
    dest="$QUARANTINE_TODAY/${base%.*}_dup${counter}.${base##*.}"
    ((counter++))
  done
  echo "[step2] 🧺 Moving $file → $dest" | tee -a "$LOG_FILE"
  if mv -n -- "$file" "$dest"; then ((moved++)); fi
done

total_files=$(find "$QUARANTINE_TODAY" -type f 2>/dev/null | wc -l || echo 0)
total_size=$(du -sh "$QUARANTINE_TODAY" 2>/dev/null | awk '{print $1}' || echo "0B")
avail=$(df -h "$QUARANTINE_DIR" | awk 'NR==2{print $4}' || echo "unknown")

jq -n \
  --arg date "$(date -Iseconds)" \
  --argjson found "${dupes_count:-0}" \
  --argjson moved "${moved:-0}" \
  --arg quarantine "$QUARANTINE_TODAY" \
  --arg size "$total_size" \
  --arg free "$avail" \
  '{
    timestamp:$date,
    duplicates_found:$found,
    files_quarantined:$moved,
    quarantine_dir:$quarantine,
    quarantine_size:$size,
    disk_free:$free
  }' > "$REPORT_JSON"

echo "[step2] ✅ JSON summary written to $REPORT_JSON" | tee -a "$LOG_FILE"
rm -f "$TEMP_REPORT"
echo "[step2] Finished at $(date)" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"