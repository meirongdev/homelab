---
name: sync-ebooks
description: Sync local ebook files into the homelab calibre-web (cwa) ingest folder running on Kubernetes — validates integrity, de-dupes against the library, copies into the pod, and keeps a backup. Use when the user wants to sync/upload/import ebooks or books into calibre-web, or mentions calibre ingest, "同步电子书", "上传电子书到 calibre", or the book.meirong.dev library.
---

# Sync ebooks → calibre-web

Wraps `scripts/sync_ebooks.py` (bundled). It resolves the calibre-web pod **dynamically**
from a label selector (never a hardcoded pod name), validates epub/pdf integrity, skips
books already in the library DB or the ingest folder, `kubectl cp`s new ones into the
pod's ingest path, and keeps a local backup.

## Quick start

Always preview first, then run for real:

```bash
SKILL=.claude/skills/sync-ebooks/scripts/sync_ebooks.py
python3 "$SKILL" --source ~/Downloads/books --dry-run   # classify only, no copy
python3 "$SKILL" --source ~/Downloads/books             # actually sync
```

Defaults target homelab calibre-web, so for the common case only `--source` is needed.
calibre-web auto-imports from the ingest folder a few minutes after the copy.

## Parameters

| Flag | Default | Purpose |
|------|---------|---------|
| `--source` | `~/Downloads/books` | Local dir to scan (the main input) |
| `--context` | `k3s-homelab` | kubectl context |
| `--namespace` | `personal-services` | calibre-web namespace |
| `--selector` | `app=calibre-web` | Label selector → pod |
| `--ingest-path` | `/cwa-book-ingest` | Ingest folder in the pod |
| `--db-path` | `/calibre-library/metadata.db` | calibre DB in the pod |
| `--backup-dir` | `~/.local/share/calibre-web-sync-backup` | Local backup copy |
| `--exts` | `.pdf,.epub,.mobi,.azw,.azw3,.cbz,.cbr,.djvu` | Supported extensions |
| `--dry-run` / `--check-only` | off | Classify only, copy nothing |
| `--skip-validation` | off | Skip epub/pdf integrity checks |
| `--no-backup` | off | Don't keep a local backup |
| `--filter-non-ebooks` | off | Skip resumes / Confluence exports / work docs by filename |
| `--cp-timeout` | `600` | Per-file `kubectl cp` timeout (large books) |
| `--timeout` | `60` | kubectl query/exec timeout |
| `--verbose` | off | List the files that would sync |

## Workflow

1. Run with `--dry-run` and confirm the "to sync" count looks right.
2. Run without `--dry-run`. Exit code is non-zero if any copy failed.
3. Wait a few minutes; verify in calibre-web (`book.meirong.dev`) or re-run `--dry-run`
   (synced books should now show as duplicates/in-ingest).

## Notes

- **Dedup is heuristic** (title from filename vs DB title, ignoring `(author)`/`[tag]`
  suffixes and a trailing ` - author`). It can miss matches with unusual separators;
  re-running `--dry-run` after import is the safety check.
- If the DB query fails the script **aborts** rather than treating everything as new
  (which would re-ingest duplicates).
- Other ebook tooling in `scripts/` is separate: `sync-ebooks.sh` powers the in-cluster
  `calibre-ebook-sync` CronJob + `just sync-ebooks*` recipes; `cleanup-duplicates.sh`
  (`just calibre-cleanup*`) removes duplicate library entries. This skill is the
  interactive, local-machine path.
