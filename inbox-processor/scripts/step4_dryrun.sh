#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

REPORTS_DIR="/data/reports"
REPORT_FILE="$REPORTS_DIR/step3_summary.json"
LIBRARY_ROOT="/data/library"
QUARANTINE_DIR="/data/quarantine"
LOG_FILE="/tmp/step4_dryrun.log"

mkdir -p "$QUARANTINE_DIR"
: > "$LOG_FILE"

trap 'ec=$?; echo "❌ [step4-dryrun] Error on line $LINENO (exit $ec)" | tee -a "$LOG_FILE"; exit $ec' ERR

echo "============================================================" | tee -a "$LOG_FILE"
echo "🧪 [step4-dryrun] Simulating file moves based on AI analysis" | tee -a "$LOG_FILE"
echo "Report: $REPORT_FILE" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

[[ -f "$REPORT_FILE" ]] || { echo "❌ Missing report file: $REPORT_FILE"; exit 1; }

sanitize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' |
  sed 's/#/_/g; s/[^a-z0-9._-]/_/g; s/__/_/g; s/_$//; s/^_//'
}

mapfile -t ITEMS < <(jq -c '.[]' "$REPORT_FILE")

declare -i total_moved=0
declare -i total_quarantined=0

for item_json in "${ITEMS[@]}"; do
  src_path=$(jq -r '.source_path // empty' <<< "$item_json")
  [[ -z "$src_path" ]] && { echo "⚠️ Skipping empty source_path"; continue; }

  bundle_type=$(jq -r '.bundle_type // "Unknown"' <<< "$item_json")
  suggested_name=$(jq -r '.suggested_name // "unnamed"' <<< "$item_json")
  recommended_path=$(jq -r '.recommended_path // empty' <<< "$item_json")
  reasoning=$(jq -r '.reasoning // "No reasoning provided."' <<< "$item_json")
  sub_enabled=$(jq -r '.subfolder_plan.enabled // false' <<< "$item_json")

  echo "------------------------------------------------------------" | tee -a "$LOG_FILE"
  echo "📦 Processing: $src_path" | tee -a "$LOG_FILE"
  echo "Type: $bundle_type" | tee -a "$LOG_FILE"
  echo "Suggested name: $suggested_name" | tee -a "$LOG_FILE"
  echo "Recommended path: $recommended_path" | tee -a "$LOG_FILE"
  echo "Reason: $reasoning" | tee -a "$LOG_FILE"

  # SIMPLIFIED PATH HANDLING - treat everything as directory-based
  if [[ "$recommended_path" == /data/* ]]; then
    dest_root="$recommended_path"
  elif [[ "$recommended_path" == data/* ]]; then
    dest_root="/$recommended_path"
  else
    dest_root="$LIBRARY_ROOT/$recommended_path"
  fi
  
  # Clean up path
  dest_root=$(echo "$dest_root" | sed 's|//|/|g')
  
  # FOR SINGLE FILES: If the path looks like a file (has extension), extract directory
  if [[ -f "$src_path" && "$dest_root" =~ \.[a-zA-Z0-9]{1,5}$ ]]; then
    echo "  ℹ️  Single file with file-like destination - extracting directory" | tee -a "$LOG_FILE"
    file_dest="$dest_root"
    dest_root=$(dirname "$dest_root")
    final_filename=$(basename "$file_dest")
    echo "  📂 Would create directory: $dest_root" | tee -a "$LOG_FILE"
    echo "  📄 Final filename: $final_filename" | tee -a "$LOG_FILE"
  else
    echo "  📂 Would create: $dest_root" | tee -a "$LOG_FILE"
    final_filename=""
  fi

  # Handle subfolders only for actual folders (not single files)
  if [[ "$sub_enabled" == "true" && -d "$src_path" ]]; then
    echo "  ➕ Would create subfolders:" | tee -a "$LOG_FILE"
    jq -r '.subfolder_plan.map | to_entries[]? | "\(.key)=\(.value)"' <<< "$item_json" 2>/dev/null |
      while IFS='=' read -r key val; do
        [[ -z "$val" || "$val" == "null" ]] && continue
        echo "    - $key → $dest_root/$val" | tee -a "$LOG_FILE"
      done
  fi

  mapfile -t FILES < <(jq -c '.files[]?' <<< "$item_json" 2>/dev/null)
  if [[ "${#FILES[@]}" -eq 0 ]]; then
    echo "  ⚠️ No files listed for this entry." | tee -a "$LOG_FILE"
    continue
  fi

  for fjson in "${FILES[@]}"; do
    orig_name=$(jq -r '.original_name // empty' <<< "$fjson")
    rename_to=$(jq -r '.rename_to // empty' <<< "$fjson")
    cat_hint=$(jq -r '.category // "other"' <<< "$fjson")

    if [[ -d "$src_path" ]]; then
      src_file="$src_path/$orig_name"
    else
      src_file="$src_path"
    fi

    if [[ ! -f "$src_file" ]]; then
      echo "    ⚠️ Would quarantine missing: $src_file" | tee -a "$LOG_FILE"
      ((total_quarantined++))
      continue
    fi

    # Determine final filename
    if [[ -n "$final_filename" ]]; then
      # Use the pre-determined filename from path analysis
      base_name="$final_filename"
    elif [[ -n "$rename_to" && "$rename_to" != "null" ]]; then
      # Use AI-suggested rename
      base_name=$(sanitize_name "$rename_to")
    else
      # Use original name sanitized
      base_name=$(sanitize_name "$orig_name")
    fi

    # Preserve file extension for single files
    if [[ -f "$src_path" ]]; then
      orig_ext="${orig_name##*.}"
      if [[ "$orig_name" == *.* && "${#orig_ext}" -le 5 && "$orig_ext" != "*" ]]; then
        # Only add extension if base_name doesn't have one
        if [[ ! "$base_name" =~ \.[a-zA-Z0-9]{1,5}$ ]]; then
          final_name="${base_name}.${orig_ext,,}"
        else
          final_name="$base_name"
        fi
      else
        final_name="$base_name"
      fi
    else
      # For files in folders, preserve extension if rename_to doesn't include it
      if [[ -n "$rename_to" && "$rename_to" != "null" && ! "$rename_to" =~ \.[a-zA-Z0-9]{1,5}$ ]]; then
        orig_ext="${orig_name##*.}"
        if [[ "$orig_name" == *.* && "${#orig_ext}" -le 5 ]]; then
          final_name="${base_name}.${orig_ext,,}"
        else
          final_name="$base_name"
        fi
      else
        final_name="$base_name"
      fi
    fi

    # Determine destination path
    if [[ "$sub_enabled" == "true" && -d "$src_path" ]]; then
      set +e
      subfolder=$(jq -r --arg key "$cat_hint" '.subfolder_plan.map[$key] // empty' <<< "$item_json" 2>/dev/null)
      set -e
      [[ -z "$subfolder" || "$subfolder" == "null" ]] && subfolder="other"
      dest_file="$dest_root/$subfolder/$final_name"
    else
      # For single files or disabled subfolders, place directly in destination
      dest_file="$dest_root/$final_name"
    fi

    dest_file=$(echo "$dest_file" | sed 's|//|/|g')
    echo "    🚚 Would move: $src_file → $dest_file" | tee -a "$LOG_FILE"
    ((total_moved++)) || true
  done
done

echo "============================================================" | tee -a "$LOG_FILE"
echo "✅ [step4-dryrun] Simulation complete:" | tee -a "$LOG_FILE"
echo "   $total_moved moves simulated" | tee -a "$LOG_FILE"
echo "   $total_quarantined quarantines simulated" | tee -a "$LOG_FILE"