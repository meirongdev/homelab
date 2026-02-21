# Calibre-Web-Automated Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the linuxserver calibre-web deployment with Calibre-Web-Automated to enable auto-ingest (drop books into `/storage/calibre/ingest`, CWA imports them automatically).

**Architecture:** In-place update of `k8s/helm/manifests/calibre-web.yaml` — swap the container image, update env vars and volume mounts, add a new config PVC. All K8s resource names (Deployment, Service, labels) stay the same so gateway, ArgoCD, homepage, and Cloudflare need no changes. The existing `calibre-books` PVC is reused with an additional `subPath: ingest` mount for the watch folder.

**Tech Stack:** Kubernetes manifests (YAML), ArgoCD GitOps, NFS storage, Calibre-Web-Automated (`crocodilestick/calibre-web-automated:latest`)

---

### Task 1: Create the ingest directory on the NFS server

**Files:**
- No file changes — SSH action on NFS server `192.168.50.106`

**Step 1: SSH to the NFS server and create the ingest directory**

```bash
ssh root@192.168.50.106 "mkdir -p /storage/calibre/ingest && ls -la /storage/calibre/"
```

Expected output: directory listing showing `ingest/` present.

**Step 2: Verify permissions allow write from the K8s node**

```bash
ssh root@192.168.50.106 "stat /storage/calibre/ingest"
```

Expected: mode `755` or `777`. If needed: `chmod 755 /storage/calibre/ingest`.

---

### Task 2: Update the manifest — config PVC

**Files:**
- Modify: `k8s/helm/manifests/calibre-web.yaml:8-20`

**Step 1: Replace the `calibre-web-config` PVC with `calibre-web-automated-config`**

The old PVC has `Prune=false` so it will remain as an orphan (intentional — safety net). Add the new PVC alongside it.

In `k8s/helm/manifests/calibre-web.yaml`, replace the config PVC block:

```yaml
# OLD — leave this as-is (Prune=false keeps it on cluster as backup)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: calibre-web-config
  namespace: personal-services
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
```

Replace with a new PVC (different name):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: calibre-web-automated-config
  namespace: personal-services
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
```

---

### Task 3: Update the manifest — Deployment

**Files:**
- Modify: `k8s/helm/manifests/calibre-web.yaml:55-117`

**Step 1: Update the container image**

Change:
```yaml
image: lscr.io/linuxserver/calibre-web:latest
```
To:
```yaml
image: crocodilestick/calibre-web-automated:latest
```

**Step 2: Update environment variables**

Remove `DOCKER_MODS` (bundled in CWA). Add three new env vars. Final `env` block:

```yaml
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: TZ
              value: "Asia/Shanghai"
            - name: NETWORK_SHARE_MODE
              value: "true"
            - name: TRUSTED_PROXY_COUNT
              value: "1"
            - name: CWA_WATCH_MODE
              value: "poll"
```

**Step 3: Update volumeMounts in the calibre-web container**

Change `/books` → `/calibre-library` and add the ingest mount:

```yaml
          volumeMounts:
            - name: config
              mountPath: /config
            - name: books
              mountPath: /calibre-library
            - name: books
              mountPath: /cwa-book-ingest
              subPath: ingest
```

**Step 4: Update the config volume reference**

In the `volumes:` section at the bottom of the Deployment, change the config PVC claim:

```yaml
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: calibre-web-automated-config
        - name: books
          persistentVolumeClaim:
            claimName: calibre-books
```

---

### Task 4: Verify the manifest is valid YAML

**Step 1: Dry-run the manifest with kubectl**

```bash
kubectl apply --dry-run=client -f k8s/helm/manifests/calibre-web.yaml
```

Expected output (no errors):
```
namespace/personal-services configured (dry run)
persistentvolumeclaim/calibre-web-automated-config configured (dry run)
persistentvolume/calibre-books-pv configured (dry run)
persistentvolumeclaim/calibre-books configured (dry run)
deployment.apps/calibre-web configured (dry run)
service/calibre-web configured (dry run)
```

If you see parse errors, fix the YAML indentation before continuing.

---

### Task 5: Commit and push

**Step 1: Stage and commit**

```bash
git add k8s/helm/manifests/calibre-web.yaml
git commit -m "feat: migrate calibre-web to Calibre-Web-Automated

- Replace linuxserver image with crocodilestick/calibre-web-automated
- Add NETWORK_SHARE_MODE, CWA_WATCH_MODE=poll for NFS library
- Add TRUSTED_PROXY_COUNT=1 for Traefik proxy
- Mount /cwa-book-ingest via subPath:ingest on calibre-books PVC
- New calibre-web-automated-config PVC for fresh start"
```

**Step 2: Push to trigger ArgoCD**

```bash
git push origin main
```

ArgoCD polls every 3 minutes. To force immediate sync:
```bash
cd k8s/helm && just argocd-sync
```

---

### Task 6: Verify deployment

**Step 1: Watch the rollout**

```bash
kubectl rollout status deployment/calibre-web -n personal-services --timeout=120s
```

Expected: `deployment "calibre-web" successfully rolled out`

If it times out, check events:
```bash
kubectl describe deployment calibre-web -n personal-services
kubectl describe pod -l app=calibre-web -n personal-services
```

**Step 2: Confirm the running image is CWA**

```bash
kubectl get deployment calibre-web -n personal-services -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Expected: `crocodilestick/calibre-web-automated:latest`

**Step 3: Check pod logs for startup errors**

```bash
kubectl logs -l app=calibre-web -n personal-services -c calibre-web --tail=50
```

Expected: CWA startup messages, no crash loop.

**Step 4: Verify ingest volume mounted**

```bash
kubectl exec -n personal-services deploy/calibre-web -c calibre-web -- ls /cwa-book-ingest
```

Expected: empty directory listing (no error).

**Step 5: Open the UI**

Visit `https://book.meirong.dev`. You should see the CWA setup/login page.

Complete initial setup:
- Create admin user
- Set library path to `/calibre-library`

---

### Task 7: Test auto-ingest

**Step 1: Drop a test epub into the ingest folder**

From the NFS server or any machine with access to the share:
```bash
ssh root@192.168.50.106 "cp /path/to/test.epub /storage/calibre/ingest/"
```

Or from the K8s node:
```bash
kubectl exec -n personal-services deploy/calibre-web -c calibre-web -- \
  sh -c "ls /cwa-book-ingest"
```

**Step 2: Watch CWA process it**

```bash
kubectl logs -l app=calibre-web -n personal-services -c calibre-web -f
```

Expected: log lines showing the book being detected, converted if needed, and added to library. The file disappears from `/storage/calibre/ingest` and appears in the CWA web UI.

---

### Task 8: Cleanup (after stable for a few days)

**When:** Once you're satisfied CWA is stable and no rollback is needed.

**Step 1: Delete the orphaned old config PVC**

```bash
kubectl delete pvc calibre-web-config -n personal-services
```

Note: The `Prune=false` annotation means ArgoCD won't recreate it. This is a one-time manual deletion.

---

## Rollback

If CWA fails to start or behaves incorrectly:

1. Revert `calibre-web.yaml` to the previous image + env + mounts:
   ```bash
   git revert HEAD
   git push origin main
   ```
2. ArgoCD will re-sync within 3 minutes, restoring the linuxserver image.
3. The old `calibre-web-config` PVC is still on the cluster (Prune=false), so the previous config is intact.
