#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 📦 STEP 4 — MOVE FILES (with bundle and JSON support)
# ============================================================

REPORTS_DIR="/data/reports"
LIBRARY_DIR="/data/library"
INBOX_DIR="/data/inbox"
LOG_FILE="/tmp/step4_move.log"
DATE_TAG=$(date +%Y-%m-%d)
SUMMARY_JSON="$REPORTS_DIR/step4_summary_${DATE_TAG}.json"
REPORT_FILE="$REPORTS_DIR/step3_summary.json"

mkdir -p "$REPORTS_DIR"

if [[ ! -f "$REPORT_FILE" ]]; then
  echo "❌ step3_summary.json not found in $REPORTS_DIR"
  exit 1
fi

echo "============================================================" | tee "$LOG_FILE"
echo "📦 [step4] Starting file relocation at $(date)" | tee -a "$LOG_FILE"
echo "Using AI report: $REPORT_FILE" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

: > /tmp/moved.json
: > /tmp/skipped.json
: > /tmp/failed.json

trim() { echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
normalize_name() {
  local base="$1"
  base="$(echo "$base" | tr '[:upper:]' '[:lower:]')"
  base="$(echo "$base" | sed 's/[^a-z0-9._-]/_/g; s/__/_/g; s/_$//; s/^_//')"
  echo "$base"
}

# --- Handle bundle folders ----------------------------------
jq -c '.[] | select(.bundle_files)' "$REPORT_FILE" | while IFS= read -r bundle; do
  folder=$(echo "$bundle" | jq -r '.original_path')
  clean_name=$(echo "$bundle" | jq -r '.proposed_name')
  dest_dir="$LIBRARY_DIR/RAM/Movies/$clean_name"

  echo "🎬 Moving media bundle: $folder → $dest_dir" | tee -a "$LOG_FILE"
  mkdir -p "$(dirname "$dest_dir")"
  if mv -v -- "$folder" "$dest_dir" 2>>"$LOG_FILE"; then
    echo "{\"from\":\"$folder\",\"to\":\"$dest_dir\",\"bundle\":true}" >> /tmp/moved.json
  else
    echo "{\"error\":\"bundle_move_failed\",\"folder\":\"$folder\"}" >> /tmp/failed.json
  fi
done

# --- Scan inbox files ---------------------------------------
echo "🔍 Scanning inbox for remaining individual files..." | tee -a "$LOG_FILE"
mapfile -d '' existing_files < <(find "$INBOX_DIR" -type f -print0 2>/dev/null)
echo "📁 Found ${#existing_files[@]} total files." | tee -a "$LOG_FILE"
echo "---" | tee -a "$LOG_FILE"

# --- Move individual files ----------------------------------
jq -c '.[] | select(.bundle_files | not)' "$REPORT_FILE" | while IFS= read -r item; do
  original_path=$(echo "$item" | jq -r '.original_path // empty')
  proposed_name=$(echo "$item" | jq -r '.proposed_name // empty')
  category=$(echo "$item" | jq -r '.category // empty')
  subfolder_hint=$(echo "$item" | jq -r '.subfolder_hint // empty')

  [[ -z "$original_path" || -z "$proposed_name" ]] && {
    echo "{\"error\":\"missing_fields\",\"entry\":$item}" >> /tmp/skipped.json
    continue
  }

  decoded_path="${original_path//%20/ }"
  filename="$(trim "$(basename "$decoded_path")")"
  found_file=""
  for f in "${existing_files[@]}"; do
    [[ "$(trim "$(basename "$f")")" == "$filename" ]] && { found_file="$f"; break; }
  done

  if [[ -z "$found_file" ]]; then
    echo "⚠️ File not found, skipping: $filename" | tee -a "$LOG_FILE"
    echo "{\"error\":\"file_not_found\",\"filename\":\"$filename\"}" >> /tmp/skipped.json
    continue
  fi

  # --- Destination logic ------------------------------------
  case "${category,,}" in
    note) dest_dir="$LIBRARY_DIR/ROM/Notes" ;;
    document) dest_dir="$LIBRARY_DIR/ROM/Documents" ;;
    config) dest_dir="$LIBRARY_DIR/ROM/Configs" ;;
    photo|image) dest_dir="$LIBRARY_DIR/ROM/Photos" ;;
    music|audio) dest_dir="$LIBRARY_DIR/ROM/Music" ;;
    video|movie) dest_dir="$LIBRARY_DIR/RAM/Movies" ;;
    archive) dest_dir="$LIBRARY_DIR/ROM/Archives" ;;
    model) dest_dir="$LIBRARY_DIR/ROM/Models" ;;
    *) dest_dir="$LIBRARY_DIR/ROM/Misc" ;;
  esac

  if [[ -n "$subfolder_hint" && "$subfolder_hint" != "null" ]]; then
    clean_hint="$(normalize_name "$subfolder_hint")"
    dest_dir="$dest_dir/$clean_hint"
  fi
  mkdir -p "$dest_dir"

  dest_path="$dest_dir/$proposed_name"
  counter=1; base="${proposed_name%.*}"; ext="${proposed_name##*.}"
  while [[ -e "$dest_path" ]]; do
    dest_path="${dest_dir}/${base}_${counter}.${ext}"
    ((counter++))
  done

  echo "📁 Moving: $filename → $dest_path" | tee -a "$LOG_FILE"
  if mv -v -- "$found_file" "$dest_path" 2>>"$LOG_FILE"; then
    echo "{\"from\":\"$found_file\",\"to\":\"$dest_path\",\"category\":\"$category\"}" >> /tmp/moved.json
  else
    echo "{\"error\":\"move_failed\",\"file\":\"$found_file\"}" >> /tmp/failed.json
  fi
  echo "---" | tee -a "$LOG_FILE"
done

# --- Generate summary ---------------------------------------
moved_json=$(jq -s '.' /tmp/moved.json 2>/dev/null || echo "[]")
skipped_json=$(jq -s '.' /tmp/skipped.json 2>/dev/null || echo "[]")
failed_json=$(jq -s '.' /tmp/failed.json 2>/dev/null || echo "[]")

jq -n \
  --arg date "$(date -Iseconds)" \
  --arg report "$REPORT_FILE" \
  --argjson moved "$moved_json" \
  --argjson skipped "$skipped_json" \
  --argjson failed "$failed_json" \
  '{
    timestamp: $date,
    source_report: $report,
    summary: {
      moved: ($moved|length),
      skipped: ($skipped|length),
      failed: ($failed|length)
    },
    moved_files: $moved,
    skipped_files: $skipped,
    failed_files: $failed
  }' > "$SUMMARY_JSON"

echo "🧾 Summary JSON written to $SUMMARY_JSON" | tee -a "$LOG_FILE"
ARCHIVE_FILE="${REPORT_FILE%.json}_processed_$(date +%H-%M-%S).json"
mv "$REPORT_FILE" "$ARCHIVE_FILE"
echo "🗂️ Archived step3 report → $ARCHIVE_FILE" | tee -a "$LOG_FILE"
echo "📊 STEP 4 COMPLETE ✅" | tee -a "$LOG_FILE"
echo "============================================================"