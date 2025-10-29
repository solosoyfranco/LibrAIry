# 🧠 LibrAIry — AI-Powered File Organizer  
*(Developed by Franco)*

This project automates large-scale file organization and deduplication using local AI (via [Ollama](https://ollama.ai/)), metadata analysis, and structured Bash pipelines.  
It’s ideal for cleaning up mixed folders of photos, videos, documents, 3D models, and music/video collections.

---

## 🚀 Quick Start

### 1️⃣ Launch the Dev Container

```bash
docker run -it   --name devbox   -v "$PWD":/workspace   -v "$HOME/Desktop/inbox":/data   debian:bookworm-slim bash
```

> `/workspace` contains your scripts  
> `/data` is your working directory with:
> ```
> /data/inbox/      # source files to analyze
> /data/library/    # organized destination structure
> /data/reports/    # JSON outputs from each step
> /data/quarantine/ # problematic or duplicate files
> ```

If you’re installing packages and don’t want to redo setup every time:
```bash
docker commit devbox my/devbox:latest
```

Later:
```bash
docker start -ai devbox
```

---

## System Setup (inside container)

### Basic utilities
```bash
apt update && apt install -y   jq curl wget git coreutils iputils-ping rmlint ffmpeg
```

### Build Czkawka (for duplicate detection)
```bash
apt install -y   build-essential pkg-config cmake nasm yasm clang g++ gcc   libjpeg-dev libpng-dev libtiff-dev libtag1-dev   libaom-dev libdav1d-dev libavif-dev libheif-dev libx264-dev libx265-dev

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
rustc --version
cargo --version

git clone https://github.com/qarmin/czkawka.git /opt/czkawka
cd /opt/czkawka
export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig
cargo build --release --bin czkawka_cli -p czkawka_cli --features "czkawka_core/heif czkawka_core/libavif"

cp target/release/czkawka_cli /usr/local/bin/
chmod +x /usr/local/bin/czkawka_cli
czkawka_cli --version
```

---

## Pipeline Overview

| Step | Script | Description |
|------|---------|-------------|
| 1 | `step1_scan.sh` | Scans `/data/inbox` for duplicates (hash-level) and prepares reports |
| 2 | `step2_hash_audio_video.sh` | Optional: generates audio/video fingerprints for deep duplicate detection |
| 3 | `step3_classify.sh` | AI-powered classification of each inbox file/folder using Ollama |
| 4 | `step4_dryrun.sh` | Simulates moves based on AI output — shows “Would move” actions safely |
| 5 | `step5_commit.sh` | Executes real file moves and writes a summary report |
| 6 | `step6_cleanup.sh` | Clean up|

---

## Step 3 — AI Classification Details

This is where the magic happens.

The AI prompt guides the model to:
- Understand the existing `/data/library` layout.
- Examine each inbox item (file or folder).
- Recommend its **destination**, **renaming**, and **classification**.

### Supported Types

| Type | Example Destination |
|-------|----------------------|
| `VideoBundle` | `/data/library/RAM/Movies/<title>` |
| `PhotoAlbum` | `/data/library/ROM/Photos/Albums/<album>` |
| `ModelBundle` | `/data/library/ROM/Models/Bundles/<project>` |
| `MusicAlbum` | `/data/library/RAM/Music/Albums/<artist_album>` |
| `DocumentSet` | `/data/library/ROM/Documents/Sets/<topic>` |
| `ArchiveCollection` | `/data/library/ROM/Archives` |
| `TaggedProject` | `/data/library/ROM/Misc/Projects/<project>` |
| `MixedBundle` | `/data/library/RAM/Misc/Mixed/<name>` |
| `Standalone` | `/data/library/RAM/Misc/Unsorted/<file>` |

### Music & Video Rules
| Type | Destination Example |
|-------|----------------------|
| `MusicAlbum` | `/data/library/RAM/Music/Albums/artist_album` |
| `MusicSingle` | `/data/library/RAM/Music/Singles/artist_title` |
| `LiveRecording` | `/data/library/RAM/Music/Live/artist_year` |
| `MusicVideo` | `/data/library/RAM/MusicVideos/artist_title` |
| `LivePerformanceVideo` | `/data/library/RAM/MusicVideos/LivePerformances/artist_year` |
| `FanVideo` | `/data/library/RAM/MusicVideos/FanVideos/artist_title` |

---

## Example Output (from `step3_summary.json`)

```json
{
  "bundle_type": "PhotoAlbum",
  "suggested_name": "unsorted",
  "recommended_path": "/data/library/ROM/Photos/Unsorted",
  "reasoning": "single image without context",
  "subfolder_plan": { "enabled": false },
  "files": [
    {
      "original_name": "img_5661.jpeg",
      "category": "image",
      "rename_to": null
    }
  ],
  "source_path": "/data/inbox/img_5661.jpeg"
}
```

---

## Step 4 — Dry Run

```bash
/workspace/inbox-processor/scripts/step4_dryrun.sh
```

Simulates moves:
```
📦 Processing: /data/inbox/screenshot_2025-10-17_at_8.50.36_pm.jpg
Type: Standalone
Suggested name: screenshot_2025-10-17_at_8.50.36_pm
Recommended path: /data/library/RAM/Misc/Unsorted/
  📂 Would create: /data/library/RAM/Misc/Unsorted/
    🚚 Would move: /data/inbox/screenshot_2025-10-17_at_8.50.36_pm.jpg → /data/library/RAM/Misc/Unsorted/screenshot_2025-10-17_at_8.50.36_pm.jpg
✅ [step4-dryrun] Simulation complete: 25 moves simulated, 0 quarantines
```

---

## Step 5 — Commit Moves

```bash
/workspace/inbox-processor/scripts/step5_commit.sh
```

This performs actual file moves and writes `step5_summary.json`.

---

## Quarantine System

Files that are:
- Missing from source,
- Have invalid paths,
- Or produce ambiguous AI output,

…are moved to `/data/quarantine/YYYY-MM-DD`.


---

## Logs and Reports

| File | Description |
|-------|--------------|
| `/tmp/step3_ai.log` | AI classification process log |
| `/tmp/step4_dryrun.log` | Dry run summary |
| `/data/reports/step3_summary.json` | Structured AI results |
| `/data/reports/step5_summary.json` | Actual move results |
| `/data/quarantine/YYYY-MM-DD/` | Problematic files |

---

## Example Dev Workflow

```bash
cd /workspace/inbox-processor/scripts
chmod +x *.sh

./step1_scan.sh
./step2_hash_audio_video.sh
./step3_classify.sh
./step4_dryrun.sh
./step5_commit.sh
```

---

## 🧩 Future Enhancements

- ✅ Deduplication by **audio/video fingerprint**
- ✅ Integration with **Ollama local models**
- 🧠 Music metadata enrichment using `mutagen` and `ffprobe`
- 🧰 GUI interface via Flask or TUI
- ☁️ Sync integration (Nextcloud, S3, or NAS)

