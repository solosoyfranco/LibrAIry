#!/usr/bin/env bash
set -euo pipefail

REPORTS_DIR="${REPORTS_DIR:-/data/reports}"
LOG_FILE="${LOG_FILE:-/tmp/step4_dryrun.log}"
ERROR_LOG="${ERROR_LOG:-/tmp/step4_errors.log}"
SUMMARY_JSON="${REPORTS_DIR}/step4_summary.json"
STEP3_JSON="${REPORTS_DIR}/step3_summary.json"
REVIEW_DIR="/data/inbox/_review_pending"

mkdir -p "$REPORTS_DIR" "$REVIEW_DIR"

echo "============================================================" | tee -a "$LOG_FILE"
echo "DRY-RUN at $(date)" | tee -a "$LOG_FILE"
echo "Source: $STEP3_JSON" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

[[ ! -f "$STEP3_JSON" ]] && { echo "Missing $STEP3_JSON"; exit 1; }

moves=0
quarantines=0
reviews=0
subfolder_creations=0
move_log=()
quarantine_log=()
subfolder_log=()
review_log=()

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "" > "$ERROR_LOG"

# ----------------------------------------------------------
# Helper: validate bundle structure
# ----------------------------------------------------------
validate_bundle() {
  local b="$1"
  jq -e '
    .source_path and
    .suggested_name and
    .recommended_path and
    (.source_path | type=="string") and
    (.suggested_name | type=="string") and
    (.recommended_path | type=="string")
  ' <<<"$b" >/dev/null 2>&1
}

# ----------------------------------------------------------
# Main bundle loop
# ----------------------------------------------------------
while read -r bundle; do
  if ! validate_bundle "$bundle"; then
    echo -e "${RED}⚠ Invalid JSON bundle structure — skipped.${NC}" | tee -a "$LOG_FILE"
    echo "$bundle" >> "$ERROR_LOG"
    ((reviews++))
    continue
  fi

  src_root=$(echo "$bundle" | jq -r '.source_path')
  bundle_type=$(echo "$bundle" | jq -r '.bundle_type // "Unknown"')
  confidence=$(echo "$bundle" | jq -r '.confidence // 0.0')
  suggested_name=$(echo "$bundle" | jq -r '.suggested_name // empty')
  recommended_path=$(echo "$bundle" | jq -r '.recommended_path // empty')
  year=$(echo "$bundle" | jq -r '.metadata.year // null')
  subfolder_enabled=$(echo "$bundle" | jq -r '.subfolder_plan.enabled // false')
  subfolder_map=$(echo "$bundle" | jq -c '.subfolder_plan.map // {}')

  # --- Check invalid names or corrupted AI results ---
  if [[ "$suggested_name" =~ \]$ || "$suggested_name" =~ \.$ || "$suggested_name" =~ [\<\>\*\?\"] ]]; then
    echo -e "${RED}⚠ Corrupted suggested_name: $suggested_name${NC}" | tee -a "$LOG_FILE"
    mv "$src_root" "$REVIEW_DIR/" 2>/dev/null || true
    echo "$src_root → review (bad name)" >> "$ERROR_LOG"
    ((reviews++))
    continue
  fi

  # --- Skip low-confidence items to review folder ---
  if (( $(echo "$confidence < 0.5" | bc -l) )); then
    echo -e "${YELLOW}⚠ Low confidence ($confidence) — moving to review.${NC}" | tee -a "$LOG_FILE"
    mv "$src_root" "$REVIEW_DIR/" 2>/dev/null || true
    echo "$src_root → review (low confidence)" >> "$ERROR_LOG"
    ((reviews++))
    continue
  fi

  # --- Debug info ---
  echo -e "${BLUE}RAW SOURCE:${NC} $src_root" | tee -a "$LOG_FILE"
  echo -e "   Type: ${YELLOW}$bundle_type${NC} (conf: $confidence)" | tee -a "$LOG_FILE"

  # Sanitize destination
  dest_root="${recommended_path%/}"
  [[ -z "$dest_root" ]] && dest_root="/data/library/RAM/Misc/Unsorted"

  # Build final folder name
  final_folder="$suggested_name"
  if [[ "$bundle_type" == "MusicAlbum" && -n "$year" && "$year" != "null" ]]; then
    base="${suggested_name%.*}"
    ext="${suggested_name##*.}"
    [[ "$ext" != "$suggested_name" ]] && ext=".$ext"
    final_folder="${base}_$year$ext"
  fi

  # --- Destination logic ---
  if [[ -f "$src_root" ]]; then
    dest_path="$dest_root/$final_folder"
    echo -e "   FILE DEST: ${GREEN}$dest_path${NC}" | tee -a "$LOG_FILE"
  elif [[ -d "$src_root" ]]; then
    dest_root="$dest_root/$final_folder"
    echo -e "   FOLDER DEST: ${GREEN}$dest_root${NC}" | tee -a "$LOG_FILE"
  else
    echo -e "${RED}❌ Source missing → quarantine:${NC} $src_root" | tee -a "$LOG_FILE"
    quarantine_log+=("$src_root")
    ((quarantines++))
    continue
  fi

  # --- Subfolder creation (dry run only) ---
  if [[ "$subfolder_enabled" == "true" && -d "$src_root" ]]; then
    echo "   Creating subfolders:" | tee -a "$LOG_FILE"
    while IFS="=" read -r src_sub dest_sub; do
      [[ -z "$src_sub" ]] && continue
      echo -e "     ${BLUE}mkdir -p${NC} $dest_root/$dest_sub" | tee -a "$LOG_FILE"
      subfolder_log+=("$src_sub → $dest_sub")
      ((subfolder_creations++))
    done < <(echo "$subfolder_map" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  fi

  # --- File processing ---
  files_json=$(echo "$bundle" | jq -c '.files // []')
  file_count=$(echo "$files_json" | jq 'length')

  if (( file_count == 0 )) || [[ -f "$src_root" ]]; then
    echo "   SINGLE FILE MODE" | tee -a "$LOG_FILE"
    orig_name=$(basename "$src_root")
    rename_to=$(echo "$bundle" | jq -r '.files[0].rename_to // empty')
    [[ -z "$rename_to" || "$rename_to" == "null" ]] && rename_to="$orig_name"
    clean_name=$(echo "$rename_to" | tr -d ':\*\?"<>|' | sed 's/[^A-Za-z0-9._/-]/_/g')
    dest_path="$dest_root/$clean_name"
    if [[ ! -e "$src_root" ]]; then
      echo -e "${RED}Missing → quarantine:${NC} $src_root" | tee -a "$LOG_FILE"
      quarantine_log+=("$src_root")
      ((quarantines++))
    else
      echo -e "     ${GREEN}mv${NC} $src_root → $dest_path" | tee -a "$LOG_FILE"
      move_log+=("$src_root → $dest_path")
      ((moves++))
    fi
    continue
  fi

  # --- MULTI-FILE MODE ---
  echo "   MULTI-FILE MODE ($file_count files)" | tee -a "$LOG_FILE"
  for i in $(seq 0 $((file_count - 1))); do
    orig=$(echo "$files_json" | jq -r ".[$i].original_name // empty")
    rename=$(echo "$files_json" | jq -r ".[$i].rename_to // empty")
    [[ -z "$orig" ]] && continue
    src_path="$src_root/$orig"

    if [[ ! -e "$src_path" ]]; then
      echo -e "${RED}Missing → quarantine:${NC} $src_path" | tee -a "$LOG_FILE"
      quarantine_log+=("$src_path")
      ((quarantines++))
      continue
    fi

    [[ -z "$rename" || "$rename" == "null" ]] && rename="$orig"
    clean_name=$(echo "$rename" | tr -d ':\*\?"<>|' | sed 's/[^A-Za-z0-9._/-]/_/g')

    dest_file_path="$dest_root/$clean_name"
    echo -e "     ${GREEN}mv${NC} $src_path → $dest_file_path" | tee -a "$LOG_FILE"
    move_log+=("$src_path → $dest_file_path")
    ((moves++))
  done
done < <(jq -c '.[]' "$STEP3_JSON")

# ----------------------------------------------------------
# Final summary
# ----------------------------------------------------------
jq -n \
  --arg date "$(date -Iseconds)" \
  --argjson moves "$moves" \
  --argjson quarantines "$quarantines" \
  --argjson subfolders "$subfolder_creations" \
  --argjson reviews "$reviews" \
  --arg moves_list "$(printf '%s\n' "${move_log[@]}" | jq -R . | jq -s .)" \
  --arg quarantine_list "$(printf '%s\n' "${quarantine_log[@]}" | jq -R . | jq -s .)" \
  --arg review_list "$(printf '%s\n' "${review_log[@]}" | jq -R . | jq -s .)" \
  --arg subfolder_list "$(printf '%s\n' "${subfolder_log[@]}" | jq -R . | jq -s .)" \
  '{
    timestamp: $date,
    simulated_moves: $moves,
    simulated_quarantines: $quarantines,
    simulated_subfolders: $subfolders,
    flagged_for_review: $reviews,
    move_plan: $moves_list,
    quarantine_plan: $quarantine_list,
    review_plan: $review_list,
    subfolder_plan: $subfolder_list
  }' > "$SUMMARY_JSON"

echo "============================================================" | tee -a "$LOG_FILE"
echo -e "${GREEN}DRY-RUN COMPLETE${NC}" | tee -a "$LOG_FILE"
echo -e "   Moves: $moves" | tee -a "$LOG_FILE"
echo -e "   Quarantines: $quarantines" | tee -a "$LOG_FILE"
echo -e "   Review flags: $reviews" | tee -a "$LOG_FILE"
echo -e "   Subfolders: $subfolder_creations" | tee -a "$LOG_FILE"
echo -e "   Report: $SUMMARY_JSON" | tee -a "$LOG_FILE"
echo -e "   Error log: $ERROR_LOG" | tee -a "$LOG_FILE"
echo -e "   Review folder: $REVIEW_DIR" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"