#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
INBOX_DIRS="${INBOX_DIRS:-/data/inbox}"
LIBRARY_DIRS="${LIBRARY_DIRS:-/data/library}"
QUARANTINE_DIR="${QUARANTINE_DIR:-/data/quarantine}"
REPORTS_DIR="${REPORTS_DIR:-/data/reports}"
LOG_FILE="${LOG_FILE:-/tmp/czkawka.log}"

DATE_TAG=$(date +%Y-%m-%d)
QUARANTINE_TODAY="${QUARANTINE_DIR}/${DATE_TAG}"
REPORT_JSON="${REPORTS_DIR}/step2_summary.json"
TEMP_REPORT="${REPORTS_DIR}/czkawka_duplicates_${DATE_TAG}.txt"

ALLOWED_EXT="jpg,png,jpeg,gif,bmp,heic,avif,mp4,mkv,mov,avi,mp3,flac,wav,ogg,txt,pdf,docx"

# --- Safety setup ---
mkdir -p "$REPORTS_DIR" "$(dirname "$LOG_FILE")"
if ! mkdir -p "$QUARANTINE_TODAY" 2>/dev/null; then
  echo "[step2] ERROR: cannot create $QUARANTINE_TODAY — check Docker mount permissions." | tee -a "$LOG_FILE"
  exit 1
fi

echo "============================================================" | tee -a "$LOG_FILE"
echo "🪶 [step2] Starting media duplicate quarantine scan at $(date)" | tee -a "$LOG_FILE"

# --- Step 1: Run czkawka_cli (duplicates only) ---
if ! command -v czkawka_cli >/dev/null 2>&1; then
  echo "[step2] ERROR: czkawka_cli not found. Please install it in /usr/local/bin." | tee -a "$LOG_FILE"
  exit 1
fi

echo "[step2] ▶ Running czkawka_cli dup scan..." | tee -a "$LOG_FILE"
czkawka_cli dup -d "$INBOX_DIRS" -d "$LIBRARY_DIRS" \
  --allowed-extensions "$ALLOWED_EXT" \
  -f "$TEMP_REPORT" 2>>"$LOG_FILE" || true

# --- Step 2: Validate report ---
if [[ ! -s "$TEMP_REPORT" ]]; then
  echo "[step2] No duplicates found. ✅" | tee -a "$LOG_FILE"
  # Clean up temp file immediately
  [[ -f "$TEMP_REPORT" ]] && rm -f "$TEMP_REPORT"
  exit 0
fi

# Clean the temp report of carriage returns
sed -i 's/\r$//' "$TEMP_REPORT" 2>/dev/null || true

# Count files by looking for quoted file paths
dupes_count=$(grep -c '^"/' "$TEMP_REPORT" 2>/dev/null || echo 0)
if [[ "$dupes_count" -eq 0 ]]; then
  echo "[step2] No duplicates detected by czkawka. ✅" | tee -a "$LOG_FILE"
  # Clean up temp file immediately
  [[ -f "$TEMP_REPORT" ]] && rm -f "$TEMP_REPORT"
  exit 0
fi
echo "[step2] Found $dupes_count duplicate entries." | tee -a "$LOG_FILE"

# --- Step 3: Extract ALL inbox duplicates ---
moved=0
total_bytes=0
inbox_files_to_move=()

echo "[step2] 🔍 Scanning for inbox duplicates to move..." | tee -a "$LOG_FILE"

# Extract ALL files that are in the inbox directory
while IFS= read -r line; do
  # Skip non-file lines
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^(Results|Found|-+$|----) ]] && continue
  
  # Extract filename from quotes
  if [[ "$line" =~ ^\"(.*)\"$ ]]; then
    file="${BASH_REMATCH[1]}"
    # If file is in inbox and exists, add to move list
    if [[ "$file" == "$INBOX_DIRS"* && -f "$file" ]]; then
      # Only add if not already in the list
      # This avoids trying to move the same file twice
      if ! [[ " ${inbox_files_to_move[*]} " =~ " ${file} " ]]; then
        inbox_files_to_move+=("$file")
        echo "[step2] 📋 Queued for move: $file" | tee -a "$LOG_FILE"
      fi
    fi
  fi
done < "$TEMP_REPORT"

echo "[step2] 📝 Found ${#inbox_files_to_move[@]} unique inbox files to move" | tee -a "$LOG_FILE"

# Move ALL inbox duplicates
# ----- START FIX -----
# Temporarily disable exit-on-error to ensure the loop finishes
set +e
# ----- END FIX -----
for file in "${inbox_files_to_move[@]}"; do
  if [[ -f "$file" ]]; then
    base="$(basename "$file")"
    dest="${QUARANTINE_TODAY}/${base}"
    
    # Generate unique filename if destination exists
    counter=1
    original_dest="$dest"
    while [[ -e "$dest" ]]; do
      name="${base%.*}"
      if [[ "$base" =~ \. ]]; then
        ext="${base##*.}"
        dest="${QUARANTINE_TODAY}/${name}_dup${counter}.${ext}"
      else
        dest="${QUARANTINE_TODAY}/${base}_dup${counter}"
      fi
      ((counter++))
      # Safety check to prevent infinite loop
      if (( counter > 1000 )); then
        echo "[step2] ERROR: Too many duplicate filenames for $base" | tee -a "$LOG_FILE"
        break
      fi
    done
    
    echo "[step2] 🧺 Moving duplicate: $file → $dest" | tee -a "$LOG_FILE"
    if mv -- "$file" "$dest"; then
      ((moved++))
      sz=$(stat -c '%s' "$dest" 2>/dev/null || echo 0)
      ((total_bytes+=sz))
      echo "[step2] ✅ Successfully moved $file" | tee -a "$LOG_FILE"
    else
      echo "[step2] ❌ Failed to move $file to $dest" | tee -a "$LOG_FILE"
    fi
  else
    echo "[step2] ⚠️ File no longer exists (already moved?): $file" | tee -a "$LOG_FILE"
  fi
done
# ----- START FIX -----
# Re-enable exit-on-error
set -e
# ----- END FIX -----

# --- Step 4: Build JSON report (using first script's structure) ---
group_data="[]"
current_group_files=()
current_group_size="unknown"

# Process the report to build group structure
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line//$'\r'/}"
  if [[ "$line" =~ ^----\ Size ]]; then
    # Flush previous group
    if (( ${#current_group_files[@]} > 0 )); then
      files_json=$(printf '%s\n' "${current_group_files[@]}" | jq -R . | jq -s .)
      group_data=$(jq --arg size "$current_group_size" --argjson files "$files_json" \
        '. + [{"size":$size,"files":$files}]' <<<"$group_data")
    fi
    current_group_size=$(echo "$line" | sed -E 's/^---- Size ([^ ]+) .*/\1/')
    current_group_files=()
    continue
  fi
  [[ -z "$line" || "$line" =~ ^(Results|Found|-+$) ]] && continue
  
  # Use regex to safely extract file path
  if [[ "$line" =~ ^\"(.*)\"$ ]]; then
    f="${BASH_REMATCH[1]}"
    current_group_files+=("$f")
  fi
done < "$TEMP_REPORT"

# Flush last group
if (( ${#current_group_files[@]} > 0 )); then
  files_json=$(printf '%s\n' "${current_group_files[@]}" | jq -R . | jq -s .)
  group_data=$(jq --arg size "$current_group_size" --argjson files "$files_json" \
    '. + [{"size":$size,"files":$files}]' <<<"$group_data")
fi

# --- Step 5: Generate final summary and JSON report ---
total_files=$(find "$QUARANTINE_TODAY" -type f 2>/dev/null | wc -l || echo 0)
total_size=$(du -sh "$QUARANTINE_TODAY" 2>/dev/null | awk '{print $1}' || echo "0B")
avail=$(df -h "$QUARANTINE_DIR" 2>/dev/null | awk 'NR==2{print $4}' || echo "unknown")

# Create the JSON report (using first script's format)
jq -n \
  --arg date "$(date -Iseconds)" \
  --argjson found "$dupes_count" \
  --argjson moved "$moved" \
  --arg quarantine "$QUARANTINE_TODAY" \
  --arg size "${total_size}" \
  --arg free "${avail}" \
  --argjson groups "$group_data" \
  '{
    timestamp: $date,
    duplicates_found: $found,
    files_quarantined: $moved,
    quarantine_dir: $quarantine,
    quarantine_size: $size,
    disk_free: $free,
    duplicate_groups: $groups
  }' > "$REPORT_JSON"

echo "[step2] ✅ JSON summary written to $REPORT_JSON" | tee -a "$LOG_FILE"
echo "[step2] Quarantined $moved files into $QUARANTINE_TODAY 🧺" | tee -a "$LOG_FILE"
echo "[step2] Quarantine summary: $total_files files, total size $total_size, disk free $avail 💾" | tee -a "$LOG_FILE"

# --- Step 6: Cleanup and finalize ---
# Remove the temporary report file
if [[ -f "$TEMP_REPORT" ]]; then
  rm -f "$TEMP_REPORT"
  echo "[step2] 🧹 Temporary report file removed" | tee -a "$LOG_FILE"
fi

echo "[step2] Finished at $(date)" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

# Exit with appropriate code
if (( moved > 0 )); then
  exit 0
else
  # Exit 0 for success, even if no files were moved.
  # The script's job (scan and quarantine) was successful.
  exit 0
fi
