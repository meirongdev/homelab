# Plan: Fix Calibre-Web NFS Permissions

## Problem Statement
When uploading books or performing automated ingest in Calibre-Web-Automated, newly created directories on the NFS share are owned by `root`. Since the application drops privileges to user `1000` (PUID) after initialization, it loses the ability to modify these files/directories later, leading to permission denied errors.

## Root Cause Analysis
1. **Container Initialization**: The `crocodilestick/calibre-web-automated` image (based on LinuxServer.io patterns) starts as `root` (UID 0) to perform system-level initialization (like `chown`ing the `/config` directory) before dropping to the user specified by `PUID`.
2. **NFS Ownership**: If directory creation happens during the root phase or if the NFS server defaults to root ownership for new entries created by a root client, the resulting files are inaccessible to the app's unprivileged user.
3. **Recursive Chown Limitation**: On large NFS volumes, the container's built-in `chown` logic might be skipped or fail due to `NETWORK_SHARE_MODE=true` or timeout, leaving subdirectories with incorrect ownership.

## Implementation Status (2026-03-15 Update)
**DEPRECATED**: The `initContainer` approach was found to be unreliable due to NFS `root_squash` restrictions and potential performance issues on large libraries.

**FINAL DECISION**: Fixed via NFS Server-side configuration (`all_squash`).
- **NFS Server Export**: `/storage/calibre *(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)`
- **Reasoning**: This ensures all files, including those created by background automated processes, are consistently owned by UID 1000, regardless of the container's internal UID transitions.
- **Manual Cleanup**: Permissions were manually normalized on the NFS host using `chown -R 1000:1000 /storage/calibre`.

## Original Proposed Solution (Retained for history)
... (rest of the original content) ...
Add an `initContainer` to the `calibre-web` deployment that explicitly sets ownership of the library and config directories to `1000:1000`. This ensures that even if the NFS server or provisioner created them as root, they are corrected before the app starts.

### 2. Update Pod Security Context
Add `fsGroup: 1000` to the pod's `securityContext`. While NFS support for `fsGroup` varies, it provides a hint to the Kubelet to attempt ownership management.

### 3. Verify NFS Export Configuration
Ensure the NFS export on the server (`192.168.50.106`) is configured appropriately.
- **Recommended**: `no_root_squash` if you trust the K8s nodes, allowing the init container to perform `chown`.
- **Alternative**: `all_squash` with `anonuid=1000,anongid=1000` to force all operations to be user 1000 (simplest but less granular).

## Implementation Steps

### Step 1: Modify `k8s/helm/manifests/calibre-web.yaml`
Apply the following changes to the Deployment:

```yaml
spec:
  template:
    spec:
      securityContext:
        fsGroup: 1000
      initContainers:
        - name: fix-permissions
          image: busybox
          command: ["sh", "-c", "chown -R 1000:1000 /config /calibre-library /cwa-book-ingest"]
          volumeMounts:
            - name: config
              mountPath: /config
            - name: books
              mountPath: /calibre-library
            - name: books
              mountPath: /cwa-book-ingest
              subPath: ingest
```

### Step 2: Apply Changes
```bash
kubectl apply -f k8s/helm/manifests/calibre-web.yaml
```

### Step 3: Verification
1. Restart the pod: `kubectl rollout restart deployment calibre-web -n personal-services`.
2. Check logs of the init container: `kubectl logs -l app=calibre-web -n personal-services -c fix-permissions`.
3. Exec into the main container and verify ownership:
   ```bash
   kubectl exec -it deploy/calibre-web -n personal-services -- ls -la /calibre-library
   ```
4. Perform a test upload in the web UI.

## Risks & Mitigations
- **Large Library Performance**: Running `chown -R` on a very large NFS library can be slow and might delay pod startup.
  - *Mitigation*: If the library is huge (>100GB), change the command to only fix the top-level directories or use a more targeted `find` command.
- **NFS Server Restrictions**: If the NFS server has `root_squash` enabled, the `initContainer` (running as root) might fail to `chown`.
  - *Mitigation*: Set `no_root_squash` on the NFS server or manually `chown` from the NFS server side.
