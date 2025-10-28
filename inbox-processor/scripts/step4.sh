#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 📦 STEP 4 — MOVE FILES (bundle-aware + category routes)
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
  echo "❌ step3_summary.json missing — nothing to move."
  exit 1
fi

echo "============================================================" | tee "$LOG_FILE"
echo "📦 [step4] Starting file relocation at $(date)" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

: > /tmp/moved.json
: > /tmp/skipped.json
: > /tmp/failed.json

normalize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g; s/__/_/g; s/_$//; s/^_//'
}

# --- Move bundle folders ------------------------------------
jq -c '.[] | select(.bundle_files)' "$REPORT_FILE" | while IFS= read -r bundle; do
  src=$(echo "$bundle" | jq -r '.original_path')
  dest_name=$(echo "$bundle" | jq -r '.proposed_name')
  cat=$(echo "$bundle" | jq -r '.category')
  case "$cat" in
    VideoBundle) dest="$LIBRARY_DIR/RAM/Movies/$dest_name" ;;
    PhotoAlbum) dest="$LIBRARY_DIR/ROM/Photos/Albums/$dest_name" ;;
    MusicAlbum) dest="$LIBRARY_DIR/ROM/Music/Albums/$dest_name" ;;
    ModelBundle) dest="$LIBRARY_DIR/ROM/Models/Bundles/$dest_name" ;;
    DocumentSet) dest="$LIBRARY_DIR/ROM/Documents/Sets/$dest_name" ;;
    ArchiveCollection) dest="$LIBRARY_DIR/ROM/Archives/Collections/$dest_name" ;;
    *) dest="$LIBRARY_DIR/ROM/Misc/$dest_name" ;;
  esac
  echo "🎞️ Moving $cat: $src → $dest" | tee -a "$LOG_FILE"
  mkdir -p "$(dirname "$dest")"
  if mv -v -- "$src" "$dest" >>"$LOG_FILE" 2>&1; then
    echo "{\"from\":\"$src\",\"to\":\"$dest\",\"bundle\":true,\"category\":\"$cat\"}" >> /tmp/moved.json
  else
    echo "{\"error\":\"bundle_move_failed\",\"path\":\"$src\"}" >> /tmp/failed.json
  fi
done

# --- Move individual files ----------------------------------
jq -c '.[] | select(.bundle_files | not)' "$REPORT_FILE" | while IFS= read -r item; do
  src=$(echo "$item" | jq -r '.original_path')
  name=$(echo "$item" | jq -r '.proposed_name')
  cat=$(echo "$item" | jq -r '.category')
  [[ ! -f "$src" ]] && { echo "{\"error\":\"missing\",\"path\":\"$src\"}" >> /tmp/skipped.json; continue; }

  case "${cat,,}" in
    text|document) dest_base="$LIBRARY_DIR/ROM/Documents" ;;
    image|photo) dest_base="$LIBRARY_DIR/ROM/Photos" ;;
    audio|music) dest_base="$LIBRARY_DIR/ROM/Music" ;;
    video) dest_base="$LIBRARY_DIR/RAM/Movies" ;;
    model) dest_base="$LIBRARY_DIR/ROM/Models" ;;
    config) dest_base="$LIBRARY_DIR/ROM/Configs" ;;
    archive) dest_base="$LIBRARY_DIR/ROM/Archives" ;;
    *) dest_base="$LIBRARY_DIR/ROM/Misc" ;;
  esac

  mkdir -p "$dest_base"
  dest="$dest_base/$name"
  i=1; base="${name%.*}"; ext="${name##*.}"
  while [[ -e "$dest" ]]; do
    dest="${dest_base}/${base}_${i}.${ext}"; ((i++))
  done

  echo "📁 Moving: $src → $dest" | tee -a "$LOG_FILE"
  if mv -v -- "$src" "$dest" >>"$LOG_FILE" 2>&1; then
    echo "{\"from\":\"$src\",\"to\":\"$dest\",\"category\":\"$cat\"}" >> /tmp/moved.json
  else
    echo "{\"error\":\"move_failed\",\"path\":\"$src\"}" >> /tmp/failed.json
  fi
done

# --- Cleanup empty folders ----------------------------------
find "$INBOX_DIR" -type d -empty -delete
echo "[step4] 🧹 Cleaned up empty folders in inbox." | tee -a "$LOG_FILE"

# --- Build summary ------------------------------------------
moved_json=$(jq -s '.' /tmp/moved.json 2>/dev/null || echo "[]")
skipped_json=$(jq -s '.' /tmp/skipped.json 2>/dev/null || echo "[]")
failed_json=$(jq -s '.' /tmp/failed.json 2>/dev/null || echo "[]")