# 📂 LibrAIry
*An AI-powered librarian for your digital clutter.*

> **Note:** This repository is the **project plan (in progress)** for LibrAIry.  
> The vision is to build an AI-powered file workflow that can run on **any NAS platform** (Unraid, TrueNAS, Synology, etc.) using Docker or Kubernetes.  
> I personally run this on **Unraid**, but the design is portable.

---

## Project Idea

**LibrAIry** is a self-hosted **file organization workflow** designed for NAS and homelabs.  
It transforms messy **inbox folders** into clean, deduplicated, AI-organized **libraries** ready for Plex, Jellyfin, Paperless-ngx, Immich, and more.

---

## Folder Analogy

```
/mnt/user/RAM/          # Non-critical, ephemeral media
    inbox/              # New unsorted files
    staging/            # Where dedupe + AI run
    library/            # Final organized Plex/Jellyfin dirs
    quarantine/         # Unknowns or flagged items

/mnt/user/ROM/          # Critical backups & memories
    inbox/
    staging/
    library/
    quarantine/
```

- **RAM** → Movies, shows, ISOs, tutorials (no backup, Plex-ready)
- **ROM** → Backups, documents, photos, memories (backed up + indexed)

---

## Workflow Plan

1. **Drop files**  
   - Plex downloads → `/RAM/inbox`  
   - iPhone backups, Win/Mac backups, photos, docs → `/ROM/inbox`

2. **Processing**  
   - `rmlint` → exact duplicates (JSON + safe apply script)  
   - `czkawka-cli` → similar images/videos (JSON report)  
   - `LlamaFS` → AI rename/move proposals (via Ollama (local LLM) or ChatGPT)  

3. **Review (UI)**
   - Get alert (gotify, discord, telegram, etc)
   - Review reports in **File Browser** or **TagSpaces**  
   - Approve & run safe apply script → moves to `library/`

5. **Indexing & search**  
   - **Recoll WebUI** auto-indexes libraries for full-text search  
   - **Paperless-ngx** ingests documents  
   - **Immich** manages photos & videos  

6. **Backup policy**
   - `/ROM/library` → nightly `restic` backup (secondary NAS, and cloud backup)
   - `/RAM/library` → no backup, Plex reads directly

---

## Getting Started

The `inbox-processor` image in this repository already wires together the rmlint
planning, safe apply scripts, quarantine handling, and reporting described above.

- Read the step-by-step [setup guide](docs/setup-guide.md) for build/run
  instructions tailored to NAS platforms.
- A ready-to-edit Compose example lives at
  [`examples/docker-compose.yml`](examples/docker-compose.yml) so you can plug in
  your own inbox/library mounts quickly.
- The helper scripts emit JSON reports and summaries under `/data/reports`; pair
  them with tools like File Browser or TagSpaces for review before applying
  changes.

---

## Integrations

- **Plex / Jellyfin** → media libraries
- **Paperless-ngx** → OCR & document management
- **Immich** → photo/video management
- **TagSpaces** → tagging & visual file browsing
- **Recoll WebUI** → full-text search engine
- **Ollama / ChatGPT** → AI rename/move proposals
- **Discord** → nightly reports & alerts
- **n8n** → optional workflow automation glue

---

## Checklist (Project Plan)

- [ ] Create Docker container with `rmlint` + `czkawka-cli`
- [ ] Add reporting pipeline (JSON + summaries)
- [ ] Add Discord webhook for alerts
- [ ] Add `LlamaFS` for AI rename/move proposals
- [ ] Build safe apply scripts (`apply_rmlint.sh`, `apply_llamafs.py`)
- [ ] Integrate with File Browser for human review
- [ ] Mount into Plex/Jellyfin (RAM)
- [ ] Mount into Paperless-ngx (ROM Documents)
- [ ] Mount into Immich (ROM Photos)
- [ ] Add Recoll WebUI for search
- [ ] Add restic backup jobs for ROM
- [ ] Add project tag system (`!projectName/` auto-routing)
- [ ] Package as public Docker image (multi-arch: amd64 + arm64)
- [ ] Publish documentation and setup guides

---

## Idea

- **Safe-first** → nothing deletes automatically; dupes replaced by hardlinks  
- **Human in loop** → AI only proposes; you approve  
- **Extensible** → add more tools (ffprobe, exiftool, rdfind) easily  
- **Future proof** → runs in Docker now, migrates to Kubernetes later  

---

## 📜 License

MIT — free to use, fork, and improve.

---

## 💡 Credits

- [rmlint](https://github.com/sahib/rmlint) — duplicate finder  
- [czkawka](https://github.com/qarmin/czkawka) — similar image/video finder  
- [LlamaFS](https://github.com/iyaja/llama-fs) — AI file renamer/sorter  
- [TagSpaces](https://www.tagspaces.org/), [Recoll](https://www.lesbonscomptes.com/recoll/), [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx), [Immich](https://github.com/immich-app/immich)
