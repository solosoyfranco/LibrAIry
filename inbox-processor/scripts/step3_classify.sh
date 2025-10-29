#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# 🤖 STEP 3 — Full AI-Driven Classification (Inbox + Library-aware)
# ============================================================

INBOX_DIR="/data/inbox"
LIBRARY_DIR="/data/library"
REPORTS_DIR="/data/reports"
REPORT_FILE="$REPORTS_DIR/step3_summary.json"

OLLAMA_HOST="${OLLAMA_HOST:-http://192.168.1.94:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.1:8b}"
TEMP_DIR="/tmp/ai_step3"
LOG_FILE="/tmp/step3_ai.log"

mkdir -p "$REPORTS_DIR" "$TEMP_DIR"
: > "$LOG_FILE"

trap 'ec=$?; echo "❌ [step3] Failed at line $LINENO (exit $ec)"; exit $ec' ERR

echo "============================================================" | tee -a "$LOG_FILE"
echo "🤖 [step3] Full AI run at $(date)" | tee -a "$LOG_FILE"
echo "Model: $OLLAMA_MODEL @ $OLLAMA_HOST" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

# ---------- helpers ----------

sanitize_name() {
  # lower, replace # with _, non-safe -> _, collapse _, trim ends
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/#/_/g; s/[^a-z0-9._-]/_/g; s/__/_/g; s/_$//; s/^_//'
}

ext_of() {
  local f="$1"; f="${f##*/}"; echo "${f##*.}" | tr '[:upper:]' '[:lower:]'
}

# Simple type hint (the AI will still decide final)
type_hint() {
  case "$(ext_of "$1")" in
    jpg|jpeg|png|gif|heic|avif|bmp|tiff|webp) echo "image" ;;
    mp4|mkv|mov|avi|webm|wmv)                 echo "video" ;;
    mp3|wav|flac|ogg|aac|m4a)                 echo "audio" ;;
    stl|obj|step|3mf|scad)                    echo "model" ;;
    gcode)                                    echo "print" ;;
    pdf|doc|docx|xls|xlsx|ppt|pptx|odt)       echo "document" ;;
    sh|py|js|go|cpp|c|h|rs|ps1|bat)           echo "code" ;;
    zip|7z|rar|tar|gz|bz2)                    echo "archive" ;;
    dmg|iso)                                  echo "diskimage" ;;
    srt|txt|md|csv|yaml|yml|json|xml|ini|cfg|conf|log) echo "text" ;;
    *)                                        echo "other" ;;
  esac
}

strip_code_fences() {
  # reads stdin, removes ```json ... ``` wrappers or ``` ... ```
  sed -E '1s/^```(json)?[[:space:]]*//; $s/[[:space:]]*```$//'
}

ai_call() {
  local prompt_file="$1"
  curl -sS "$OLLAMA_HOST/api/generate" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "model": "$OLLAMA_MODEL",
  "prompt": $(jq -Rs . < "$prompt_file"),
  "stream": false,
  "options": {
    "temperature": 0.2,
    "top_p": 0.9
  }
}
EOF
}

# ---------- build library context (for the model) ----------

# Summarize library by category buckets (path + counts + sample names)
LIB_SUMMARY="$TEMP_DIR/library_summary.txt"
: > "$LIB_SUMMARY"

summarize_bucket() {
  local label="$1" ; local path="$2" ; local limit="${3:-10}"
  echo "### $label ($path)" >> "$LIB_SUMMARY"
  if [[ -d "$path" ]]; then
    # counts by common extensions
    find "$path" -type f 2>/dev/null \
      | awk -F. '{print tolower($NF)}' \
      | sort | uniq -c | sort -nr | head -n 20 \
      | awk '{printf("- ext:%s count:%s\n",$2,$1)}' >> "$LIB_SUMMARY"
    echo "- sample:" >> "$LIB_SUMMARY"
    find "$path" -type f -maxdepth 4 2>/dev/null \
      | head -n "$limit" \
      | sed "s|$LIBRARY_DIR/||" \
      | awk '{print "  - " $0}' >> "$LIB_SUMMARY"
  else
    echo "- (missing)" >> "$LIB_SUMMARY"
  fi
  echo >> "$LIB_SUMMARY"
}

summarize_bucket "Movies (RAM)"   "$LIBRARY_DIR/RAM/Movies"            8
summarize_bucket "Photos (ROM)"   "$LIBRARY_DIR/ROM/Photos"            8
summarize_bucket "Photo Albums"   "$LIBRARY_DIR/ROM/Photos/Albums"     8
summarize_bucket "Documents"      "$LIBRARY_DIR/ROM/Documents"         8
summarize_bucket "Doc Sets"       "$LIBRARY_DIR/ROM/Documents/Sets"    6
summarize_bucket "Models"         "$LIBRARY_DIR/ROM/Models"            8
summarize_bucket "Model Bundles"  "$LIBRARY_DIR/ROM/Models/Bundles"    6
summarize_bucket "Music (ROM)"    "$LIBRARY_DIR/ROM/Music"             8
summarize_bucket "Music Albums"   "$LIBRARY_DIR/ROM/Music/Albums"      6
summarize_bucket "Archives (ROM)" "$LIBRARY_DIR/ROM/Archives"          6
summarize_bucket "Misc (ROM)"     "$LIBRARY_DIR/ROM/Misc"              10
summarize_bucket "Configs (ROM)"  "$LIBRARY_DIR/ROM/Configs"           6

# Cap library context length to keep prompt manageable (~12k chars hard cap)
LIB_CONTEXT="$(head -c 12000 "$LIB_SUMMARY")"

# ---------- collect inbox candidates ----------

declare -a CANDIDATES=()

# top-level files
while IFS= read -r -d '' f; do
  CANDIDATES+=("$f")
done < <(find "$INBOX_DIR" -maxdepth 1 -type f -print0)

# folders (depth 1 and 2 to catch Movies/<bundle> and any tagged projects)
while IFS= read -r -d '' d; do
  # skip hidden dirs
  base="$(basename "$d")"
  [[ "$base" == .* ]] && continue
  CANDIDATES+=("$d")
done < <(find "$INBOX_DIR" -mindepth 1 -maxdepth 2 -type d -print0)

echo "[step3] Found ${#CANDIDATES[@]} candidates in inbox." | tee -a "$LOG_FILE"

# ---------- master report ----------
echo "[" > "$REPORT_FILE"
FIRST=true

# ---------- per-candidate AI loop ----------

for item in "${CANDIDATES[@]}"; do
  rel_item="${item#$INBOX_DIR/}"
  echo "🧠 Analyzing: $rel_item" | tee -a "$LOG_FILE"

  ITEM_DESC_FILE="$TEMP_DIR/item_desc.txt"
  : > "$ITEM_DESC_FILE"

  if [[ -d "$item" ]]; then
    # Describe folder contents briefly
    echo "{ \"kind\":\"folder\", \"path\":\"$rel_item\", \"has_tag\":$( [[ "$rel_item" == *"#"* ]] && echo true || echo false ), \"files\":[" >> "$ITEM_DESC_FILE"
    first=true
    while IFS= read -r -d '' f; do
      bn="$(basename "$f")"
      sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
      th="$(type_hint "$f")"
      [[ "$first" == true ]] || echo "," >> "$ITEM_DESC_FILE"
      first=false
      printf '{"name":%s,"ext":%s,"bytes":%s,"hint":%s}' \
        "$(jq -Rn --arg s "$bn" '$s')" \
        "$(jq -Rn --arg s "$(ext_of "$bn")" '$s')" \
        "$sz" \
        "$(jq -Rn --arg s "$th" '$s')" >> "$ITEM_DESC_FILE"
    done < <(find "$item" -maxdepth 1 -type f -print0)
    echo "] }" >> "$ITEM_DESC_FILE"
  else
    bn="$(basename "$item")"
    sz=$(stat -c%s "$item" 2>/dev/null || echo 0)
    th="$(type_hint "$item")"
    printf '{"kind":"file","path":%s,"name":%s,"ext":%s,"bytes":%s,"hint":%s}' \
      "$(jq -Rn --arg s "$rel_item" '$s')" \
      "$(jq -Rn --arg s "$bn" '$s')" \
      "$(jq -Rn --arg s "$(ext_of "$bn")" '$s')" \
      "$sz" \
      "$(jq -Rn --arg s "$th" '$s')" > "$ITEM_DESC_FILE"
  fi

#   # ---- build prompt ----
#   PROMPT="$TEMP_DIR/prompt.txt"
#   {
#     echo "You are an expert digital librarian and file organizer."
#     echo "You will receive:"
#     echo "1) A brief inventory summary of the existing library (paths and extension counts)."
#     echo "2) A single candidate item from the inbox: either a folder (with its immediate files) or a single file."
#     echo
#     echo "Your task:"
#     echo "- Decide the best destination under /data/library using existing structure and best practices."
#     echo "- Choose an appropriate bundle type (one of):"
#     echo "  VideoBundle | PhotoAlbum | ModelBundle | MusicAlbum | DocumentSet | ArchiveCollection | TaggedProject | MixedBundle | Standalone"
#     echo "- Propose a friendly, sanitized name for the item (no spaces, lowercase, use underscores; replace '#' with '_')."
#     echo "- If the item is a TaggedProject (folder name contains '#'), rename the folder to a friendly form like 'misc_project',"
#     echo "  and create subfolders by format (e.g., 'models', 'prints', 'images', 'documents', 'audio', 'video', 'archives', 'code', 'other')."
#     echo "- For multi-format folders (MixedBundle or TaggedProject), suggest a subfolder strategy."
#     echo "- For a single file, just return where it should go and what the file should be renamed to."
#     echo "- IMPORTANT: Provide a strict JSON object with the schema below — no markdown fences, no extra text."
#     echo
#     echo "Destination expectations (examples):"
#     #### Videos
#     echo "- Movies go to: ROM vs RAM → Use RAM for movies: /data/library/RAM/Movies/<bundle>"
#     echo "- TV series bundles: /data/library/RAM/Shows/<series_name>"
#     ### Music
#     echo "- Music: /data/library/RAM/Music or /ROM/Music/Albums/<album>"
#     ### Photos
#     echo "- Photos: /data/library/ROM/Photos or /ROM/Photos/Albums/<album>"
#     echo "- single photos: /data/library/ROM/Photos/Unsorted/<image>"
#     echo "- Screenshots: /data/library/ROM/Images/Screenshots/<image>"
#     echo "- Memes: /data/library/ROM/Images/Memes/<image>"
#     ### 3D Models
#     echo "- 3D Models: /data/library/ROM/Models or /ROM/Models/Bundles/<bundle>"
#     echo "- Models: /data/library/ROM/Models or /ROM/Models/Bundles/<bundle>"
#     ### Documents
#     echo "- Documents: /data/library/ROM/Documents or /ROM/Documents/Sets/<set>"
#     echo "- Text files: /data/library/RAM/Misc/Text/<file>"
#     ### Other
#     echo "- Other: /data/library/RAM/Misc/Other"
#     echo "- Archives: /data/library/ROM/Archives"
#     echo "- Config/Code: /data/library/ROM/Configs or /ROM/Misc if unsure"
#     echo "- Mixed content bundles: /data/library/RAM/Misc/Mixed/<bundle>"
#     echo "- Tagged projects: /data/library/ROM/Misc/Projects/<project_name>"
#     echo "- Standalone files: /data/library/RAM/Misc/Unsorted/<file>"
#     echo "- ISO/DMG disk images: /data/library/RAM/Misc/DiskImages/<image>"
#     echo "- Code files: /data/library/ROM/Code or /ROM/Misc/Code/<file>"
#     echo "- backups or dumps: /data/library/ROM/Backups/<file>"
#     ### ignore
#     echo "- Ignore system files, hidden files, thumbs.db, .DS_Store, desktop.ini, etc."
#     echo
#     echo "JSON Schema (output exactly one object):"
#     echo '{'
#     echo '  "bundle_type": "VideoBundle|PhotoAlbum|ModelBundle|MusicAlbum|DocumentSet|ArchiveCollection|TaggedProject|MixedBundle|Standalone",'
#     echo '  "suggested_name": "string (sanitized)",'
#     echo '  "recommended_path": "string (relative under /data/library, e.g., ROM/Models/Bundles/misc_project or RAM/Movies/wrongfully_accused_1998_webrip_1080p_yts.lt)",'
#     echo '  "reasoning": "short justification",'
#     echo '  "subfolder_plan": { "enabled": true/false, "map": { "models": "models", "prints": "prints", "images": "images", "documents": "documents", "audio": "audio", "video": "video", "archives": "archives", "code": "code", "other":"other" } },'
#     echo '  "files": ['
#     echo '     { "original_name": "string", "category": "image|video|model|print|audio|document|archive|code|text|diskimage|other", "rename_to": "string or null" }'
#     echo '  ]'
#     echo '}'
#     echo
#     echo "Library summary:"
#     echo "$LIB_CONTEXT"
#     echo
#     echo "Candidate item (JSON):"
#     cat "$ITEM_DESC_FILE"
#     echo
#     echo "Respond with only the JSON object."
#   } > "$PROMPT"
# ---- build prompt ----
PROMPT="$TEMP_DIR/prompt.txt"
{
  echo "You are an expert digital librarian and file organizer."
  echo
  echo "You will receive two things:"
  echo "1. A short inventory summary of the existing /data/library structure."
  echo "2. A single candidate item from the inbox (either one file or one folder with its immediate files)."
  echo
  echo "Your task:"
  echo "- Decide the best destination for the item under /data/library, following existing organization and examples."
  echo "- ALWAYS choose one of these bundle types:"
  echo "  VideoBundle | PhotoAlbum | ModelBundle | MusicAlbum | DocumentSet | ArchiveCollection | TaggedProject | MixedBundle | Standalone"
  echo "- ALWAYS sanitize names: lowercase, underscores instead of spaces. if there is a '#' in the name that means (its tagged) that belongs to a project (so keep it in bundle and subfolders). anything after the '#' its a description of the project or tag , replace '#' with '_'."
  echo
  echo "RULES FOR SINGLE FILES"
  echo "- If the candidate is a **single file**, classify it as 'Standalone' unless clearly part of a specific domain (e.g., photo, video, model, document)."
  echo "- For single files:"
  echo "    * DO NOT create subfolder plans or enable subfolder_plan."
  echo "    * Only one entry in 'files'."
  echo "    * recommended_path MUST be a **directory path** (not ending with a filename)."
  echo "    * Example: '/data/library/ROM/Photos/Unsorted' or 'RAM/Misc/Unsorted'."
  echo "    * rename_to should be the sanitized base name without extension, or null if no rename needed."
  echo
  echo "RULES FOR FOLDERS"
  echo "- If the candidate is a **folder**, classify it based on its contents:"
  echo "    * TaggedProject: folder name contains '#'."
  echo "    * MixedBundle: multiple file types but not a tagged project."
  echo "    * PhotoAlbum, ModelBundle, DocumentSet, etc., when clearly homogenous."
  echo "- For folders, you may enable subfolder_plan=true if useful."
  echo
  echo "Output Requirements:"
  echo "- Produce a strict JSON object (no markdown, no extra text, comments or emojis)."
  echo "- Ensure the output adheres to this schema:"
  echo '{'
  echo '  "bundle_type": "VideoBundle|PhotoAlbum|ModelBundle|MusicAlbum|DocumentSet|ArchiveCollection|TaggedProject|MixedBundle|Standalone",'
  echo '  "suggested_name": "string (sanitized)",'
  echo '  "recommended_path": "string (relative under /data/library, e.g., ROM/Models/Bundles/misc_project or ROM/Photos/Unsorted)",'
  echo '  "reasoning": "short justification",'
  echo '  "subfolder_plan": { "enabled": true/false, "map": { "models": "models", "prints": "prints", "images": "images", "documents": "documents", "audio": "audio", "video": "video", "archives": "archives", "code": "code", "other":"other" } },'
  echo '  "files": ['
  echo '     { "original_name": "string", "category": "image|video|model|print|audio|document|archive|code|text|diskimage|other", "rename_to": "string or null" }'
  echo '  ]'
  echo '}'
  echo
  echo "Destination expectations (examples):"
  echo "- Movies → /data/library/RAM/Movies/<bundle>"
  echo "- TV series → /data/library/RAM/Shows/<series_name>"
  echo "- Photos → /data/library/ROM/Photos or /ROM/Photos/Albums/<album>"
  echo "- Single photos → /data/library/ROM/Photos/Unsorted/<image>"
  echo "- Screenshots → /data/library/ROM/Images/Screenshots/<image>"
  echo "- 3D models → /data/library/ROM/Models or /ROM/Models/Bundles/<bundle>"
  echo "- Documents → /data/library/ROM/Documents or /ROM/Documents/Sets/<set>"
  echo "- Text → /data/library/RAM/Misc/Text/<file>"
  echo "- Archives → /data/library/ROM/Archives"
  echo "- Games → /data/library/ROM/Games or /ROM/Games/<platform>"
  echo "- Code/Configs → /data/library/ROM/Configs or /ROM/Misc/Code"
  echo "- Miscellaneous single files → /data/library/RAM/Misc/Unsorted/<file>"
  echo "- ISO/DMG disk images → /data/library/RAM/Misc/DiskImages/<image>"
  echo "- Tagged projects → /data/library/ROM/Misc/Projects/<project_name>"
  echo "- Ignore hidden/system files (.DS_Store, thumbs.db, etc.)"
  echo
  echo "=== MUSIC & VIDEO SPECIAL INSTRUCTIONS ==="
  echo "- You will often encounter MP3, FLAC, or WAV files that lack proper tags."
  echo "- Classify them as:"
  echo "  * MusicAlbum: if multiple related songs (same folder, similar prefix, album context)"
  echo "  * MusicSingle: if an isolated song or loose track"
  echo "  * LiveRecording: if name contains 'live', 'concert', 'session', or audience noise"
  echo "- When metadata is incomplete, rely on filename cues and acoustic fingerprint summaries."
  echo "- When unsure, group by audio content similarity or folder context."
  echo
  echo "For videos (MP4, MKV, MOV, AVI):"
  echo "- Classify as:"
  echo "  * MusicVideo: official music video or studio clip"
  echo "  * LivePerformanceVideo: concert or performance footage"
  echo "  * FanVideo: unofficial remix, lyric video, or montage"
  echo "- Prefer grouping by song title or artist if recognizable in filename."
  echo
  echo "Your job is to propose an organized structure under /data/library:"
  echo "- Music albums: /data/library/RAM/Music/Albums/<artist>_<album>"
  echo "- Singles: /data/library/RAM/Music/Singles/<artist>_<title>"
  echo "- Live recordings: /data/library/RAM/Music/Live/<artist>_<venue_or_year>"
  echo "- Music videos: /data/library/RAM/MusicVideos/<artist>_<title>"
  echo "- Live performance videos: /data/library/RAM/MusicVideos/LivePerformances/<artist>_<year>"
  echo "- Fan videos: /data/library/RAM/MusicVideos/FanVideos/<artist>_<title>"
  echo
  echo "For all music/video items, include bitrate (for audio) or resolution (for video) if available in metadata analysis."
  echo "This helps when selecting duplicates later."
  echo "Library summary:"
  echo "$LIB_CONTEXT"
  echo
  echo "Candidate item (JSON):"
  cat "$ITEM_DESC_FILE"
  echo
  echo "Respond ONLY with the JSON object, no prose or markdown fences."
} > "$PROMPT"
  # ---- call AI ----
  RAW="$TEMP_DIR/raw_$(uuidgen 2>/dev/null || date +%s%N).txt"
  RESP_JSON="$TEMP_DIR/resp_$(uuidgen 2>/dev/null || date +%s%N).json"
  ai_call "$PROMPT" > "$RAW" || { echo "  ✖️ AI call failed" | tee -a "$LOG_FILE"; continue; }

  # The /api/generate returns {"model":"..","created_at":"..","response":"...","done":true,...}
  # Extract the "response" string, strip code fences, and validate JSON.
  jq -er '.response' "$RAW" 2>/dev/null | strip_code_fences > "$RESP_JSON" || {
    echo "  ✖️ Could not extract .response" | tee -a "$LOG_FILE"
    continue
  }

  if ! jq -e 'type=="object" and .bundle_type and .suggested_name and .recommended_path and .files' "$RESP_JSON" >/dev/null 2>&1; then
    echo "  ✖️ Invalid JSON schema from AI — saving raw." | tee -a "$LOG_FILE"
    cp "$RAW" "$TEMP_DIR/invalid_$(basename "$rel_item")_$(date +%s).txt"
    continue
  fi

  # Augment with source path for step4
  AUGMENTED=$(jq --arg src "$item" '. + {source_path:$src}' "$RESP_JSON")

  # Append to master array
  if [[ "$FIRST" == true ]]; then
    FIRST=false
    echo "$AUGMENTED" >> "$REPORT_FILE"
  else
    echo "," >> "$REPORT_FILE"
    echo "$AUGMENTED" >> "$REPORT_FILE"
  fi

  echo "  ✅ Done: $rel_item" | tee -a "$LOG_FILE"
done

echo "]" >> "$REPORT_FILE"

echo "------------------------------------------------------------" | tee -a "$LOG_FILE"
echo "📄 Report written: $REPORT_FILE" | tee -a "$LOG_FILE"
jq -r '[
  (.[] | .bundle_type) as $t
  | $t
] | group_by(.) | map({type: .[0], count: length})' "$REPORT_FILE" 2>/dev/null \
  | tee -a "$LOG_FILE" || true

echo "✅ [step3] Finished at $(date)" | tee -a "$LOG_FILE"
