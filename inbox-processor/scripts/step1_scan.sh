#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
INBOX_DIRS="${INBOX_DIRS:-/data/inbox}"
LIBRARY_DIRS="${LIBRARY_DIRS:-/data/library}"
QUARANTINE_DIR="${QUARANTINE_DIR:-/data/quarantine}"
REPORTS_DIR="${REPORTS_DIR:-/data/reports}"
LOG_FILE="${LOG_FILE:-/tmp/rmlint.log}"

DATE_TAG=$(date +%Y-%m-%d)
QUARANTINE_TODAY="${QUARANTINE_DIR}/${DATE_TAG}"

# --- Safety setup ---
mkdir -p "$REPORTS_DIR" "$(dirname "$LOG_FILE")"
if ! mkdir -p "$QUARANTINE_TODAY" 2>/dev/null; then
  echo "[step1] ERROR: cannot create $QUARANTINE_TODAY — check Docker mount permissions." | tee -a "$LOG_FILE"
  exit 1
fi

echo "============================================================" | tee -a "$LOG_FILE"
echo "🧹 [step1] Starting duplicate scan at $(date)" | tee -a "$LOG_FILE"

# --- Step 1: Run rmlint ---
rmlint "$INBOX_DIRS" "$LIBRARY_DIRS" \
  --types=duplicates \
  --output=json:"$REPORTS_DIR/rmlint.json" \
  | tee -a "$LOG_FILE"

# --- Step 2: Validate report ---
REPORT="$REPORTS_DIR/rmlint.json"
if [[ ! -s "$REPORT" ]]; then
  echo "[step1] No report found or empty. ✅" | tee -a "$LOG_FILE"
  exit 0
fi

dupes_count=$(jq '[.[] | select(.type=="duplicate_file")] | length' "$REPORT")
if [[ "$dupes_count" -eq 0 ]]; then
  echo "[step1] No duplicates found. ✅" | tee -a "$LOG_FILE"
  exit 0
fi
echo "[step1] Found $dupes_count duplicate entries." | tee -a "$LOG_FILE"

# --- Step 3: Group and move duplicates ---
moved=0
mapfile -t checksums < <(jq -r '[.[] | select(.type=="duplicate_file") | .checksum] | unique[]' "$REPORT")

for checksum in "${checksums[@]}"; do
  mapfile -t paths < <(jq -r --arg c "$checksum" '[.[] | select(.checksum==$c and .type=="duplicate_file") | .path] | .[]' "$REPORT")
  [[ ${#paths[@]} -le 1 ]] && continue

  # Split by library vs inbox
  inbox_files=()
  library_files=()
  for f in "${paths[@]}"; do
    if [[ "$f" == "$LIBRARY_DIRS"* ]]; then
      library_files+=("$f")
    elif [[ "$f" == "$INBOX_DIRS"* ]]; then
      inbox_files+=("$f")
    else
      inbox_files+=("$f") # fallback if unknown
    fi
  done

  # If library version exists → keep it, move inbox copies
  if ((${#library_files[@]} > 0)); then
    for f in "${inbox_files[@]}"; do
      if [[ -f "$f" ]]; then
        base="$(basename "$f")"
        dest="${QUARANTINE_TODAY}/${base}"
        # Avoid name collisions
        if [[ -e "$dest" ]]; then
          ext="${base##*.}"
          name="${base%.*}"
          dest="${QUARANTINE_TODAY}/${name}_dup_${RANDOM}.${ext}"
        fi
        echo "[step1] Moving duplicate (library wins): $f → $dest" | tee -a "$LOG_FILE"
        mv -n -- "$f" "$dest" && ((moved++)) || echo "[step1] WARN: could not move $f" | tee -a "$LOG_FILE"
      fi
    done
  else
    # No library version → keep one inbox file, move others
    keep="${inbox_files[0]}"
    for f in "${inbox_files[@]:1}"; do
      if [[ -f "$f" ]]; then
        base="$(basename "$f")"
        dest="${QUARANTINE_TODAY}/${base}"
        [[ -e "$dest" ]] && dest="${QUARANTINE_TODAY}/${base%.*}_dup_${RANDOM}.${base##*.}"
        echo "[step1] Moving duplicate (inbox set): $f → $dest" | tee -a "$LOG_FILE"
        mv -n -- "$f" "$dest" && ((moved++)) || echo "[step1] WARN: could not move $f" | tee -a "$LOG_FILE"
      fi
    done
  fi
done


# --- Step 4: Summaries ---

# Count duplicates *within library*
library_dupes=$(jq --arg lib "$LIBRARY_DIRS" \
  '[.[] | select(.type=="duplicate_file" and (.path|startswith($lib)))] | group_by(.checksum) | map(select(length>1)) | length' \
  "$REPORT" 2>/dev/null || echo 0)

# Optional: create a list of duplicate library files (for human-readable log)
if (( library_dupes > 0 )); then
  echo "[step1] ⚠ Found $library_dupes duplicate groups inside the library itself:" | tee -a "$LOG_FILE"
  jq -r --arg lib "$LIBRARY_DIRS" '
    [.[] | select(.type=="duplicate_file" and (.path|startswith($lib)))] 
    | group_by(.checksum) 
    | map(select(length>1) | {"checksum": .[0].checksum, "files": map(.path)}) 
    | .[]
    | "[\(.checksum[0:10])] " + (.files | join("\n  ├─ "))
  ' "$REPORT" | tee -a "$LOG_FILE"
else
  echo "[step1] ✅ No internal duplicates inside the library." | tee -a "$LOG_FILE"
fi

# --- Step 5: Global stats ---
total_files=$(find "$QUARANTINE_TODAY" -type f | wc -l || echo 0)
total_size=$(du -sh "$QUARANTINE_TODAY" 2>/dev/null | awk '{print $1}')
avail=$(df -h "$QUARANTINE_DIR" | awk 'NR==2{print $4}')

echo "[step1] Quarantined $moved files into $QUARANTINE_TODAY 🧺" | tee -a "$LOG_FILE"
echo "[step1] Quarantine summary: $total_files files, total size $total_size, disk free $avail 💾" | tee -a "$LOG_FILE"

# --- Step 6: JSON report with duplicate file paths ---

# Build structured JSON data for library duplicate groups
library_dup_json=$(jq --arg lib "$LIBRARY_DIRS" '
  [.[] 
   | select(.type=="duplicate_file" and (.path|startswith($lib))) 
   | {checksum, path}
  ] 
  | group_by(.checksum) 
  | map(select(length>1) 
    | {checksum: .[0].checksum, files: map(.path)}
  )
' "$REPORT")

jq -n \
  --arg date "$(date -Iseconds)" \
  --argjson found "$dupes_count" \
  --argjson moved "$moved" \
  --argjson library_groups "$library_dup_json" \
  --arg quarantine "$QUARANTINE_TODAY" \
  --arg size "${total_size:-unknown}" \
  --arg free "${avail:-unknown}" \
  '{
    timestamp: $date,
    duplicates_found: $found,
    files_quarantined: $moved,
    library_duplicates: $library_groups,
    quarantine_dir: $quarantine,
    quarantine_size: $size,
    disk_free: $free
  }' > "$REPORTS_DIR/step1_summary.json"

echo "[step1] JSON summary written to $REPORTS_DIR/step1_summary.json" | tee -a "$LOG_FILE"
echo "[step1] Finished at $(date)" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

if (( moved > 0 )); then
  exit 0
else
  exit 1
fi