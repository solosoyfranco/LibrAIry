#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# STEP 3 — AI-Powered File Classification
# Optimized for local Ollama models with robust error handling
# ============================================================

# Configuration
INBOX_DIR="/data/inbox"
LIBRARY_DIR="/data/library"
REPORTS_DIR="/data/reports"
REPORT_FILE="$REPORTS_DIR/step3_summary.json"
QUARANTINE_DIR="/data/quarantine"

# Ollama Configuration
OLLAMA_HOST="${OLLAMA_HOST:-http://192.168.1.94:11434}"
OLLAMA_MODEL_PRIMARY="${OLLAMA_MODEL:-llama3.1:8b}"
OLLAMA_MODEL_SECONDARY="${OLLAMA_MODEL_SECONDARY:-qwen2.5:7b}"

# AI Provider Configuration
USE_MULTI_AI="${USE_MULTI_AI:-false}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o-mini}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-3-5-haiku-20241022}"
CONFIDENCE_THRESHOLD=0.80

TEMP_DIR="/tmp/ai_step3"
LOG_FILE="$REPORTS_DIR/step3_ai.log"

# Performance settings
MAX_FILES_TO_ANALYZE=100
AI_TIMEOUT=120
MAX_AI_RETRIES=2
BATCH_SIZE=50

# Initialize
mkdir -p "$REPORTS_DIR" "$TEMP_DIR" "$QUARANTINE_DIR"
: > "$LOG_FILE"

trap 'ec=$?; echo "ERROR [step3] Failed at line $LINENO (exit $ec)"; cleanup_temp; exit $ec' ERR

cleanup_temp() {
    find "$TEMP_DIR" -type f -mmin +60 -delete 2>/dev/null || true
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "============================================================"
log "AI Classification Starting"
log "Primary Model: $OLLAMA_MODEL_PRIMARY @ $OLLAMA_HOST"
log "Multi-AI: $USE_MULTI_AI"
log "============================================================"

# ============================================================
# Core Analysis Functions
# ============================================================

analyze_item_with_python() {
    local item="$1"
    local output_file="$2"
    
    python3 - "$item" "$output_file" "$MAX_FILES_TO_ANALYZE" <<'PYTHON_ANALYZE'
import sys
import json
import os
from pathlib import Path
from datetime import datetime
from collections import defaultdict
import subprocess
import re

def get_file_type(ext):
    """Enhanced type detection with comprehensive extensions"""
    type_map = {
        # Audio
        'mp3': 'audio', 'flac': 'audio', 'wav': 'audio', 'ogg': 'audio',
        'aac': 'audio', 'm4a': 'audio', 'wma': 'audio', 'opus': 'audio',
        'alac': 'audio', 'ape': 'audio', 'aiff': 'audio', 'dsf': 'audio',
        # Video
        'mp4': 'video', 'mkv': 'video', 'avi': 'video', 'mov': 'video',
        'webm': 'video', 'wmv': 'video', 'm4v': 'video', 'flv': 'video',
        'mpg': 'video', 'mpeg': 'video', 'ts': 'video', 'm2ts': 'video',
        'vob': 'video', 'ogv': 'video', '3gp': 'video', 'mts': 'video',
        # Images
        'jpg': 'image', 'jpeg': 'image', 'png': 'image', 'gif': 'image',
        'heic': 'image', 'webp': 'image', 'bmp': 'image', 'tiff': 'image',
        'svg': 'image', 'raw': 'image', 'cr2': 'image', 'nef': 'image',
        'arw': 'image', 'dng': 'image', 'psd': 'image', 'ai': 'image',
        'eps': 'image', 'ico': 'image', 'tga': 'image',
        # Documents
        'pdf': 'document', 'doc': 'document', 'docx': 'document',
        'xls': 'document', 'xlsx': 'document', 'ppt': 'document',
        'pptx': 'document', 'odt': 'document', 'txt': 'document',
        'rtf': 'document', 'csv': 'document', 'ods': 'document',
        'odp': 'document', 'pages': 'document', 'numbers': 'document',
        'key': 'document', 'epub': 'document', 'mobi': 'document',
        # 3D Models
        'stl': 'model', 'obj': 'model', 'fbx': 'model', '3mf': 'model',
        'blend': 'model', 'step': 'model', 'stp': 'model', 'iges': 'model',
        'igs': 'model', 'dae': 'model', 'gltf': 'model', 'glb': 'model',
        'max': 'model', 'ma': 'model', 'mb': 'model', 'c4d': 'model',
        # Print files
        'gcode': 'print', 'nc': 'print', 'cnc': 'print', 'stl': 'print',
        # Archives
        'zip': 'archive', '7z': 'archive', 'rar': 'archive', 'tar': 'archive',
        'gz': 'archive', 'bz2': 'archive', 'xz': 'archive', 'tgz': 'archive',
        'tbz': 'archive', 'txz': 'archive', 'lz': 'archive', 'lzma': 'archive',
        # Disk Images
        'dmg': 'diskimage', 'iso': 'diskimage', 'img': 'diskimage',
        'toast': 'diskimage', 'vdi': 'diskimage', 'vmdk': 'diskimage',
        'vhd': 'diskimage', 'qcow2': 'diskimage',
        # Code
        'py': 'code', 'js': 'code', 'java': 'code', 'cpp': 'code',
        'c': 'code', 'h': 'code', 'sh': 'code', 'go': 'code',
        'rs': 'code', 'php': 'code', 'rb': 'code', 'swift': 'code',
        'kt': 'code', 'ts': 'code', 'jsx': 'code', 'tsx': 'code',
        'css': 'code', 'scss': 'code', 'html': 'code', 'xml': 'code',
        'json': 'code', 'yaml': 'code', 'yml': 'code', 'toml': 'code',
        'sql': 'code', 'r': 'code', 'bat': 'code', 'ps1': 'code',
        # Subtitles
        'srt': 'subtitle', 'vtt': 'subtitle', 'ass': 'subtitle',
        'ssa': 'subtitle', 'sub': 'subtitle', 'idx': 'subtitle',
        # Fonts
        'ttf': 'font', 'otf': 'font', 'woff': 'font', 'woff2': 'font',
        # Database
        'db': 'database', 'sqlite': 'database', 'sqlite3': 'database',
        'mdb': 'database', 'accdb': 'database',
        # Configuration
        'conf': 'config', 'cfg': 'config', 'ini': 'config', 'properties': 'config',
        'env': 'config', 'toml': 'config', 'plist': 'config',
        # Game files
        'rom': 'game', 'gba': 'game', 'nds': 'game', 'sfc': 'game',
        'nes': 'game', 'n64': 'game', 'z64': 'game', 'sav': 'game',
    }
    return type_map.get(ext.lower(), 'other')

def extract_year_from_name(name):
    """Extract year from filename"""
    match = re.search(r'\b(19\d{2}|20\d{2})\b', name)
    return int(match.group(1)) if match else None

def extract_metadata(file_path, file_type, is_cover_art):
    """Extract metadata using external tools"""
    metadata = {}
    try:
        if file_type in ['audio', 'video']:
            ff_out = subprocess.check_output(
                ['ffprobe', '-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', file_path],
                stderr=subprocess.STDOUT, timeout=10
            )
            ff_data = json.loads(ff_out)
            duration = float(ff_data['format'].get('duration', 0))
            bit_rate = int(ff_data['format'].get('bit_rate', 0)) // 1000 if 'bit_rate' in ff_data['format'] else None
            
            if file_type == 'video' and 'streams' in ff_data:
                video_stream = next((s for s in ff_data['streams'] if s.get('codec_type') == 'video'), {})
                width = video_stream.get('width')
                height = video_stream.get('height')
                resolution = f"{width}x{height}" if width and height else None
            else:
                resolution = None
            
            metadata = {
                'duration_seconds': int(duration) if duration else None,
                'bitrate_kbps': bit_rate,
                'resolution': resolution
            }
        elif file_type == 'image':
            ex_out = subprocess.check_output(['exiftool', '-j', file_path], stderr=subprocess.STDOUT, timeout=5)
            ex_data = json.loads(ex_out)[0]
            width = ex_data.get('ImageWidth')
            height = ex_data.get('ImageHeight')
            dimensions = f"{width}x{height}" if width and height else None
            
            gps_lat = ex_data.get('GPSLatitude')
            gps_lon = ex_data.get('GPSLongitude')
            location = f"{gps_lat}, {gps_lon}" if gps_lat and gps_lon else None
            
            has_exif = any(k.startswith('EXIF') or k in ['GPSLatitude', 'GPSLongitude', 'DateTimeOriginal'] for k in ex_data.keys())
            
            metadata = {
                'type': 'image',
                'dimensions': dimensions,
                'has_exif': has_exif,
                'is_cover_art': is_cover_art,
                'date_taken': ex_data.get('DateTimeOriginal') or ex_data.get('CreateDate'),
                'orientation': ex_data.get('Orientation'),
                'camera_model': ex_data.get('Model'),
                'camera_make': ex_data.get('Make'),
                'gps_location': location,
                'city': ex_data.get('City'),
                'country': ex_data.get('Country'),
                'keywords': ex_data.get('Keywords', [])
            }
    except Exception:
        pass
    return metadata

def analyze_folder(folder_path, max_files):
    """Comprehensive folder analysis"""
    files_data = []
    file_types = defaultdict(int)
    extensions = defaultdict(int)
    years = []
    total_size = 0
    dates = []
    subfolder_names = []
    track_numbers = []
    
    file_count = 0
    
    for root, dirs, files in os.walk(folder_path):
        if root == folder_path:
            subfolder_names = [d for d in sorted(dirs) if not d.startswith('.')]
        
        for filename in sorted(files):
            if filename.startswith('.') or filename in {'.DS_Store', 'Thumbs.db', 'desktop.ini'}:
                continue
            
            if file_count >= max_files:
                break
            
            file_path = os.path.join(root, filename)
            
            try:
                stat_info = os.stat(file_path)
                file_size = stat_info.st_size
                mod_time = datetime.fromtimestamp(stat_info.st_mtime)
                
                path_obj = Path(filename)
                ext = path_obj.suffix.lower().lstrip('.')
                stem = path_obj.stem
                
                file_type = get_file_type(ext)
                file_types[file_type] += 1
                extensions[ext] += 1
                total_size += file_size
                
                file_date = mod_time.strftime('%Y-%m-%d')
                dates.append(file_date)
                
                year = extract_year_from_name(stem)
                if year:
                    years.append(year)
                
                track_match = re.match(r'^(\d{1,3})', stem)
                track_number = int(track_match.group(1)) if track_match else None
                if track_number:
                    track_numbers.append(track_number)
                
                is_cover = any(kw in stem.lower() for kw in ['cover', 'folder', 'front', 'album', 'artwork'])
                
                rel_path = os.path.relpath(file_path, folder_path)
                
                metadata = extract_metadata(file_path, file_type, is_cover)
                
                files_data.append({
                    "name": filename,
                    "path": rel_path,
                    "extension": ext,
                    "type": file_type,
                    "size_bytes": file_size,
                    "size_human": format_size(file_size),
                    "year": year,
                    "modification_date": file_date,
                    "track_number": track_number,
                    "is_cover_art": is_cover,
                    "metadata": metadata
                })
                
                file_count += 1
                
            except (OSError, IOError):
                continue
        
        if file_count >= max_files:
            break
    
    max_type_count = max(file_types.values()) if file_types else 0
    coherence = round(max_type_count / file_count, 2) if file_count > 0 else 0.0
    dominant_type = max(file_types, key=file_types.get) if file_types else "other"
    dominant_ext = max(extensions, key=extensions.get) if extensions else "none"
    
    has_track_numbers = len(track_numbers) > 0
    is_sequential = False
    if len(track_numbers) >= 3:
        sorted_tracks = sorted(set(track_numbers))
        is_sequential = all(sorted_tracks[i] + 1 == sorted_tracks[i + 1] 
                          for i in range(min(5, len(sorted_tracks) - 1)))
    
    return {
        "files": files_data[:50],
        "summary": {
            "file_count": file_count,
            "total_size_bytes": total_size,
            "total_size_human": format_size(total_size),
            "has_subfolders": len(subfolder_names) > 0,
            "subfolder_names": subfolder_names[:10],
            "bundle_coherence_score": coherence,
            "dominant_category": dominant_type,
            "dominant_extension": dominant_ext,
            "file_type_distribution": dict(file_types),
            "extension_distribution": dict(extensions),
            "date_range": {
                "earliest": min(dates) if dates else None,
                "latest": max(dates) if dates else None
            },
            "year_range": {
                "earliest": min(years) if years else None,
                "latest": max(years) if years else None
            },
            "has_track_numbers": has_track_numbers,
            "is_sequential_tracks": is_sequential,
            "track_count": len(track_numbers)
        }
    }

def analyze_file(file_path):
    """Single file analysis"""
    try:
        stat_info = os.stat(file_path)
        file_size = stat_info.st_size
        mod_time = datetime.fromtimestamp(stat_info.st_mtime)
        
        path_obj = Path(file_path)
        filename = path_obj.name
        ext = path_obj.suffix.lower().lstrip('.')
        stem = path_obj.stem
        
        file_type = get_file_type(ext)
        year = extract_year_from_name(stem)
        file_date = mod_time.strftime('%Y-%m-%d')
        
        is_cover = any(kw in stem.lower() for kw in ['cover', 'folder', 'front', 'album', 'artwork'])
        
        metadata = extract_metadata(file_path, file_type, is_cover)
        
        return {
            "files": [{
                "name": filename,
                "path": filename,
                "extension": ext,
                "type": file_type,
                "size_bytes": file_size,
                "size_human": format_size(file_size),
                "year": year,
                "modification_date": file_date,
                "track_number": None,
                "is_cover_art": is_cover,
                "metadata": metadata
            }],
            "summary": {
                "file_count": 1,
                "total_size_bytes": file_size,
                "total_size_human": format_size(file_size),
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
                    "earliest": year,
                    "latest": year
                },
                "has_track_numbers": False,
                "is_sequential_tracks": False,
                "track_count": 0
            }
        }
    except Exception as e:
        raise

def format_size(bytes_size):
    """Human-readable file size"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_size < 1024.0:
            return f"{bytes_size:.1f} {unit}"
        bytes_size /= 1024.0
    return f"{bytes_size:.1f} PB"

if __name__ == "__main__":
    item_path = sys.argv[1]
    output_file = sys.argv[2]
    max_files = int(sys.argv[3])
    
    try:
        if os.path.isdir(item_path):
            result = analyze_folder(item_path, max_files)
        else:
            result = analyze_file(item_path)
        
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
        
    except Exception as e:
        print(f"Analysis error: {e}", file=sys.stderr)
        sys.exit(1)
PYTHON_ANALYZE
}

merge_with_python() {
    local analysis_file="$1"
    local bundle_file="$2"
    local item="$3"
    local is_folder="$4"
    local output_file="$5"
    
    python3 - "$analysis_file" "$bundle_file" "$item" "$is_folder" "$output_file" <<'PYTHON_MERGE'
import sys
import json
import os
import re
from pathlib import Path

analysis_file = sys.argv[1]
bundle_file = sys.argv[2]
item = sys.argv[3]
is_folder = sys.argv[4] == 'true'
output_file = sys.argv[5]

with open(analysis_file, 'r') as f:
    analysis = json.load(f)

with open(bundle_file, 'r') as f:
    bundle = json.load(f)

def sanitize_name(name):
    # Remove affiliate/quality tags
    name = re.sub(r'\[\w+\.\w+\]', '', name)  # [YTS.MX]
    name = re.sub(r'Beats⭐', '', name)
    name = re.sub(r'\[?WEBRip\]?', '', name, flags=re.I)
    name = re.sub(r'\[?BluRay\]?', '', name, flags=re.I)
    name = re.sub(r'\[?DVD\d?\]?', '', name, flags=re.I)
    
    # Replace special chars with single space first
    name = re.sub(r'[^\w\s-]', ' ', name)
    
    # Replace multiple spaces/dashes with single space
    name = re.sub(r'[\s-]+', ' ', name)
    
    # Now convert spaces to underscores
    name = name.replace(' ', '_')
    
    # Remove any remaining multiple underscores
    name = re.sub(r'_+', '_', name)
    
    # Trim underscores from ends
    name = name.strip('_')
    
    return name if name else 'unnamed'

def detect_video_context(filename, folder_name):
    """Detect concert/live vs official music video"""
    name_lower = (filename + ' ' + folder_name).lower()
    
    concert_keywords = ['live', 'concert', 'tour', 'festival', 'show', 'performance', 'arena', 'stadium']
    if any(kw in name_lower for kw in concert_keywords):
        return 'concert', ['live', 'concert']
    
    mv_keywords = ['official video', 'music video', 'mv', 'official mv', 'lyric video']
    if any(kw in name_lower for kw in mv_keywords):
        return 'music_video', ['official', 'music-video']
    
    return 'music_video', []

bundle['suggested_name'] = sanitize_name(bundle['suggested_name'])
bundle['bundle_coherence_score'] = analysis['summary']['bundle_coherence_score']

year = analysis['summary']['year_range']['latest'] if analysis['summary']['year_range']['latest'] else "null"
detected_language = "English" if analysis['summary']['dominant_category'] in ['audio', 'document'] else "None"

bundle['metadata'] = {
    "year": year,
    "file_count": analysis['summary']['file_count'],
    "dominant_category": analysis['summary']['dominant_category'],
    "dominant_extension": analysis['summary']['dominant_extension'],
    "file_type_distribution": analysis['summary']['file_type_distribution'],
    "size_total": analysis['summary']['total_size_human'],
    "has_subfolders": analysis['summary']['has_subfolders'],
    "subfolder_names": analysis['summary']['subfolder_names'],
    "contains_sensitive_data": False,
    "detected_language": detected_language
}

zone_map = {
    'PhotoAlbum': 'ROM', 'Screenshot': 'ROM', 'DocumentSet': 'ROM', 'ModelBundle': 'ROM',
    'MusicAlbum': 'RAM', 'MusicVideo': 'RAM', 'Karaoke': 'RAM', 'VideoBundle': 'RAM',
    'TVShow': 'RAM', 'Game': 'RAM', 'Tutorial': 'RAM',
    'Standalone': 'RAM', 'MixedBundle': 'RAM'
}
bundle['storage_zone'] = zone_map.get(bundle['bundle_type'], bundle.get('storage_zone', 'RAM'))

os_ = bundle.get('os', 'unknown')
if os_ == 'unknown' or os_ is None:
    ext = analysis['summary']['dominant_extension']
    if ext == 'dmg':
        os_ = 'macos'
    elif ext == 'exe':
        os_ = 'windows'
    elif ext == 'deb':
        os_ = 'linux'
    elif ext == 'apk':
        os_ = 'android'
    bundle['os'] = os_

usecase = bundle.get('usecase', 'unsorted')
genre = bundle.get('genre', 'Unknown') if bundle.get('genre') else 'Unknown'
subcategory = bundle.get('subcategory', 'Unsorted') if bundle.get('subcategory') else 'Unsorted'

bundle_type = bundle['bundle_type']
# Common sense overrides based on file names
if bundle_type in ['MusicAlbum', 'PhotoAlbum']:
    # Check if all images are screenshots
    image_files = [f for f in analysis['files'] if f['type'] == 'image']
    if image_files and all('screenshot' in f['name'].lower() or 'screen shot' in f['name'].lower() for f in image_files):
        bundle_type = 'Screenshot'
        bundle['bundle_type'] = 'Screenshot'
        category = 'Image'
        bundle['category'] = 'Image'

# Detect if video content should be MusicVideo
if bundle_type == 'MusicAlbum' and 'video' in analysis['summary']['file_type_distribution']:
    video_count = analysis['summary']['file_type_distribution'].get('video', 0)
    audio_count = analysis['summary']['file_type_distribution'].get('audio', 0)
    if video_count > 0 and video_count >= audio_count:
        bundle_type = 'MusicVideo'
        bundle['bundle_type'] = 'MusicVideo'
        category = 'Video'
        bundle['category'] = 'Video'
        # Detect concert context
        folder_name = os.path.basename(item)
        first_video = next((f for f in analysis['files'] if f['type'] == 'video'), None)
        if first_video:
            name_lower = (first_video['name'] + ' ' + folder_name).lower()
            if any(kw in name_lower for kw in ['live', 'concert', 'tour', 'dvd', 'special']):
                bundle['video_context'] = 'concert'
                bundle['tags'].extend(['live', 'concert'])

# Improve genre/subcategory inference for documents
# Define category early to prevent NameError
category = bundle.get('category', 'Other')
zone = bundle.get('storage_zone', 'RAM')

# Improve genre/subcategory inference for documents
if category == 'Document':
    item_name_lower = os.path.basename(item).lower()
    if any(kw in item_name_lower for kw in ['coding', 'interview', 'programming', 'algorithm']):
        if bundle_type == 'Standalone':
            bundle_type = 'Tutorial'
            bundle['bundle_type'] = 'Tutorial'
        genre = 'Programming'
        bundle['genre'] = 'Programming'
        subcategory = 'Programming'
    elif any(kw in item_name_lower for kw in ['book', 'ebook', 'guide']):
        if bundle_type == 'Standalone':
            bundle_type = 'DocumentSet'
            bundle['bundle_type'] = 'DocumentSet'
        subcategory = 'Books'

if bundle_type == 'MusicAlbum':
    bundle['recommended_path'] = f"/data/library/{zone}/Music/{genre}/Albums/"
elif bundle_type == 'MusicVideo':
    folder_name = os.path.basename(item)
    first_video = next((f for f in analysis['files'] if f['type'] == 'video'), None)
    if first_video:
        context, context_tags = detect_video_context(first_video['name'], folder_name)
        bundle['video_context'] = context
        bundle['tags'].extend(context_tags)
        
        if context == 'concert':
            bundle['recommended_path'] = f"/data/library/{zone}/MusicVideos/{genre}/LivePerformances/"
        else:
            bundle['recommended_path'] = f"/data/library/{zone}/MusicVideos/{genre}/Official/"
    else:
        bundle['recommended_path'] = f"/data/library/{zone}/MusicVideos/{genre}/"
elif bundle_type == 'Karaoke':
    bundle['recommended_path'] = f"/data/library/{zone}/Music/Karaoke/{genre}/"
elif bundle_type == 'VideoBundle':
    bundle['recommended_path'] = f"/data/library/{zone}/Movies/{genre}/"
elif bundle_type == 'TVShow':
    bundle['recommended_path'] = f"/data/library/{zone}/Shows/{genre}/"
elif bundle_type == 'PhotoAlbum':
    bundle['recommended_path'] = f"/data/library/{zone}/Photos/{subcategory}/"
elif bundle_type == 'Screenshot':
    bundle['recommended_path'] = f"/data/library/{zone}/Images/Screenshots/"
elif bundle_type == 'ModelBundle':
    bundle['recommended_path'] = f"/data/library/{zone}/3dModels/Projects/"
elif bundle_type == 'DocumentSet':
    # Use subcategory for documents
    if subcategory and subcategory != 'Unsorted':
        bundle['recommended_path'] = f"/data/library/{zone}/Documents/{subcategory}/"
    else:
        bundle['recommended_path'] = f"/data/library/{zone}/Documents/Sets/"
elif bundle_type == 'Tutorial':
    # Use genre for tutorials
    if genre and genre != 'Unknown':
        bundle['recommended_path'] = f"/data/library/{zone}/Tutorials/{genre}/"
    else:
        bundle['recommended_path'] = f"/data/library/{zone}/Tutorials/"
elif bundle_type == 'Game':
    platform = bundle.get('platform', 'Unknown')
    bundle['recommended_path'] = f"/data/library/{zone}/Games/{platform}/"
elif category == 'Software' or (bundle_type == 'Standalone' and 'software' in bundle.get('tags', [])):
    bundle['recommended_path'] = f"/data/library/{zone}/Software/{os_}/{usecase}/"
elif category == 'Archive':
    bundle['recommended_path'] = f"/data/library/{zone}/Archives/"
elif category == 'Code':
    bundle['recommended_path'] = f"/data/library/ROM/Misc/Code/"
else:
    bundle['recommended_path'] = f"/data/library/{zone}/Misc/Unsorted/"

if is_folder:
    bundle['recommended_path'] += bundle['suggested_name'] + '/'

if not bundle['recommended_path'].endswith('/'):
    bundle['recommended_path'] += '/'

files = []
for f in analysis['files']:
    file_category = f['type'].capitalize()
    ext = f['extension']
    name = f['name']
    stem = Path(name).stem
    track_number = f['track_number']
    is_cover_art = f['is_cover_art']
    
    if track_number is not None:
        track_match = re.match(r'^(\d{1,3})\s*[-._]?\s*', stem)
        if track_match and int(track_match.group(1)) == track_number:
            stem = stem[track_match.end():]
    
    sanitized_stem = sanitize_name(stem)
    if is_cover_art:
        rename_to = 'cover.' + ext if ext else 'cover'
        keep_original = True
    else:
        if track_number is not None:
            rename_to = f"{track_number:02d}_{sanitized_stem}.{ext}" if ext else f"{track_number:02d}_{sanitized_stem}"
        else:
            rename_to = f"{sanitized_stem}.{ext}" if ext else sanitized_stem
        keep_original = False
    
    if bundle_type == 'Standalone' and len(analysis['files']) == 1:
        rename_to = bundle['suggested_name'] + '.' + ext if ext else bundle['suggested_name']
    
    recommended_path = bundle['recommended_path']
    
    if bundle['subfolder_plan'].get('enabled', False):
        subfolder = bundle['subfolder_plan']['map'].get(file_category, '')
        if bundle_type == 'MusicAlbum' and file_category == 'Image':
            subfolder = 'Covers'
        if subfolder and not (
            (file_category == 'Audio' and bundle_type in ['MusicAlbum', 'Karaoke']) or
            (file_category == 'Video' and bundle_type in ['VideoBundle', 'MusicVideo', 'TVShow'])
        ):
            recommended_path += subfolder + '/'
    
    file_entry = {
        "original_path": os.path.join(item, f['path']),
        "original_name": name,
        "category": file_category,
        "rename_to": rename_to,
        "recommended_path": recommended_path,
        "track_number": track_number,
        "file_size": f['size_human'],
        "file_extension": ext,
        "keep_original": keep_original,
        "needs_processing": False,
        "metadata": f['metadata']
    }
    files.append(file_entry)

bundle['files'] = files

recommendations = bundle.get('recommendations', [])
if bundle_type == 'MusicAlbum' and 'image' not in analysis['summary']['file_type_distribution']:
    recommendations.append("Download cover art from internet")
if bundle_type in ['VideoBundle', 'TVShow'] and 'subtitle' not in analysis['summary']['file_type_distribution']:
    recommendations.append("Download subtitles from internet")
if year == "null":
    recommendations.append("Extract year from internet based on file name")
bundle['recommendations'] = recommendations

bundle.setdefault('related_items', [])
bundle.setdefault('warnings', [])
bundle.setdefault('processing_notes', {
    "special_handling": "None",
    "estimated_time_seconds": 5,
    "risk_level": "low"
})
bundle['actions'].setdefault('extract_year', bool(year != "null"))

item_basename = os.path.basename(item)
if '#' in item_basename:
    tag = item_basename.split('#')[-1].strip()
    bundle['tags'].append(f"project:{tag}")
    bundle['warnings'].append(f"Item tagged with project: {tag}")

with open(output_file, 'w', encoding='utf-8') as f:
    json.dump(bundle, f, ensure_ascii=False, indent=2)
PYTHON_MERGE
}

# ============================================================
# AI Interaction
# ============================================================

create_ai_prompt() {
    local item="$1"
    local is_folder="$2"
    local analysis_json="$3"
    local output_file="$4"
    
    cat > "$output_file" << EOF
You are a file organization AI. Classify this item and return ONLY valid JSON.

ITEM: $(basename "$item")
TYPE: $( [[ "$is_folder" == "true" ]] && echo "FOLDER" || echo "FILE" )

ANALYSIS:
$(cat "$analysis_json")

LIBRARY STRUCTURE:
RAM/:
  - Music/Genre/Albums/ → music albums
  - Music/Genre/Singles/ → single tracks
  - Music/Genre/Live/ → live recordings
  - Music/Karaoke/Genre/ → karaoke tracks
  - MusicVideos/Genre/Official/ → official music videos
  - MusicVideos/Genre/LivePerformances/ → concerts/live
  - Movies/Genre/ → movies
  - Shows/Genre/ → TV shows
  - Games/Platform/ → game files
  - Tutorials/ → course materials
  - Software/OS/UseCase/ → applications
  - 3dModels/Projects/ → 3D model projects
  - Misc/Unsorted/ → unclassified

ROM/:
  - Photos/Subcategory/ → photo albums (Travel, Events, Personal, Nature)
  - Images/Screenshots/ → screenshots
  - Images/Wallpapers/ → wallpapers
  - Documents/Sets/ → document collections
  - Archives/ → compressed backups
  - Backups/ → system backups
  - Private/ → sensitive files
  - Tags/ProjectName/ → tagged projects (#tag)
  - Misc/Code/ → source code
  - Misc/Configs/ → configuration files

BUNDLE TYPES:
- MusicAlbum: 70%+ audio with track numbers
- MusicVideo: video music content (detect concert vs official)
- Karaoke: karaoke audio tracks
- TVShow: TV series episodes
- VideoBundle: movies/films
- PhotoAlbum: 70%+ images (infer subcategory from EXIF GPS/keywords/names: Travel, Events, Personal, Nature, Screenshots)
- Screenshot: computer screenshots
- DocumentSet: 70%+ documents
- ModelBundle: 3D model files
- Game: game ROMs/files
- Tutorial: educational content
- Standalone: single file
- MixedBundle: mixed content

SPECIAL RULES:
- If '#' in name: belongs to project, route to ROM/Tags/<project_name>
- For photos: Use EXIF GPS, keywords, camera, dates to determine subcategory
- For music videos: Detect 'live', 'concert' → LivePerformances, otherwise → Official
- Always extract and append year if present in name/analysis
- Extract genre from name/context (Rock, Pop, Comedy, Action, etc.)
- For suggested_name: Keep as much of ITEM name as possible, including anniversaries, quality (e.g., 320_kbps), but remove junk like Beats⭐
- Infer genre/subcategory from name keywords: e.g., 'coding/interview/programming' → genre='Programming', bundle_type='Tutorial'; 'book/guide' → subcategory='Books'; avoid 'Unknown/Unsorted' by using 'General' if unsure.
- If dominant_category is 'video' but content is music-related (e.g., concert, band name like Queen, live performance), classify as MusicVideo, not MusicAlbum. Detect concert/live vs official from names/keywords.
- For genre: Use a single genre without slashes, e.g., "RnB" or "Action". If multiple, choose the primary one.

COMMON SENSE RULES:
- If filename contains 'screenshot' or 'screen shot' → bundle_type='Screenshot', route to ROM/Images/Screenshots/
- If filename contains 'coding'/'interview'/'programming' and is document → bundle_type='Tutorial', genre='Programming'
- If filename contains 'book'/'ebook'/'guide' and is document → bundle_type='DocumentSet', subcategory='Books'
- If dominant_category is 'video' AND (folder name contains band/artist OR has 'concert'/'live'/'DVD') → bundle_type='MusicVideo', NOT MusicAlbum
- If folder only contains images with 'screenshot' in names → bundle_type='Screenshot', NOT PhotoAlbum/MusicAlbum
- Avoid 'Unknown'/'Unsorted' - use context clues: 'interview' → genre='Career', 'coding' → genre='Programming', etc.
- For DocumentSet: infer subcategory from keywords: 'coding'/'programming' → 'Programming', 'interview'/'career' → 'Career', 'business' → 'Business'

IMPORTANT INSTRUCTIONS:
- For suggested_name: Keep as much of ITEM name as possible - DON'T over-strip. Remove only junk tags like [YTS.MX], Beats⭐, quality specs. Keep words like "20th Anniversary", "Questions and Solutions". Avoid multiple underscores.
- For genre: NEVER use "Unknown" - infer from context: 'Rock', 'RnB', 'Programming', 'Career', 'Action', 'Comedy', 'General'. Use single genre (no slashes like "RnB/Soul" - just "RnB").
- For subcategory (DocumentSet/PhotoAlbum): NEVER use "Unsorted" - infer: 'Programming', 'Books', 'Career', 'Personal', 'Travel', 'Events', 'General'.
- If dominant_category='video' but content is music (DVD, concert, band name) → MusicVideo, not MusicAlbum
- If images named 'screenshot' → Screenshot bundle, not PhotoAlbum

RESPOND WITH ONLY JSON:
{
  "bundle_type": (one of: MusicAlbum, MusicVideo, Karaoke, VideoBundle, TVShow, PhotoAlbum, Screenshot, DocumentSet, ModelBundle, Game, Tutorial, Standalone, MixedBundle),
  "suggested_name": "Suggested_Name_Here",
  "recommended_path": "/data/library/RAM (or ROM)/.../",
  "confidence": 0.00 to 1.0,
  "reasoning": "Detailed explanation",
  "tags": ["genre", "quality", "live", "official", ...],
  "category": (one of: Music, Video, MusicVideo, Karaoke, Photo, Document, Model, Game, Software, Archive, Code, Other, Tutorial, Midi, ... ),",
  "storage_zone": "RAM" or "ROM",
  "genre": "Rock" or "Pop" or "Action" or "Programming" or "General" or ...,
  "subcategory": "Events" or "Personal" or "Nature" or "Books" or "Screenshots" or ...,
  "os": "windows" or "macos" or "linux" or "android" or "ios" or "unknown",
  "usecase": "gaming" or "productivity" or "development" or "entertainment" or "unsorted" or ...,
  "platform": "PC" or "Mac" or "Linux" or "Android" or "iOS" or "Nintendo" or "PlayStation" or ...,
  "video_context": "concert" or "music_video" or "live" or "movie" or ...,
  "subfolder_plan": {
    "enabled": true,
    "map": {"Image": "Covers"},
    "reasoning": "Explanation for subfolder plan"
  },
  "actions": {
    "move": true | false,
    "rename": true | false,
    "extract_year": true | false,
    "create_subfolders": true | false,
    "generate_tags": true | false,
    "verify_duplicates": true | false,
    "preserve_structure": true | false,
    "flatten_hierarchy": true | false
  },
  "warnings": ["warning message 1", "warning message 2", ...],
  "recommendations": ["recommendation 1", "recommendation 2", ...],
  "processing_notes": {
    "special_handling": ("None" or "High Risk" or "Requires Review" or ...),
    "estimated_time_seconds": integer,
    "risk_level": "low" or "medium" or "high"
  },
  "bundle_coherence_score": 0.00 to 1.0,
  "metadata": {
    "year": (extracted year or "null"),
    "file_count": integer,
    "dominant_category": "video" or "audio" or "image" or "document" or ...,
    "dominant_extension": "dmg" or "mp4" or "mp3" or ...,
    "file_type_distribution": {
      "type1": count1,
      "type2": count2, ...
    },
    "size_total": "KB/MB/GB/etc.",
    "has_subfolders": true | false,
    "subfolder_names": ["subfolder1", "subfolder2", ...],
    "contains_sensitive_data": true | false,
    "detected_language": "English" or "Spanish" or "None" or ...
  },
  "files": [
    {
      "original_path": "/data/inbox/name_of_file_or_subfolder/name_of_file.extension",
      "original_name": "name_of_file.extension",
      "category": "Image" or "Audio" or "Video" or "Document" or "Model" or "Game" or "Other" or ...,
      "rename_to": "Renamed_File.extension",
      "recommended_path": "/data/library/RAM (or ROM)/.../",
      "track_number": null or integer,
      "file_size": "KB/MB/GB/etc.",
      "file_extension": "extension",
      "keep_original": true | false,
      "needs_processing": true | false,
      "metadata": { ... extracted metadata ...}
    }
  ],
  "related_items": ["related_item_1", "related_item_2", ...],
  "source_path": "/data/inbox/name_of_file_or_subfolder",
  "is_folder": true | false
}
EOF
}

call_ollama_ai() {
    local prompt_file="$1"
    local output_file="$2"
    local model="${3:-$OLLAMA_MODEL_PRIMARY}"
    
    curl -sS --max-time "$AI_TIMEOUT" "$OLLAMA_HOST/api/generate" \
        -H "Content-Type: application/json" \
        -d @- <<EOF 2>/dev/null > "$output_file"
{
  "model": "$model",
  "prompt": $(jq -Rs . < "$prompt_file"),
  "stream": false,
  "options": {
    "temperature": 0.0,
    "top_p": 0.9,
    "num_ctx": 8192
  }
}
EOF
}

call_openai_ai() {
    local prompt_file="$1"
    local output_file="$2"
    
    if [[ -z "$OPENAI_API_KEY" ]]; then
        return 1
    fi
    
    curl -sS --max-time "$AI_TIMEOUT" https://api.openai.com/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d @- <<EOF > "$output_file" 2>/dev/null
{
  "model": "$OPENAI_MODEL",
  "messages": [{"role": "user", "content": $(jq -Rs . < "$prompt_file")}],
  "temperature": 0.0
}
EOF
}

call_anthropic_ai() {
    local prompt_file="$1"
    local output_file="$2"
    
    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
        return 1
    fi
    
    curl -sS --max-time "$AI_TIMEOUT" https://api.anthropic.com/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d @- <<EOF > "$output_file" 2>/dev/null
{
  "model": "$ANTHROPIC_MODEL",
  "max_tokens": 4096,
  "temperature": 0.0,
  "messages": [{"role": "user", "content": $(jq -Rs . < "$prompt_file")}]
}
EOF
}

extract_json_from_response() {
    local response_file="$1"
    local output_file="$2"
    
    jq -r '.response' "$response_file" 2>/dev/null | \
        sed -E '1s/^```(json)?[[:space:]]*//; $s/[[:space:]]*```$//' > "$output_file"
}

extract_openai_response() {
    local response_file="$1"
    local output_file="$2"
    
    jq -r '.choices[0].message.content' "$response_file" 2>/dev/null | \
        sed -E '1s/^```(json)?[[:space:]]*//; $s/[[:space:]]*```$//' > "$output_file"
}

extract_anthropic_response() {
    local response_file="$1"
    local output_file="$2"
    
    jq -r '.content[0].text' "$response_file" 2>/dev/null | \
        sed -E '1s/^```(json)?[[:space:]]*//; $s/[[:space:]]*```$//' > "$output_file"
}

validate_ai_json() {
    local json_file="$1"
    
    jq -e '
        type == "object" and
        has("bundle_type") and
        has("suggested_name") and
        has("recommended_path") and
        (.bundle_type | type == "string") and
        (.suggested_name | type == "string") and
        (.recommended_path | type == "string")
    ' "$json_file" >/dev/null 2>&1
}

# ============================================================
# Fallback Classification
# ============================================================

create_fallback() {
    local item="$1"
    local is_folder="$2"
    
    python3 - "$item" "$is_folder" <<'PYTHON_FALLBACK'
import sys
import json
import os
from pathlib import Path
import re

item = sys.argv[1]
is_folder = sys.argv[2] == "true"

base_name = os.path.basename(item)
ext = Path(item).suffix.lower().lstrip('.') if not is_folder else ''

type_routes = {
    'mp3': ('MusicAlbum', 'Audio', '/data/library/RAM/Music/Unknown/Albums/', 'Unknown'),
    'flac': ('MusicAlbum', 'Audio', '/data/library/RAM/Music/Unknown/Albums/', 'Unknown'),
    'mp4': ('VideoBundle', 'Video', '/data/library/RAM/Movies/Unknown/', 'Unknown'),
    'mkv': ('VideoBundle', 'Video', '/data/library/RAM/Movies/Unknown/', 'Unknown'),
    'jpg': ('PhotoAlbum', 'Image', '/data/library/ROM/Photos/Unsorted/', None),
    'png': ('PhotoAlbum', 'Image', '/data/library/ROM/Photos/Unsorted/', None),
    'pdf': ('DocumentSet', 'Document', '/data/library/ROM/Documents/Sets/', None),
    'stl': ('ModelBundle', 'Model', '/data/library/RAM/3dModels/Projects/', None),
    'gcode': ('ModelBundle', 'Print', '/data/library/RAM/3dModels/GCode/', None),
    'dmg': ('Standalone', 'Software', '/data/library/RAM/Software/macos/unsorted/', None),
    'exe': ('Standalone', 'Software', '/data/library/RAM/Software/windows/unsorted/', None),
    'iso': ('Standalone', 'DiskImage', '/data/library/RAM/Misc/DiskImages/', None),
    'zip': ('Standalone', 'Archive', '/data/library/ROM/Archives/', None),
    'rar': ('Standalone', 'Archive', '/data/library/ROM/Archives/', None),
}

if is_folder:
    bundle_type = 'MixedBundle'
    category = 'Other'
    path = '/data/library/RAM/Misc/Unsorted/'
    genre = 'Unknown'
    os_ = 'unknown'
    usecase = 'unsorted'
else:
    bundle_type, category, path, genre = type_routes.get(ext, ('Standalone', 'Other', '/data/library/RAM/Misc/Unsorted/', None))
    os_ = 'macos' if ext == 'dmg' else 'windows' if ext == 'exe' else 'linux' if ext == 'deb' else 'unknown'
    usecase = 'unsorted'
    if category == 'Software':
        path = f'/data/library/RAM/Software/{os_}/{usecase}/'

clean_stem = Path(base_name).stem
year_match = re.search(r'\b(19\d{2}|20\d{2})\b', clean_stem)
year = f"_{year_match.group(0)}" if year_match else ''
title = re.sub(r'\.\d{4}.*', '', clean_stem).replace('.', ' ').strip()
clean_name = '_'.join(word.capitalize() for word in title.split())
clean_name += year
clean_name = re.sub(r'[^\w]', '_', clean_name)
clean_name = re.sub(r'_+', '_', clean_name).strip('_')

path += clean_name + '/' if is_folder else ''

result = {
    "bundle_type": bundle_type,
    "suggested_name": clean_name,
    "recommended_path": path,
    "confidence": 0.60,
    "reasoning": "Fallback rule-based classification",
    "tags": ["fallback", category.lower()],
    "category": category,
    "storage_zone": 'RAM' if bundle_type in ['MusicAlbum', 'VideoBundle', 'Standalone'] else 'ROM',
    "genre": genre,
    "os": os_,
    "usecase": usecase,
    "subfolder_plan": {"enabled": is_folder, "map": {}, "reasoning": "Fallback"},
    "actions": {
        "move": True,
        "rename": True,
        "extract_year": False,
        "create_subfolders": is_folder,
        "generate_tags": False,
        "verify_duplicates": True,
        "preserve_structure": False,
        "flatten_hierarchy": False
    },
    "warnings": ["AI classification failed, using fallback"],
    "recommendations": ["Manual review recommended"],
    "processing_notes": {
        "special_handling": "Fallback",
        "estimated_time_seconds": 5,
        "risk_level": "medium"
    }
}

print(json.dumps(result, ensure_ascii=False))
PYTHON_FALLBACK
}

# ============================================================
# Project Tag Detection
# ============================================================

detect_project_tag() {
    local item_name="$1"
    local tag=""
    
    if [[ "$item_name" =~ \#([a-zA-Z0-9_-]+) ]]; then
        tag="${BASH_REMATCH[1]}"
        echo "$tag"
    fi
}

find_project_folder() {
    local tag="$1"
    local found_path=""
    
    for zone in RAM ROM; do
        found_path=$(find "$LIBRARY_DIR/$zone" -maxdepth 3 -type d -iname "*${tag}*" -print -quit 2>/dev/null || true)
        if [[ -n "$found_path" ]]; then
            echo "$found_path"
            return 0
        fi
    done
    
    echo "/data/library/ROM/Tags/${tag}"
}

# ============================================================
# Main Classification Loop
# ============================================================

collect_candidates() {
    local -n candidates_ref=$1
    
    while IFS= read -r -d '' f; do
        candidates_ref+=("$f")
    done < <(find "$INBOX_DIR" -maxdepth 1 -type f ! -name '.*' -print0)
    
    while IFS= read -r -d '' d; do
        [[ "$(basename "$d")" == .* ]] && continue
        candidates_ref+=("$d")
    done < <(find "$INBOX_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0)
}

declare -a CANDIDATES=()
collect_candidates CANDIDATES

log "Found ${#CANDIDATES[@]} candidates to classify"
log ""
log "Candidates:"
for item in "${CANDIDATES[@]}"; do
    log "  - $(basename "$item")"
done
log ""

echo "[" > "$REPORT_FILE"
FIRST_ENTRY=true
PROCESSED=0
FAILED=0

for item in "${CANDIDATES[@]}"; do
    rel_path="${item#$INBOX_DIR/}"
    log "Processing: $rel_path"
    
    if [[ -d "$item" ]] && ! find "$item" -type f ! -name '.*' -print | head -1 | grep -q .; then
        log "  Skipping empty folder"
        continue
    fi
    
    is_folder=false
    [[ -d "$item" ]] && is_folder=true
    
    ANALYSIS_FILE="$TEMP_DIR/analysis_$$_$(date +%s%N).json"
    
    if ! analyze_item_with_python "$item" "$ANALYSIS_FILE"; then
        log "  ⚠️  Analysis failed"
        FAILED=$((FAILED + 1))
        continue
    fi
    
    AI_SUCCESS=false
    BUNDLE_JSON_FILE="$TEMP_DIR/bundle_$$_$(date +%s%N).json"
    FINAL_CONFIDENCE=0.0
    
    declare -a AI_CHAIN=("ollama_primary")
    
    if [[ "$USE_MULTI_AI" == "true" ]]; then
        AI_CHAIN+=("ollama_secondary")
        [[ -n "$OPENAI_API_KEY" ]] && AI_CHAIN+=("openai")
        [[ -n "$ANTHROPIC_API_KEY" ]] && AI_CHAIN+=("anthropic")
    fi
    
    for provider in "${AI_CHAIN[@]}"; do
        PROMPT_FILE="$TEMP_DIR/prompt_$$_$(date +%s%N).txt"
        RAW_RESPONSE="$TEMP_DIR/raw_$$_$(date +%s%N).json"
        CLEAN_JSON="$TEMP_DIR/clean_$$_$(date +%s%N).json"
        
        create_ai_prompt "$item" "$is_folder" "$ANALYSIS_FILE" "$PROMPT_FILE"
        
        case "$provider" in
            ollama_primary)
                log "  🤖 Trying Ollama ($OLLAMA_MODEL_PRIMARY)"
                call_ollama_ai "$PROMPT_FILE" "$RAW_RESPONSE" "$OLLAMA_MODEL_PRIMARY" && \
                    extract_json_from_response "$RAW_RESPONSE" "$CLEAN_JSON"
                ;;
            ollama_secondary)
                log "  🤖 Trying Ollama secondary ($OLLAMA_MODEL_SECONDARY)"
                call_ollama_ai "$PROMPT_FILE" "$RAW_RESPONSE" "$OLLAMA_MODEL_SECONDARY" && \
                    extract_json_from_response "$RAW_RESPONSE" "$CLEAN_JSON"
                ;;
            openai)
                log "  🌐 Trying OpenAI ($OPENAI_MODEL)"
                call_openai_ai "$PROMPT_FILE" "$RAW_RESPONSE" && \
                    extract_openai_response "$RAW_RESPONSE" "$CLEAN_JSON"
                ;;
            anthropic)
                log "  🌐 Trying Anthropic ($ANTHROPIC_MODEL)"
                call_anthropic_ai "$PROMPT_FILE" "$RAW_RESPONSE" && \
                    extract_anthropic_response "$RAW_RESPONSE" "$CLEAN_JSON"
                ;;
        esac
        
        if validate_ai_json "$CLEAN_JSON"; then
            FINAL_CONFIDENCE=$(jq -r '.confidence // 0.0' "$CLEAN_JSON" 2>/dev/null || echo "0.0")
            
            if (( $(echo "$FINAL_CONFIDENCE >= $CONFIDENCE_THRESHOLD" | bc -l 2>/dev/null || echo "1") )); then
                cp "$CLEAN_JSON" "$BUNDLE_JSON_FILE"
                AI_SUCCESS=true
                log "  ✓ $provider succeeded (confidence: $FINAL_CONFIDENCE)"
                break
            else
                log "  ⚠️  $provider low confidence ($FINAL_CONFIDENCE)"
            fi
        else
            log "  ⚠️  $provider failed validation"
        fi
        
        rm -f "$PROMPT_FILE" "$RAW_RESPONSE" "$CLEAN_JSON" 2>/dev/null || true
        sleep 1
    done
    
    if [[ "$AI_SUCCESS" == false ]]; then
        log "  ⚠️  All AI failed, using fallback"
        FALLBACK_JSON=$(create_fallback "$item" "$is_folder")
        echo "$FALLBACK_JSON" > "$BUNDLE_JSON_FILE"
        FAILED=$((FAILED + 1))
    fi
    
    MERGED_JSON="$TEMP_DIR/merged_$$_$(date +%s%N).json"
    merge_with_python "$ANALYSIS_FILE" "$BUNDLE_JSON_FILE" "$item" "$is_folder" "$MERGED_JSON"
    
    PROJECT_TAG=$(detect_project_tag "$(basename "$item")")
    if [[ -n "$PROJECT_TAG" ]]; then
        PROJECT_PATH=$(find_project_folder "$PROJECT_TAG")
        log "  📌 Project tag: #$PROJECT_TAG → $PROJECT_PATH"
        
        MERGED_JSON_TAGGED="$TEMP_DIR/tagged_$$_$(date +%s%N).json"
        CLEAN_ITEM_NAME=$(basename "$item" | sed "s/#${PROJECT_TAG}//")
        
        jq --arg path "$PROJECT_PATH/${CLEAN_ITEM_NAME}/" \
           --arg tag "$PROJECT_TAG" \
           '.recommended_path = $path | .tags += ["project:" + $tag] | .warnings += ["Tagged with project: " + $tag]' \
           "$MERGED_JSON" > "$MERGED_JSON_TAGGED"
        
        mv "$MERGED_JSON_TAGGED" "$MERGED_JSON"
    fi
    
    FINAL_JSON=$(jq --arg src "$item" --argjson folder "$is_folder" \
        '. + {source_path: $src, is_folder: $folder}' "$MERGED_JSON")
    
    if [[ "$FIRST_ENTRY" == true ]]; then
        FIRST_ENTRY=false
    else
        echo "," >> "$REPORT_FILE"
    fi
    echo "$FINAL_JSON" >> "$REPORT_FILE"
    
    PROCESSED=$((PROCESSED + 1))
    
    bundle=$(jq -r '.bundle_type' <<< "$FINAL_JSON")
    name=$(jq -r '.suggested_name' <<< "$FINAL_JSON")
    conf=$(jq -r '.confidence' <<< "$FINAL_JSON")
    log "  → $name ($bundle, confidence: $conf)"
    
    rm -f "$ANALYSIS_FILE" "$PROMPT_FILE" "$RAW_RESPONSE" "$CLEAN_JSON" "$BUNDLE_JSON_FILE" "$MERGED_JSON" 2>/dev/null || true
done

echo "]" >> "$REPORT_FILE"

log "============================================================"
log "Classification Complete"
log "Processed: $PROCESSED items"
log "Failed: $FAILED items"
log "Report: $REPORT_FILE"

if command -v jq >/dev/null 2>&1; then
    log ""
    log "Classification Summary:"
    jq -r '
        group_by(.bundle_type) |
        map({type: .[0].bundle_type, count: length}) |
        .[] |
        "  \(.type): \(.count)"
    ' "$REPORT_FILE" 2>/dev/null | tee -a "$LOG_FILE" || true
    
    AVG_CONF=$(jq '[.[].confidence] | add / length' "$REPORT_FILE" 2>/dev/null || echo "0")
    log "Average Confidence: $AVG_CONF"
fi

log "============================================================"
log "Log file: $LOG_FILE"

cleanup_temp

exit 0
