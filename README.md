# LibrAIry  
**AI‑Powered File Organization & Library Manager**

LibrAIry automates large‑scale file reorganization by combining:
- AI analysis (via local model)  
- Metadata & fingerprinting  
- Structured move‑planning  
with a simple Bash pipeline.

Whether you've got random files, downloads, media assets, or a growing document stash — LibrAIry helps you turn it into an organised, searchable library.

---

## 🚀 Why LibrAIry?

- **Smart classification** — Files and folders are analysed and grouped logically (photos, videos, 3D models, music, documents, etc).  
- **AI‑driven suggestions** — A local AI helps determine destination, renaming, category and structure.  
- **Dry‑run safe** — Preview exactly what will move/rename before anything changes.  
- **Supports massive/chaotic collections** — Recovers order from inboxes, archives, or mixed dumps.  
- **Extensible pipeline** — Easily drop in further steps: fingerprinting duplicates, metadata enrichment, clean‑up.

---

## 🧩 Core Pipeline

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `step1_scan.sh` | Scans `/data/inbox`, identifies duplicates, generates report. |
| 2 | `step2_hash_audio_video.sh` | Optional: generate audio/video fingerprints for deep dup detection. |
| 3 | `step3_classify.sh` | AI classifies each item: bundle type, rename, destination. |
| 4 | `step4_dryrun.sh` | Dry run: shows “Would move” list based on AI output. |
| 5| `step5_commit.sh` | Actually moves/renames files and logs summary. |

---

## 📂 Directory Layout

```
/data
  ├─ inbox/         # incoming un‑organised files/folders
  ├─ library/       # target organised library root
  ├─ reports/       # JSON & logs from each step
  └─ quarantine/    # files flagged for review or duplicates
```

---

## 🧑‍💻 Quick Start

```bash
git clone https://github.com/solosoyfranco/LibrAIry.git
cd LibrAIry

# In Docker or dev container:
docker run -it   --name devbox   -v "$PWD":/workspace   -v "$HOME/Desktop/inbox-test":/data   debian:bookworm-slim bash

# Install dependencies (inside container):
apt update && apt install -y jq curl wget git coreutils iputils-ping rmlint ffmpeg

# Clone & build Czkawka (optional for duplicates)
# (see full instructions in INSTRUCTIONS.md)

# Make scripts executable:
cd scripts && chmod +x *.sh

# Run the pipeline:
./step1_scan.sh
./step2_hash_audio_video.sh
./step3_classify.sh
./step4_dryrun.sh

# Inspect dry‑run output. If satisfied:
./step5_commit.sh
```

---

## 📊 What the AI Output Looks Like

A snippet of the JSON report produced in step 3 (`step3_summary.json`):

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

## 🎯 License & Contribution

LibrAIry is released under the **MIT License**.  
Contributions welcome — please open issues/PRs for new features, bug fixes or better AI prompt fine‑tuning.

---

## 🪄 Future Vision

- Deep duplicate detection via audio/video fingerprinting  
- Metadata enrichment (music tags, video resolution, photo EXIF)  
- UI/WEB dashboard for managing and visualising your library  
- Cloud/NAS integration (sync, index, search)  

---


## 💡 Credits

- [rmlint](https://github.com/sahib/rmlint) — duplicate finder  
- [czkawka](https://github.com/qarmin/czkawka) — similar image/video finder  
