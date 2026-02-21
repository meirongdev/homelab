# Design: Calibre-Web → Calibre-Web-Automated Migration

**Date:** 2026-02-21
**Approach:** In-place update (Approach A)

## Goal

Replace the existing `lscr.io/linuxserver/calibre-web` deployment with `crocodilestick/calibre-web-automated` to gain auto-ingest functionality: drop books into `/storage/calibre/ingest` on NFS and CWA automatically imports them into the Calibre library.

## Changes

### `k8s/helm/manifests/calibre-web.yaml`

| What | Before | After |
|------|--------|-------|
| Image | `lscr.io/linuxserver/calibre-web:latest` | `crocodilestick/calibre-web-automated:latest` |
| `DOCKER_MODS` env | `linuxserver/mods:universal-calibre` | removed (bundled in CWA) |
| New env vars | — | `NETWORK_SHARE_MODE=true`, `TRUSTED_PROXY_COUNT=1`, `CWA_WATCH_MODE=poll` |
| Library mount | `/books` → `calibre-books` PVC | `/calibre-library` → `calibre-books` PVC (full mount) |
| Ingest mount | — | `/cwa-book-ingest` → `calibre-books` PVC, `subPath: ingest` |
| Config PVC name | `calibre-web-config` | `calibre-web-automated-config` (fresh start) |
| log-exporter | tails `/config/calibre-web.log` | same (verify path post-deploy) |

### No changes to:
- `gateway.yaml` (HTTPRoute backendRef: `calibre-web:8083` unchanged)
- `argocd/applications/personal-services.yaml`
- `cloudflare/terraform/terraform.tfvars`
- `homepage.yaml`

## Prerequisite

Create `/storage/calibre/ingest` on NFS server `192.168.50.106` before deploying.

## Migration Flow

1. Create `/storage/calibre/ingest` on NFS server
2. Apply manifest changes via `git push` → ArgoCD auto-deploys within 3 min
3. Old `calibre-web-config` PVC remains (orphaned, `Prune=false`) — delete manually once stable
4. Access `book.meirong.dev`, complete CWA initial setup (admin user, Calibre library path → `/calibre-library`)
5. Drop a test book into `/storage/calibre/ingest` to verify auto-ingest

## Decisions

- **Fresh config:** Start with a new `calibre-web-automated-config` PVC; do not reuse old app DB
- **URL:** Keep `book.meirong.dev` — no Cloudflare or gateway changes
- **Ingest folder:** Subpath of existing `calibre-books` PVC (`subPath: ingest`) — no new NFS export needed
- **NFS env vars:** `NETWORK_SHARE_MODE=true` + `CWA_WATCH_MODE=poll` required for NFS-backed library
