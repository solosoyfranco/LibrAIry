#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 🤖 STEP 3 — AI FILE ANALYSIS with folder awareness
# ============================================================

INBOX_DIRS="/data/inbox"
REPORTS_DIR="/data/reports"
OLLAMA_HOST="http://192.168.1.94:11434"
OLLAMA_MODEL="llama3.1:8b"
AI_TIMEOUT=60
REPORT_FILE="$REPORTS_DIR/step3_summary.json"

mkdir -p "$REPORTS_DIR"

echo "============================================================"
echo "🤖 [step3] Starting AI file analysis at $(date)"
echo "Ollama host: $OLLAMA_HOST"
echo "Model: $OLLAMA_MODEL"
echo "============================================================"

# --- Check Ollama connection ---
if ! curl -s --connect-timeout 5 "$OLLAMA_HOST/api/tags" >/dev/null; then
  echo "❌ ERROR: Cannot connect to Ollama at $OLLAMA_HOST"
  exit 1
fi
echo "✅ Ollama connection successful"

# --- Helpers ------------------------------------------------
skip_unwanted_file() {
  local name="${1,,}"
  case "$name" in
    .ds_store|thumbs.db|desktop.ini|.spotlight-v100|.trashes|.fseventsd)
      return 0 ;; # skip
  esac
  [[ "$name" == .* ]] && return 0
  return 1
}

get_type_hint() {
  local ext="${1,,}"
  case "$ext" in
    txt|md|log|csv|srt) echo "text" ;;
    jpg|jpeg|png|gif|bmp|heic|avif) echo "image" ;;
    pdf|doc|docx|xls|xlsx|ppt|pptx) echo "document" ;;
    mp3|flac|wav|ogg|m4a) echo "audio" ;;
    mp4|mkv|mov|avi|webm) echo "video" ;;
    zip|tar|gz|bz2|7z|rar) echo "archive" ;;
    cfg|ini|json|yaml|yml|xml|conf|sh|py|js) echo "config" ;;
    stl|obj|step|cad) echo "model" ;;
    *) echo "other" ;;
  esac
}

normalize_name() {
  local base="$1"
  base="$(echo "$base" | tr '[:upper:]' '[:lower:]')"
  base="$(echo "$base" | sed 's/[^a-z0-9._-]/_/g; s/__/_/g; s/_$//; s/^_//')"
  echo "$base"
}

# --- Collect top-level files --------------------------------
files=()
while IFS= read -r -d '' f; do
  name="$(basename "$f")"
  skip_unwanted_file "$name" && continue
  files+=("$f")
done < <(find "$INBOX_DIRS" -maxdepth 1 -type f -print0)

# --- Detect tagged subfolders (#) ---------------------------
declare -A seen_tagged_folders
while IFS= read -r -d '' folder; do
  tag="$(basename "$folder" | sed 's/^.*#//; s/_/ /g')"
  [[ -n "${seen_tagged_folders["$folder"]:-}" ]] && continue
  seen_tagged_folders["$folder"]=1
  echo "📁 Found tagged folder: $folder (tag: $tag)"
  while IFS= read -r -d '' f; do
    name="$(basename "$f")"
    skip_unwanted_file "$name" && continue
    files+=("$f#tag:${tag}")
  done < <(find "$folder" -type f -print0)
done < <(find "$INBOX_DIRS" -type d -name '*#*' -print0)

# --- Detect media-bundle folders ----------------------------
echo "🎬 Scanning for multi-type folders..."
bundle_folders=()
while IFS= read -r -d '' dir; do
  [[ "$(basename "$dir")" == .* ]] && continue
  [[ "$dir" == *"#"* ]] && continue
  # Count unique extensions
  types_found=$(find "$dir" -maxdepth 1 -type f | grep -Eo '\.[^.]+$' | tr '[:upper:]' '[:lower:]' | sort -u)
  type_count=$(echo "$types_found" | wc -l)
  if (( type_count > 1 )) || echo "$types_found" | grep -Eq '\.(mp4|mkv|avi|mov)'; then
    bundle_folders+=("$dir")
  fi
done < <(find "$INBOX_DIRS" -mindepth 1 -maxdepth 2 -type d -print0)
echo "🎥 Found ${#bundle_folders[@]} media-bundle folders."

# --- Exit early if nothing found ----------------------------
if [[ ${#files[@]} -eq 0 && ${#bundle_folders[@]} -eq 0 ]]; then
  echo "❌ No valid files found in $INBOX_DIRS"
  exit 0
fi

# --- Analysis begins ----------------------------------------
echo "🧾 Found ${#files[@]} individual files + ${#bundle_folders[@]} folders to analyze"
echo "[" >"$REPORT_FILE"
first=true

# --- Analyze folders first ----------------------------------
for bdir in "${bundle_folders[@]}"; do
  echo "🎞️ Analyzing folder bundle: $bdir"
  folder_name="$(basename "$bdir")"
  clean_folder="$(normalize_name "$folder_name")"

  mapfile -t bundle_files < <(find "$bdir" -type f -maxdepth 1)
  bundle_json="[]"

  for bf in "${bundle_files[@]}"; do
    fname="$(basename "$bf")"
    ext="${fname##*.}"
    type_hint=$(get_type_hint "$ext")
    clean_name="$(normalize_name "${fname%.*}").${ext,,}"
    bundle_json=$(jq --arg orig "$bf" --arg name "$clean_name" --arg type "$type_hint" \
      '. + [{"original_path":$orig,"proposed_name":$name,"category":$type,"confidence":"High","group_folder":"'"$clean_folder"'"}]' \
      <<<"$bundle_json")
  done

  entry=$(jq -n \
    --arg folder "$bdir" \
    --arg proposed_name "$clean_folder" \
    --arg category "VideoBundle" \
    --arg confidence "High" \
    --argjson files "$bundle_json" \
    '{original_path:$folder, proposed_name:$proposed_name, category:$category, confidence:$confidence, subfolder_hint:"media folder", bundle_files:$files}')

  if [[ "$first" == true ]]; then
    first=false
  else
    echo "," >>"$REPORT_FILE"
  fi
  echo "$entry" >>"$REPORT_FILE"
  echo "✅ Bundle analyzed: $clean_folder"
done

# --- Analyze standalone files -------------------------------
for file_entry in "${files[@]}"; do
  tag_context=""
  file="$file_entry"
  if [[ "$file" == *"#tag:"* ]]; then
    tag_context="${file#*#tag:}"
    file="${file%%#tag:*}"
  fi

  parent_dir="$(dirname "$file")"
  skip=false
  for bdir in "${bundle_folders[@]}"; do
    [[ "$parent_dir" == "$bdir" ]] && { skip=true; break; }
  done
  $skip && continue

  filename=$(basename "$file")
  ext="${filename##*.}"
  type_hint=$(get_type_hint "$ext")
  clean_name="$(normalize_name "${filename%.*}").${ext,,}"

  entry=$(jq -n \
    --arg orig "$file" \
    --arg name "$clean_name" \
    --arg category "$(get_type_hint "$ext")" \
    --arg confidence "High" \
    --arg subfolder "${tag_context:-""}" \
    '{original_path:$orig, proposed_name:$name, category:$category, confidence:$confidence, subfolder_hint:$subfolder}')

  if [[ "$first" == true ]]; then
    first=false
  else
    echo "," >>"$REPORT_FILE"
  fi
  echo "$entry" >>"$REPORT_FILE"
  echo "✅ Analyzed file: $filename"
done

echo "]" >>"$REPORT_FILE"
echo "============================================================"
echo "📄 Report saved to: $REPORT_FILE"
echo "✅ Analysis complete!"
echo "============================================================"