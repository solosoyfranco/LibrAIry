#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 🤖 STEP 3 — AI FILE ANALYSIS (multi-category smart bundles)
# ============================================================

INBOX_DIRS="/data/inbox"
REPORTS_DIR="/data/reports"
OLLAMA_HOST="http://192.168.1.94:11434"
OLLAMA_MODEL="llama3.1:8b"
REPORT_FILE="$REPORTS_DIR/step3_summary.json"

mkdir -p "$REPORTS_DIR"

echo "============================================================"
echo "🤖 [step3] Starting AI file analysis at $(date)"
echo "Model: $OLLAMA_MODEL"
echo "============================================================"

if ! curl -s --connect-timeout 5 "$OLLAMA_HOST/api/tags" >/dev/null; then
  echo "❌ ERROR: Cannot connect to Ollama ($OLLAMA_HOST)"
  exit 1
fi

# ----------------- Helper functions --------------------------
skip_unwanted_file() {
  local n="${1,,}"
  case "$n" in
    .ds_store|thumbs.db|desktop.ini|.spotlight-v100|.trashes|.fseventsd) return 0 ;;
  esac
  [[ "$n" == .* ]] && return 0
  return 1
}

get_type_hint() {
  local ext="${1,,}"
  case "$ext" in
    txt|md|csv|srt|log|json|yaml|yml|xml|ini|cfg|conf) echo "text" ;;
    jpg|jpeg|png|gif|heic|avif|bmp|tiff|webp) echo "image" ;;
    mp3|wav|flac|ogg|aac|m4a) echo "audio" ;;
    mp4|mkv|mov|avi|webm|wmv) echo "video" ;;
    pdf|doc|docx|xls|xlsx|ppt|pptx|odt) echo "document" ;;
    stl|obj|step|3mf|scad) echo "model" ;;
    zip|7z|rar|tar|gz|bz2) echo "archive" ;;
    sh|py|js|go|cpp|h|java|rs|ps1|bat) echo "code" ;;
    gcode) echo "print" ;;
    *) echo "other" ;;
  esac
}

normalize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g; s/__/_/g; s/_$//; s/^_//'
}

# ---------------- Collect files + tagged folders --------------
files=()
while IFS= read -r -d '' f; do
  skip_unwanted_file "$(basename "$f")" && continue
  files+=("$f")
done < <(find "$INBOX_DIRS" -maxdepth 1 -type f -print0)

declare -A seen_tagged
while IFS= read -r -d '' dir; do
  tag="${dir##*#}"
  [[ -n "${seen_tagged["$dir"]:-}" ]] && continue
  seen_tagged["$dir"]=1
  while IFS= read -r -d '' f; do
    skip_unwanted_file "$(basename "$f")" && continue
    files+=("$f#tag:${tag}")
  done < <(find "$dir" -type f -print0)
done < <(find "$INBOX_DIRS" -type d -name '*#*' -print0)

# ---------------- Detect likely bundles ----------------------
bundle_folders=()
while IFS= read -r -d '' dir; do
  base="$(basename "$dir" | tr '[:upper:]' '[:lower:]')"
  [[ "$base" == .* ]] && continue
  [[ "$dir" == *"#"* ]] && continue

  count_videos=$(find "$dir" -maxdepth 1 -type f -iregex '.*\.\(mp4\|mkv\|mov\|avi\|webm\|wmv\)' | wc -l)
  count_srt=$(find "$dir" -maxdepth 1 -type f -iname "*.srt" | wc -l)
  count_images=$(find "$dir" -maxdepth 1 -type f -iregex '.*\.\(jpg\|jpeg\|png\|heic\|avif\|bmp\|gif\)' | wc -l)
  count_models=$(find "$dir" -maxdepth 1 -type f -iregex '.*\.\(stl\|obj\|3mf\|step\|scad\)' | wc -l)
  count_audio=$(find "$dir" -maxdepth 1 -type f -iregex '.*\.\(mp3\|wav\|flac\|ogg\|m4a\|aac\)' | wc -l)
  count_docs=$(find "$dir" -maxdepth 1 -type f -iregex '.*\.\(pdf\|docx\|pptx\|xlsx\)' | wc -l)

  if (( count_videos >= 1 )); then
    bundle_type="VideoBundle"
  elif (( count_images >= 3 && count_videos == 0 )); then
    bundle_type="PhotoAlbum"
  elif (( count_models >= 1 )); then
    bundle_type="ModelBundle"
  elif (( count_audio >= 3 )); then
    bundle_type="MusicAlbum"
  elif (( count_docs >= 3 )); then
    bundle_type="DocumentSet"
  else
    continue
  fi

  bundle_folders+=("$dir|$bundle_type")
done < <(find "$INBOX_DIRS" -mindepth 1 -maxdepth 2 -type d -print0)

echo "🎬 Found ${#bundle_folders[@]} multi-type bundles to analyze."

# ---------------- Write report -------------------------------
echo "[" > "$REPORT_FILE"
first=true

for entry in "${bundle_folders[@]}"; do
  IFS="|" read -r b type <<< "$entry"
  clean_folder=$(normalize_name "$(basename "$b")")
  mapfile -t files_in_bundle < <(find "$b" -maxdepth 1 -type f)
  bundle_json="[]"
  for bf in "${files_in_bundle[@]}"; do
    ext="${bf##*.}"
    t=$(get_type_hint "$ext")
    name="$(normalize_name "$(basename "$bf")")"
    bundle_json=$(jq --arg orig "$bf" --arg name "$name" --arg type "$t" \
      '. + [{"original_path":$orig,"proposed_name":$name,"category":$type,"group_folder":"'"$clean_folder"'"}]' <<< "$bundle_json")
  done
  entry_json=$(jq -n --arg folder "$b" --arg name "$clean_folder" --arg cat "$type" --argjson bundle "$bundle_json" \
    '{original_path:$folder, proposed_name:$name, category:$cat, confidence:"High", bundle_files:$bundle}')
  [[ "$first" == true ]] || echo "," >> "$REPORT_FILE"
  first=false
  echo "$entry_json" >> "$REPORT_FILE"
done

for f in "${files[@]}"; do
  tag=""
  [[ "$f" == *"#tag:"* ]] && { tag="${f#*#tag:}"; f="${f%%#tag:*}"; }
  [[ ! -f "$f" ]] && continue
  name="$(normalize_name "$(basename "$f")")"
  ext="${f##*.}"
  type="$(get_type_hint "$ext")"
  entry=$(jq -n --arg orig "$f" --arg name "$name" --arg cat "$type" --arg sub "$tag" \
    '{original_path:$orig, proposed_name:$name, category:$cat, subfolder_hint:$sub, confidence:"High"}')
  [[ "$first" == true ]] || echo "," >> "$REPORT_FILE"
  first=false
  echo "$entry" >> "$REPORT_FILE"
done

echo "]" >> "$REPORT_FILE"
echo "📄 Report saved to $REPORT_FILE"
echo "============================================================"