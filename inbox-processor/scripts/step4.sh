#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
REPORTS_DIR="/data/reports"
LIBRARY_DIR="/data/library"
INBOX_DIR="/data/inbox"
LOG_FILE="/tmp/step4_move.log"

# Default AI report path
REPORT_FILE="${1:-$REPORTS_DIR/step3_text_$(date +%Y-%m-%d).json}"
DATE_TAG=$(date +%Y-%m-%d)
SUMMARY_JSON="$REPORTS_DIR/step4_summary_${DATE_TAG}.json"

echo "============================================================" | tee "$LOG_FILE"
echo "📦 [step4] Starting file relocation at $(date)" | tee -a "$LOG_FILE"
echo "Using AI report: $REPORT_FILE" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

if [[ ! -f "$REPORT_FILE" ]]; then
  echo "❌ No AI report found: $REPORT_FILE" | tee -a "$LOG_FILE"
  exit 1
fi

moved=0
skipped=0
failed=0

# Arrays for JSON summary
moved_files=()
skipped_files=()
failed_files=()

# First, let's see what files actually exist in the inbox
echo "🔍 Checking which files actually exist in $INBOX_DIR..." | tee -a "$LOG_FILE"
existing_files=()
while IFS= read -r -d '' file; do
    existing_files+=("$file")
done < <(find "$INBOX_DIR" -type f -name "*.txt" -print0 2>/dev/null)

echo "📁 Found ${#existing_files[@]} actual .txt files in inbox:" | tee -a "$LOG_FILE"
printf '  %s\n' "${existing_files[@]}" | tee -a "$LOG_FILE"
echo "---" | tee -a "$LOG_FILE"

# --- Process entries using proper JSON parsing ---
# Use jq to extract each object and handle the formatting properly
jq -c '.[]' "$REPORT_FILE" | while IFS= read -r item; do
  original_path=$(echo "$item" | jq -r '.original_path // empty')
  proposed_name=$(echo "$item" | jq -r '.proposed_name // empty')
  category=$(echo "$item" | jq -r '.category // empty')

  if [[ -z "$original_path" || -z "$proposed_name" ]]; then
    echo "⚠️ Skipping invalid entry (missing fields)" | tee -a "$LOG_FILE"
    echo "{\"error\": \"missing_fields\", \"item\": $item}" >> /tmp/skipped.json
    continue
  fi

  # Decode URL-encoded path (fix %20 to spaces)
  decoded_path="${original_path//\%20/ }"
  
  # Extract just the filename for lookup
  filename=$(basename "$decoded_path")
  
  # Check if file exists in inbox
  found_file=""
  for existing_file in "${existing_files[@]}"; do
    existing_filename=$(basename "$existing_file")
    if [[ "$existing_filename" == "$filename" ]]; then
      found_file="$existing_file"
      break
    fi
  done

  if [[ -z "$found_file" ]]; then
    echo "⚠️ File not found in inbox, skipping: $filename" | tee -a "$LOG_FILE"
    echo "{\"error\": \"file_not_in_inbox\", \"filename\": \"$filename\", \"original_path\": \"$original_path\"}" >> /tmp/skipped.json
    continue
  fi

  echo "📁 Processing: $filename" | tee -a "$LOG_FILE"
  echo "  Proposed name: $proposed_name" | tee -a "$LOG_FILE"
  echo "  Category: $category" | tee -a "$LOG_FILE"

  # --- Destination directory by category ---
  case "${category,,}" in
    note) dest_dir="$LIBRARY_DIR/ROM/Notes" ;;
    document) dest_dir="$LIBRARY_DIR/ROM/Documents" ;;
    config) dest_dir="$LIBRARY_DIR/ROM/Configs" ;;
    photo|image) dest_dir="$LIBRARY_DIR/ROM/Photos" ;;
    music|audio) dest_dir="$LIBRARY_DIR/ROM/Music" ;;
    video|movie) dest_dir="$LIBRARY_DIR/RAM/Movies" ;;
    *) dest_dir="$LIBRARY_DIR/ROM/Misc" ;;
  esac
  
  mkdir -p "$dest_dir"
  echo "  Destination: $dest_dir" | tee -a "$LOG_FILE"

  dest_path="$dest_dir/$proposed_name"

  # Avoid collisions
  counter=1
  base="${proposed_name%.*}"
  ext="${proposed_name##*.}"
  original_dest="$dest_path"
  while [[ -e "$dest_path" ]]; do
    dest_path="${dest_dir}/${base}_${counter}.${ext}"
    ((counter++))
    if [[ $counter -gt 10 ]]; then
      echo "❌ Too many duplicate filenames for: $proposed_name" | tee -a "$LOG_FILE"
      dest_path=""
      break
    fi
  done

  if [[ -n "$dest_path" ]]; then
    # Move the file
    echo "  Moving to: $dest_path" | tee -a "$LOG_FILE"
    if mv -v -- "$found_file" "$dest_path" 2>> "$LOG_FILE"; then
      echo "✅ Moved: $filename → $(basename "$dest_path")" | tee -a "$LOG_FILE"
      echo "{\"from\": \"$found_file\", \"to\": \"$dest_path\", \"category\": \"$category\", \"proposed_name\": \"$proposed_name\"}" >> /tmp/moved.json
      
      # Remove from existing_files array so we don't process it again
      for i in "${!existing_files[@]}"; do
        if [[ "${existing_files[i]}" == "$found_file" ]]; then
          unset 'existing_files[i]'
          break
        fi
      done
      # Reindex array
      existing_files=("${existing_files[@]}")
    else
      echo "❌ Failed to move: $filename" | tee -a "$LOG_FILE"
      echo "{\"error\": \"move_failed\", \"file\": \"$found_file\"}" >> /tmp/failed.json
    fi
  else
    echo "❌ Could not determine destination for: $filename" | tee -a "$LOG_FILE"
    echo "{\"error\": \"destination_error\", \"file\": \"$found_file\"}" >> /tmp/failed.json
  fi

  echo "---" | tee -a "$LOG_FILE"

done

# Count results from temporary files
if [[ -f /tmp/moved.json ]]; then
  moved=$(jq -s 'length' /tmp/moved.json)
  moved_files_json=$(jq -s '.' /tmp/moved.json)
else
  moved=0
  moved_files_json="[]"
fi

if [[ -f /tmp/skipped.json ]]; then
  skipped=$(jq -s 'length' /tmp/skipped.json)
  skipped_files_json=$(jq -s '.' /tmp/skipped.json)
else
  skipped=0
  skipped_files_json="[]"
fi

if [[ -f /tmp/failed.json ]]; then
  failed=$(jq -s 'length' /tmp/failed.json)
  failed_files_json=$(jq -s '.' /tmp/failed.json)
else
  failed=0
  failed_files_json="[]"
fi

# Clean up temp files
rm -f /tmp/moved.json /tmp/skipped.json /tmp/failed.json

# --- Build JSON summary ---
jq -n \
  --arg date "$(date -Iseconds)" \
  --argjson moved "$moved_files_json" \
  --argjson skipped "$skipped_files_json" \
  --argjson failed "$failed_files_json" \
  --arg report "$REPORT_FILE" \
  '{
    timestamp: $date,
    source_report: $report,
    summary: {
      moved: ($moved | length),
      skipped: ($skipped | length),
      failed: ($failed | length)
    },
    moved_files: $moved,
    skipped_files: $skipped,
    failed_files: $failed
  }' > "$SUMMARY_JSON"

echo "🧾 Summary JSON written to: $SUMMARY_JSON" | tee -a "$LOG_FILE"

# --- Archive processed report ---
ARCHIVE_FILE="${REPORT_FILE%.json}_processed_$(date +%H-%M-%S).json"
mv "$REPORT_FILE" "$ARCHIVE_FILE"
echo "🗂️ Archived AI report as: $ARCHIVE_FILE" | tee -a "$LOG_FILE"

# --- Show remaining files in inbox ---
remaining_files=()
while IFS= read -r -d '' file; do
    remaining_files+=("$file")
done < <(find "$INBOX_DIR" -type f -name "*.txt" -print0 2>/dev/null)

echo "📁 Remaining .txt files in inbox: ${#remaining_files[@]}" | tee -a "$LOG_FILE"
printf '  %s\n' "${remaining_files[@]}" | tee -a "$LOG_FILE"

# --- Summary printout ---
echo "============================================================" | tee -a "$LOG_FILE"
echo "📊 STEP 4 COMPLETE:" | tee -a "$LOG_FILE"
echo "  ✅ Moved:   $moved files" | tee -a "$LOG_FILE"
echo "  ⚠️ Skipped: $skipped files" | tee -a "$LOG_FILE"
echo "  ❌ Failed:  $failed files" | tee -a "$LOG_FILE"
echo "📁 Library updated at: $LIBRARY_DIR" | tee -a "$LOG_FILE"
echo "📄 Full log at: $LOG_FILE" | tee -a "$LOG_FILE"
echo "📋 Summary at: $SUMMARY_JSON" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

# Show what was actually moved
if [[ $moved -gt 0 ]]; then
  echo "📦 Files moved:" | tee -a "$LOG_FILE"
  jq -r '.moved_files[] | "  \(.from | split("/")[-1]) → \(.to)"' "$SUMMARY_JSON" 2>/dev/null | tee -a "$LOG_FILE"
fi

# Exit with appropriate code
if [[ $moved -eq 0 && $failed -gt 0 ]]; then
  exit 1
elif [[ $moved -gt 0 ]]; then
  exit 0
else
  exit 2
fi
EOF