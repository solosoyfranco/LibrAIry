#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# STEP 3 — AI Classification with Precision Schema
# ============================================================

INBOX_DIR="/data/inbox"
LIBRARY_DIR="/data/library"
REPORTS_DIR="/data/reports"
REPORT_FILE="$REPORTS_DIR/step3_summary.json"

OLLAMA_HOST="${OLLAMA_HOST:-http://10.0.2.11:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.1:8b}"
TEMP_DIR="/tmp/ai_step3"
LOG_FILE="/tmp/step3_ai.log"

mkdir -p "$REPORTS_DIR" "$TEMP_DIR"
: > "$LOG_FILE"

trap 'ec=$?; echo "ERROR [step3] Failed at line $LINENO (exit $ec)"; exit $ec' ERR

echo "============================================================" | tee -a "$LOG_FILE"
echo "Precision AI Classification at $(date)" | tee -a "$LOG_FILE"
echo "Model: $OLLAMA_MODEL @ $OLLAMA_HOST" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

# ---------- Core Helpers ----------

sanitize_name() {
    local base="$1"
    # Use LC_ALL=C to handle UTF-8 safely
    base="$(echo "$base" | LC_ALL=C sed 's/#/_/g; s/[^[:alnum:]._-]/_/g; s/__*/_/g; s/^_//; s/_$//')"
    base="$(echo "$base" | sed 's/_/ /g')"
    base="$(echo "$base" | awk '{for(i=1;i<=NF;i++){ $i=toupper(substr($i,1,1)) substr($i,2) }}1')"
    base="$(echo "$base" | sed 's/ /_/g')"
    echo "$base"
}

# Safe JSON string escaping
json_escape() {
    local str="$1"
    # Escape special characters for JSON
    printf '%s' "$str" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

ext_of() {
    local f="${1##*/}"
    echo "${f##*.}" | tr '[:upper:]' '[:lower:]'
}

type_hint() {
    case "$(ext_of "$1")" in
        jpg|jpeg|png|gif|heic|avif|bmp|tiff|webp) echo "image" ;;
        mp4|mkv|mov|avi|webm|wmv|m4v|flv|3gp)     echo "video" ;;
        mp3|wav|flac|ogg|aac|m4a|wma|opus)        echo "audio" ;;
        stl|obj|step|stp|3mf|scad|blend|fbx)      echo "model" ;;
        gcode|nc|cnc)                             echo "print" ;;
        pdf|doc|docx|xls|xlsx|ppt|pptx|odt|ods)   echo "document" ;;
        sh|py|js|go|cpp|c|h|rs|ps1|bat|java|php)  echo "code" ;;
        zip|7z|rar|tar|gz|bz2|xz|tgz)             echo "archive" ;;
        dmg|iso|img|toast)                        echo "diskimage" ;;
        srt|vtt|ass|ssa)                          echo "subtitle" ;;
        txt|md|csv|yaml|yml|json|xml|ini|cfg|conf|log|tex) echo "text" ;;
        *)                                        echo "other" ;;
    esac
}

get_file_size() {
    local file="$1"
    stat -c%s "$file" 2>/dev/null || echo 0
}

get_human_size() {
    local bytes="$1"
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$((bytes / 1073741824)) GB"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$((bytes / 1048576)) MB"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$((bytes / 1024)) KB"
    else
        echo "$bytes bytes"
    fi
}

extract_year() {
    local file="$1"
    local year

    # First try to extract from filename
    year=$(echo "$file" | grep -oE '\b(19|20)[0-9]{2}\b' | head -1 || true)
    if [[ -n "$year" && "$year" =~ ^(19|20)[0-9]{2}$ ]]; then
        echo "$year"
        return 0
    fi

    # Fallback to modification date
    if command -v python3 >/dev/null 2>&1; then
        year=$(python3 - "$file" <<'PY' 2>/dev/null || true
import os
import sys
import datetime

path = sys.argv[1]
try:
    ts = os.stat(path).st_mtime
    print(datetime.datetime.fromtimestamp(ts).year)
except (FileNotFoundError, OSError):
    print("")
PY
        )
    fi

    if [[ "$year" =~ ^(19|20)[0-9]{2}$ ]]; then
        echo "$year"
    else
        echo "null"
    fi
}

get_file_date() {
    local file="$1"
    stat -c %y "$file" 2>/dev/null | cut -d' ' -f1 || echo "$(date +%Y-%m-%d)"
}

extract_track_number() {
    local filename="$1"
    local track
    track=$(echo "$filename" | grep -oE '^[0-9]{1,3}' | head -1)
    if [[ -n "$track" ]]; then
        echo "$((10#$track))"
    else
        echo "null"
    fi
}

get_image_dimensions() {
    local file="$1"
    if command -v identify >/dev/null 2>&1; then
        identify -format "%wx%h" "$file" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

get_audio_duration() {
    local file="$1"
    if command -v ffprobe >/dev/null 2>&1; then
        ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | cut -d. -f1 || echo "null"
    else
        echo "null"
    fi
}

has_exif_data() {
    local file="$1"
    if command -v exiftool >/dev/null 2>&1; then
        exiftool "$file" 2>/dev/null | grep -q "EXIF" && echo "true" || echo "false"
    else
        echo "false"
    fi
}

strip_code_fences() {
    sed -E '1s/^```(json)?[[:space:]]*//; $s/[[:space:]]*```$//'
}

ai_call() {
    local prompt_file="$1"
    curl -sS --max-time 300 "$OLLAMA_HOST/api/generate" \
        -H "Content-Type: application/json" \
        -d @- <<EOF
{
  "model": "$OLLAMA_MODEL",
  "prompt": $(jq -Rs . < "$prompt_file"),
  "stream": false,
  "options": {
    "temperature": 0.1,
    "top_p": 0.85,
    "num_ctx": 8192
  }
}
EOF
}

# ---------- Robust JSON Validation ----------

validate_ai_response() {
    local json_file="$1"
    local item="$2"
    
    if ! jq -e '.' "$json_file" >/dev/null 2>&1; then
        echo "✗ Invalid JSON syntax for: $item" | tee -a "$LOG_FILE"
        return 1
    fi
    
    if ! jq -e '
        type=="object" and 
        (.bundle_type | type=="string") and 
        (.suggested_name | type=="string") and 
        (.recommended_path | type=="string") and 
        (.files | type=="array") and
        (.files | length >= 0)
    ' "$json_file" >/dev/null 2>&1; then
        echo "✗ Missing required fields for: $item" | tee -a "$LOG_FILE"
        return 1
    fi
    
    return 0
}

# ---------- Fallback Classification ----------

create_fallback_classification() {
    local item="$1"
    local is_folder="$2"
    local analysis_file="$3"
    
    # Use Python to safely generate JSON with proper escaping
    python3 - "$item" "$is_folder" "$analysis_file" <<'PYSCRIPT'
import sys
import json
import os
from pathlib import Path

item = sys.argv[1]
is_folder = sys.argv[2] == "true"
analysis_file = sys.argv[3]

base_name = os.path.basename(item)
file_ext = Path(item).suffix.lower().lstrip('.')

# Simple type detection
type_map = {
    'mp4': ('video', 'Video', 'RAM', '/data/library/RAM/Movies/Bundles/'),
    'mkv': ('video', 'Video', 'RAM', '/data/library/RAM/Movies/Bundles/'),
    'mp3': ('audio', 'Audio', 'RAM', '/data/library/RAM/Music/Albums/'),
    'flac': ('audio', 'Audio', 'RAM', '/data/library/RAM/Music/Albums/'),
    'jpg': ('image', 'Image', 'ROM', '/data/library/ROM/Photos/Albums/'),
    'png': ('image', 'Image', 'ROM', '/data/library/ROM/Photos/Albums/'),
    'pdf': ('document', 'Document', 'ROM', '/data/library/ROM/Documents/Sets/'),
    'dmg': ('diskimage', 'Software', 'RAM', '/data/library/RAM/Software/Applications/'),
}

file_type, category, storage_zone, recommended_path = type_map.get(
    file_ext, ('other', 'Other', 'RAM', '/data/library/RAM/Misc/Unsorted/')
)

# Clean name for JSON
clean_name = ''.join(c if c.isalnum() or c in '._- ' else '_' for c in base_name)
clean_name = '_'.join(clean_name.split())

try:
    file_size = os.path.getsize(item)
except:
    file_size = 0

result = {
    "source_path": item,
    "is_folder": is_folder,
    "bundle_type": "Standalone",
    "suggested_name": clean_name,
    "recommended_path": recommended_path,
    "confidence": 0.7,
    "bundle_coherence_score": 0.7,
    "reasoning": "Fallback classification based on file type analysis",
    "tags": ["fallback", category],
    "category": category,
    "storage_zone": storage_zone,
    "metadata": {
        "year": None,
        "file_count": 1,
        "dominant_category": file_type,
        "dominant_extension": file_ext,
        "file_type_distribution": {file_type: 1},
        "size_total": f"{file_size} bytes",
        "has_subfolders": False,
        "subfolder_names": [],
        "date_range": {
            "earliest": "2025-01-01",
            "latest": "2025-01-01"
        },
        "contains_sensitive_data": False,
        "detected_language": "None"
    },
    "files": [
        {
            "original_path": item,
            "original_name": base_name,
            "category": category,
            "rename_to": f"{clean_name}.{file_ext}",
            "recommended_path": recommended_path,
            "track_number": None,
            "file_size": file_size,
            "file_extension": file_ext,
            "keep_original": True,
            "needs_processing": False,
            "metadata": {
                "type": file_type
            }
        }
    ],
    "subfolder_plan": {
        "enabled": False,
        "map": {},
        "reasoning": "Fallback classification"
    },
    "actions": {
        "move": True,
        "rename": True,
        "extract_year": False,
        "create_subfolders": False,
        "generate_tags": False,
        "verify_duplicates": True,
        "preserve_structure": False,
        "flatten_hierarchy": False
    },
    "related_items": [],
    "warnings": ["Fallback classification used"],
    "recommendations": ["Review this classification manually"],
    "processing_notes": {
        "special_handling": "Fallback",
        "estimated_time_seconds": 10,
        "risk_level": "medium"
    }
}

print(json.dumps(result, ensure_ascii=False, indent=2))
PYSCRIPT
}

# ---------- Safe Increment Helper ----------
inc_assoc() {
    local -n _map="$1"
    local _key="$2"
    _map["$_key"]=$(( ${_map["$_key"]:-0} + 1 ))
}

# ---------- Advanced Folder Analysis ----------

analyze_folder_comprehensive() {
    local folder="$1"
    local analysis_file="$2"
    
    # Use Python for safe JSON generation with UTF-8 handling
    python3 - "$folder" "$analysis_file" <<'PYSCRIPT'
import sys
import json
import os
from pathlib import Path
from datetime import datetime

folder = sys.argv[1]
analysis_file = sys.argv[2]

files_data = []
file_types = {}
extensions = {}
total_size = 0
earliest_date = None
latest_date = None
subfolder_names = []

# Analyze files
file_count = 0
for root, dirs, files in os.walk(folder):
    # Get subfolders at first level only
    if root == folder:
        subfolder_names = [d for d in dirs if not d.startswith('.')]
    
    for file in files:
        if file.startswith('.') or file in ['.DS_Store', 'Thumbs.db', 'desktop.ini']:
            continue
        
        if file_count >= 100:
            break
        
        file_path = os.path.join(root, file)
        try:
            stat_info = os.stat(file_path)
            file_size = stat_info.st_size
            mod_time = datetime.fromtimestamp(stat_info.st_mtime)
            
            ext = Path(file).suffix.lower().lstrip('.')
            
            # Simple type detection
            type_map = {
                'mp4': 'video', 'mkv': 'video', 'avi': 'video', 'mov': 'video',
                'mp3': 'audio', 'flac': 'audio', 'wav': 'audio', 'ogg': 'audio',
                'jpg': 'image', 'jpeg': 'image', 'png': 'image', 'gif': 'image',
                'pdf': 'document', 'doc': 'document', 'docx': 'document',
                'dmg': 'diskimage', 'iso': 'diskimage',
            }
            file_type = type_map.get(ext, 'other')
            
            # Track stats
            file_types[file_type] = file_types.get(file_type, 0) + 1
            extensions[ext] = extensions.get(ext, 0) + 1
            total_size += file_size
            
            # Track dates
            file_date = mod_time.strftime('%Y-%m-%d')
            if earliest_date is None or file_date < earliest_date:
                earliest_date = file_date
            if latest_date is None or file_date > latest_date:
                latest_date = file_date
            
            rel_path = os.path.relpath(file_path, folder)
            
            files_data.append({
                "name": file,
                "path": rel_path,
                "extension": ext,
                "type": file_type,
                "size_bytes": file_size,
                "size_human": f"{file_size} bytes",
                "year": None,
                "modification_date": file_date,
                "metadata": {
                    "track_number": None,
                    "dimensions": "unknown",
                    "duration_seconds": None,
                    "has_exif": False,
                    "is_cover_art": False
                }
            })
            
            file_count += 1
            
        except Exception as e:
            continue
    
    if file_count >= 100:
        break

# Calculate coherence
max_type_count = max(file_types.values()) if file_types else 0
coherence_score = max_type_count / file_count if file_count > 0 else 0.0
dominant_category = max(file_types, key=file_types.get) if file_types else "other"
dominant_extension = max(extensions, key=extensions.get) if extensions else "other"

# Default dates
if earliest_date is None:
    earliest_date = datetime.now().strftime('%Y-%m-%d')
if latest_date is None:
    latest_date = datetime.now().strftime('%Y-%m-%d')

result = {
    "files": files_data,
    "summary": {
        "file_count": file_count,
        "total_size_bytes": total_size,
        "total_size_human": f"{total_size} bytes",
        "has_subfolders": len(subfolder_names) > 0,
        "subfolder_names": subfolder_names,
        "bundle_coherence_score": round(coherence_score, 2),
        "dominant_category": dominant_category,
        "dominant_extension": dominant_extension,
        "file_type_distribution": file_types,
        "extension_distribution": extensions,
        "date_range": {
            "earliest": earliest_date,
            "latest": latest_date
        },
        "year_range": {
            "earliest": None,
            "latest": None
        }
    }
}

with open(analysis_file, 'w', encoding='utf-8') as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
PYSCRIPT
}

# ---------- Library Context ----------

LIB_CONTEXT=$(cat << 'EOF'
LIBRARY STRUCTURE:

RAM/ (Temporary/Working Files)
├── Movies/
│   └── Bundles/ (Video collections, movie folders)
├── Music/
│   └── Albums/ (Music albums with audio files)
├── Software/
│   └── Applications/ (Software, disk images)
└── Misc/
    └── Unsorted/ (Mixed content bundles)

ROM/ (Permanent/Archive Files)
├── Photos/
│   └── Albums/ (Photo collections, image sets)
├── Documents/
│   └── Sets/ (Document collections)
├── Models/
│   └── Bundles/ (3D model projects)
├── Archives/ (Compressed files, backups)
└── Images/
    └── Screenshots/ (Individual screenshots)

BUNDLE DETECTION RULES:
- MusicAlbum: 70%+ audio files, often with track numbers, may have cover art
- PhotoAlbum: 70%+ image files, coherent theme, may have subfolders
- VideoBundle: 70%+ video files, movie/TV show collections
- DocumentSet: 70%+ documents, related content (manuals, reports)
- ModelBundle: 70%+ 3D model files, project assets
- MixedBundle: <70% any single type, varied content
- Standalone: Single files

PATH MAPPING:
- MusicAlbum → RAM/Music/Albums/Artist_Album_Year/
- PhotoAlbum → ROM/Photos/Albums/Album_Name/
- VideoBundle → RAM/Movies/Bundles/Title_Year/
- DocumentSet → ROM/Documents/Sets/Set_Name/
- ModelBundle → ROM/Models/Bundles/Project_Name/
- MixedBundle → RAM/Misc/Unsorted/Bundle_Name/
- Standalone files → appropriate category folders
EOF
)

# ---------- Collect Candidates ----------

declare -a CANDIDATES=()

# Top-level files
while IFS= read -r -d '' f; do
    CANDIDATES+=("$f")
done < <(find "$INBOX_DIR" -maxdepth 1 -type f ! -name '.*' -print0)

# Folders
while IFS= read -r -d '' d; do
    base="$(basename "$d")"
    [[ "$base" == .* ]] && continue
    CANDIDATES+=("$d") 
done < <(find "$INBOX_DIR" -mindepth 1 -maxdepth 2 -type d ! -name '.*' -print0)

echo "[step3] Found ${#CANDIDATES[@]} candidates." | tee -a "$LOG_FILE"

# ---------- Master Report ----------
echo "[" > "$REPORT_FILE"
FIRST=true

# ---------- Robust Classification Loop ----------
for item in "${CANDIDATES[@]}"; do
    rel_item="${item#$INBOX_DIR/}"
    echo "Analyzing: $rel_item" | tee -a "$LOG_FILE"

    # Skip empty directories
    if [[ -d "$item" ]] && ! find "$item" -type f ! -name '.*' | grep -q .; then
        echo "Skipping empty folder: $rel_item" | tee -a "$LOG_FILE"
        continue
    fi

    # Comprehensive item analysis
    ITEM_ANALYSIS_FILE="$TEMP_DIR/analysis_$(date +%s%N).json"
    is_folder=false
    [[ -d "$item" ]] && is_folder=true

    if [[ "$is_folder" == true ]]; then
        analyze_folder_comprehensive "$item" "$ITEM_ANALYSIS_FILE"
    else
        # Single file analysis using Python for safe JSON
        python3 - "$item" "$ITEM_ANALYSIS_FILE" <<'PYSCRIPT'
import sys
import json
import os
from pathlib import Path
from datetime import datetime

file_path = sys.argv[1]
output_file = sys.argv[2]

try:
    stat_info = os.stat(file_path)
    file_size = stat_info.st_size
    mod_time = datetime.fromtimestamp(stat_info.st_mtime)
    file_date = mod_time.strftime('%Y-%m-%d')
    
    base_name = os.path.basename(file_path)
    ext = Path(file_path).suffix.lower().lstrip('.')
    
    type_map = {
        'mp4': 'video', 'mkv': 'video', 'avi': 'video',
        'mp3': 'audio', 'flac': 'audio', 'wav': 'audio',
        'jpg': 'image', 'jpeg': 'image', 'png': 'image',
        'pdf': 'document', 'doc': 'document',
        'dmg': 'diskimage', 'iso': 'diskimage',
    }
    file_type = type_map.get(ext, 'other')
    
    result = {
        "files": [{
            "name": base_name,
            "path": base_name,
            "extension": ext,
            "type": file_type,
            "size_bytes": file_size,
            "size_human": f"{file_size} bytes",
            "year": None,
            "modification_date": file_date,
            "metadata": {
                "track_number": None,
                "dimensions": "unknown",
                "duration_seconds": None,
                "has_exif": False,
                "is_cover_art": False
            }
        }],
        "summary": {
            "file_count": 1,
            "total_size_bytes": file_size,
            "total_size_human": f"{file_size} bytes",
            "has_subfolders": False,
            "subfolder_names": [],
            "bundle_coherence_score": 1.0,
            "dominant_category": file_type,
            "dominant_extension": ext,
            "file_type_distribution": {file_type: 1},
            "extension_distribution": {ext: 1},
            "date_range": {
                "earliest": file_date,
                "latest": file_date
            },
            "year_range": {
                "earliest": None,
                "latest": None
            }
        }
    }
    
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
        
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYSCRIPT
    fi

    # Build precision prompt
    PROMPT_FILE="$TEMP_DIR/prompt_$(date +%s%N).txt"
    
    cat > "$PROMPT_FILE" << EOF
PRECISION CLASSIFICATION TASK:

ITEM TO CLASSIFY:
- Location: $rel_item
- Type: $( [[ "$is_folder" == "true" ]] && echo "FOLDER" || echo "FILE" )

DETAILED CONTENT ANALYSIS:
$(cat "$ITEM_ANALYSIS_FILE")

LIBRARY CONTEXT:
$LIB_CONTEXT

OUTPUT VALID JSON ONLY matching this schema - respond with ONLY the JSON, no explanations:

{
  "source_path": "$item",
  "is_folder": $is_folder,
  "bundle_type": "MusicAlbum or PhotoAlbum or VideoBundle or DocumentSet or ModelBundle or MixedBundle or Standalone",
  "suggested_name": "Clean_Name_Without_Extension",
  "recommended_path": "/data/library/RAM/Music/Albums/ or similar",
  "confidence": 0.95,
  "bundle_coherence_score": 0.85,
  "reasoning": "Brief explanation",
  "tags": ["tag1", "tag2"],
  "category": "Audio or Video or Image or Document or Other",
  "storage_zone": "RAM or ROM",
  "metadata": {},
  "files": [],
  "subfolder_plan": {"enabled": false, "map": {}, "reasoning": ""},
  "actions": {},
  "related_items": [],
  "warnings": [],
  "recommendations": [],
  "processing_notes": {}
}

RESPOND WITH VALID JSON ONLY.
EOF

    # Call AI with robust retry logic and fallback
    MAX_RETRIES=2
    RETRY_COUNT=0
    AI_SUCCESS=false
    AUGMENTED=""
    
    while [[ $RETRY_COUNT -lt $MAX_RETRIES && "$AI_SUCCESS" == false ]]; do
        RAW="$TEMP_DIR/raw_$(date +%s%N).txt"
        RESP_JSON="$TEMP_DIR/resp_$(date +%s%N).json"
        
        echo "AI attempt $((RETRY_COUNT + 1)) for: $rel_item" | tee -a "$LOG_FILE"
        
        if ai_call "$PROMPT_FILE" > "$RAW" 2>/dev/null; then
            if jq -er '.response' "$RAW" 2>/dev/null | strip_code_fences > "$RESP_JSON" 2>/dev/null; then
                if validate_ai_response "$RESP_JSON" "$rel_item"; then
                    AUGMENTED=$(jq --arg src "$item" '. + {source_path: $src}' "$RESP_JSON" 2>/dev/null)
                    AI_SUCCESS=true
                    echo "✓ Valid AI response for: $rel_item" | tee -a "$LOG_FILE"
                fi
            fi
        fi
        
        if [[ "$AI_SUCCESS" == false ]]; then
            ((RETRY_COUNT++))
            sleep 2
        fi
    done

    # Use fallback if AI failed
    if [[ "$AI_SUCCESS" == false ]]; then
        echo "⚠️ Using fallback classification for: $rel_item" | tee -a "$LOG_FILE"
        AUGMENTED=$(create_fallback_classification "$item" "$is_folder" "$ITEM_ANALYSIS_FILE")
    fi

    # Append to master report
    if [[ "$FIRST" == true ]]; then
        FIRST=false
        echo "$AUGMENTED" >> "$REPORT_FILE"
    else
        echo "," >> "$REPORT_FILE"
        echo "$AUGMENTED" >> "$REPORT_FILE"
    fi

    bundle_type=$(jq -r '.bundle_type' <<< "$AUGMENTED")
    suggested_name=$(jq -r '.suggested_name' <<< "$AUGMENTED")
    file_count=$(jq -r '.files | length' <<< "$AUGMENTED")
    confidence=$(jq -r '.confidence' <<< "$AUGMENTED")
    
    echo "CLASSIFIED: $rel_item → $suggested_name ($bundle_type, $file_count files, confidence: $confidence)" | tee -a "$LOG_FILE"
    
    # Cleanup temp files
    rm -f "$ITEM_ANALYSIS_FILE" "$PROMPT_FILE" "$RAW" "$RESP_JSON" 2>/dev/null || true
done

echo "]" >> "$REPORT_FILE"

# ---------- Final Summary ----------
echo "============================================================" | tee -a "$LOG_FILE"
echo "PRECISION CLASSIFICATION COMPLETE at $(date)" | tee -a "$LOG_FILE"
echo "Final Report: $REPORT_FILE" | tee -a "$LOG_FILE"

if command -v jq >/dev/null 2>&1; then
    echo "Classification Summary:" | tee -a "$LOG_FILE"
    jq -r '
        group_by(.bundle_type) | 
        map({type: .[0].bundle_type, count: length}) | 
        .[] | 
        "  \(.type): \(.count) items"
    ' "$REPORT_FILE" 2>/dev/null | tee -a "$LOG_FILE" || true
    
    TOTAL_ITEMS=$(jq -r 'length' "$REPORT_FILE" 2>/dev/null || echo "0")
    TOTAL_FILES=$(jq -r '[.[].files | length] | add' "$REPORT_FILE" 2>/dev/null || echo "0")
    echo "Total Items Classified: $TOTAL_ITEMS" | tee -a "$LOG_FILE"
    echo "Total Files in Items: $TOTAL_FILES" | tee -a "$LOG_FILE
fi
echo "============================================================" | tee -a "$LOG_FILE"
