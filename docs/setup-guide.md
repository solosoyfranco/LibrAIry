# LibrAIry Setup Guide

This document explains how to run the **inbox-processor** container so it can clean,
deduplicate, and stage files that land in your NAS inboxes. The goal is to turn messy
downloads into organized libraries that tools like Plex, Jellyfin, Immich, and
Paperless-ngx can index immediately.

## 1. Folder layout

Start by mirroring the working layout described in the project README. Two distinct
storage classes keeps "cold" archival data separate from disposable downloads:

```
/mnt/user/RAM/          # High-churn media, usually un-backed up
    inbox/
    staging/
    library/
    quarantine/

/mnt/user/ROM/          # Critical photos, backups, documents (backed up nightly)
    inbox/
    staging/
    library/
    quarantine/
```

Only the inbox and library paths are required for the container; the staging and
quarantine folders give you a safe review buffer when removing duplicates.

## 2. Container image

The `inbox-processor/Dockerfile` builds a small Debian-based image with the
following tooling pre-installed:

- `rmlint` for hashing and identifying exact duplicates.
- `jq`/`gawk`/`coreutils` for parsing report data and crafting summaries.
- Helper scripts stored in `/opt/inbox` for planning, applying, and reporting on
  dedupe actions.

You can build the image locally or publish it to your private registry:

```bash
cd inbox-processor
docker build -t librairy/inbox-processor:latest .
```

## 3. Environment variables

The container is configured entirely through environment variables. The most
important ones are listed below.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ACTION` | `plan` | `plan` runs rmlint and produces reports, `apply` executes the latest rmlint script, and `dedupe` chains both plus the safe quarantine move. |
| `INBOX_DIRS` | `/data/inbox` | Comma/colon separated list of inbox paths to scan. |
| `LIBRARY_DIRS` | `/data/library` | Comma/colon separated list of library roots (used to prioritise keepers). |
| `REPORTS_DIR` | `/data/reports` | Where JSON reports and helper scripts are written. |
| `LOGS_DIR` | `/data/logs` | Persistent log destination. |
| `QUARANTINE_DIR` | `/data/quarantine/duplicates` | Folder that receives removed duplicates. |
| `QUARANTINE_RETENTION_DAYS` | `30` | Age threshold used by the purge helper. |
| `DELETE_INSTEAD_OF_QUARANTINE` | `false` | Set to `true` only after you trust the workflow. |
| `DISCORD_WEBHOOK_URL` | _(empty)_ | Optional endpoint for nightly reports. |

Every helper script honours these variables, so volume bindings only need to make
sure the relevant host paths are available under `/data/...` in the container.

## 4. Quick start (`docker run`)

After building the image, run a planning pass to generate reports:

```bash
docker run --rm \
  -e ACTION=plan \
  -e INBOX_DIRS=/data/ram/inbox:/data/rom/inbox \
  -e LIBRARY_DIRS=/data/ram/library:/data/rom/library \
  -v /mnt/user/RAM/inbox:/data/ram/inbox \
  -v /mnt/user/ROM/inbox:/data/rom/inbox \
  -v /mnt/user/RAM/library:/data/ram/library:ro \
  -v /mnt/user/ROM/library:/data/rom/library:ro \
  -v /mnt/user/system/librairy/reports:/data/reports \
  -v /mnt/user/system/librairy/logs:/data/logs \
  -v /mnt/user/system/librairy/quarantine:/data/quarantine \
  librairy/inbox-processor:latest
```

The reports folder now contains `rmlint.json`, the generated `rmlint_apply.sh`,
and a textual summary. Review those files (for example with File Browser or
TagSpaces). When satisfied, apply the safe moves:

```bash
docker run --rm \
  -e ACTION=dedupe \
  ...same volume bindings as above...
  librairy/inbox-processor:latest
```

This re-plans, quarantines the duplicates, and refreshes the summary report.

## 5. Example `docker-compose.yml`

For day-to-day usage a Compose stack keeps volumes and environment neatly
tracked. Save the snippet below as `examples/docker-compose.yml` and adjust the
host paths for your NAS.

```yaml
services:
  inbox-processor:
    build: ../inbox-processor
    container_name: librairy-inbox-processor
    restart: "no"
    environment:
      ACTION: plan
      INBOX_DIRS: /data/ram/inbox:/data/rom/inbox
      LIBRARY_DIRS: /data/ram/library:/data/rom/library
      REPORTS_DIR: /data/reports
      LOGS_DIR: /data/logs
      QUARANTINE_DIR: /data/quarantine/duplicates
      QUARANTINE_RETENTION_DAYS: "30"
      DISCORD_WEBHOOK_URL: ""
    volumes:
      - /mnt/user/RAM/inbox:/data/ram/inbox:rw
      - /mnt/user/ROM/inbox:/data/rom/inbox:rw
      - /mnt/user/RAM/library:/data/ram/library:ro
      - /mnt/user/ROM/library:/data/rom/library:ro
      - ./reports:/data/reports:rw
      - ./logs:/data/logs:rw
      - ./quarantine:/data/quarantine:rw
```

Run the processor with `docker compose run --rm inbox-processor`. Swap
`ACTION=dedupe` when you are ready to move files, or schedule the command via
cron/NAS task scheduler.

> **Tip:** create the `reports`, `logs`, and `quarantine` directories next to the
> Compose file (or update the volume paths) so that writes succeed without
> Docker creating root-owned folders on your host.

## 6. Reviewing results

- **Reports** – `rmlint.json` contains the raw data while `rmlint_apply.sh`
  shows the exact moves that will be executed. `summary.txt` provides a quick
  human-readable overview.
- **Logs** – `logs/dedupe.log` captures every move into quarantine and any
  Discord webhook output if configured.
- **Quarantine** – Each run creates a date-stamped folder. After 30 days the
  `purge_quarantine.sh` helper (invoked by `ACTION=dedupe`) clears old batches.

## 7. Next steps and extensions

1. Feed the cleaned libraries into Plex/Jellyfin for media, Immich for photos,
   and Paperless-ngx for documents.
2. Plug the reports directory into TagSpaces or File Browser to manually review
   near-duplicate proposals.
3. Add automation using n8n or your NAS scheduler to alternate `plan` and
   `dedupe` passes (for example: plan daily, dedupe weekly after manual review).
4. Layer in AI rename/move proposals with LlamaFS or an Ollama container once
   the core dedupe workflow is stable.

## 8. Backup policy reminders

- Treat the `ROM/library` data as critical and back it up with `restic` or your
  preferred tool every night to both a secondary NAS and cloud storage.
- `RAM/library` is assumed to be reproducible media, so Plex and Jellyfin can
  read directly from it without extra backups.
- The quarantine area is your safety net—never enable the hard delete option
  until you have validated multiple successful runs.
