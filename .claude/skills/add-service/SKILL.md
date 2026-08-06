---
name: add-service
description: Add a new service to the homelab. Creates the K8s manifest, gateway HTTPRoute, homepage entry, and Uptime Kuma monitor. DNS is automatic (external-dns). Use when the user wants to deploy a new application or self-hosted service.
argument-hint: [service-name]
allowed-tools: Read, Edit, Write, Glob, Grep, Bash(kubectl *), Bash(dig *), Bash(curl *), Bash(cd /Users/matthew/projects/homelab && git *)
---

## Add New Homelab Service: $ARGUMENTS

This homelab uses **ArgoCD GitOps**: once changes are pushed to `main`, ArgoCD auto-deploys within 3 minutes. No manual `kubectl apply` needed for service manifests.

**DNS needs no manual step** (since 2026-07-20). Both tunnels have a single wildcard `*.meirong.dev` route, and external-dns creates each subdomain's CNAME from its HTTPRoute. Writing the HTTPRoute *is* the DNS change — do **not** touch `cloudflare/terraform`.

### Step 1 — Gather information

Ask the user (or infer from context) the following:

| Field | Example |
|-------|---------|
| **Cluster** | `oracle-k3s` (default for new personal services) / `homelab` |
| Service name (lowercase, hyphenated) | `my-app` |
| Subdomain | `myapp` → `myapp.meirong.dev` |
| Docker image | `ghcr.io/author/my-app:latest` |
| Container port | `8080` |
| Service port | `8080` |
| Namespace | `personal-services` (default) |
| Homepage section (个人服务 / 监控 / 基础设施) | `个人服务` |
| Homepage description (Chinese preferred) | `我的应用` |
| Homepage icon (from walkxcode/dashboard-icons) | `my-app.png` |
| Needs persistent storage? | yes/no |
| Needs external secrets? | yes/no |

**Cluster choice matters** — the two have different file layouts, gateways, and registration steps (table below). Default to **oracle-k3s** for stateless personal services; choose **homelab** only when the service needs homelab-local data, the Vault/Prometheus stack, or GPU/LAN access (homelab is also a thermally-constrained single laptop node).

⚠️ **oracle-k3s is NOT roomy any more.** It was downsized 4 OCPU/24GB → **2 OCPU / 12GB** on 2026-08-05, and that is a one-way move (ap-osaka-1 A1 Free Tier has no capacity to grow back). Only **1800m** is allocatable and CPU requests already sit around **76%** of it. So: set `requests` from measured usage (10–25m covers most apps — compare `trends`, which runs on 15m), and put non-core services on `priorityClassName: meirong-bulk`. Do not copy the 50m–100m figures that upstream reference manifests tend to use.

⚠️ **oracle-k3s is arm64.** Verify the image publishes a `linux/arm64` variant before choosing it. When pinning by digest, use the **multi-arch manifest-list digest**, not an amd64 image digest.

| | homelab | oracle-k3s |
|---|---|---|
| Manifest | `k8s/helm/manifests/personal-services/<service>.yaml` | `cloud/oracle/manifests/personal-services/<service>.yaml` |
| HTTPRoute lives in | its own `k8s/helm/manifests/gateway/route-<service>.yaml` | the same file as the Deployment |
| Gateway parentRef | `homelab-gateway`, ns `kube-system`, **port 80** | `oracle-gateway`, ns `kube-system`, **port 80** |
| Registration | none — files in `k8s/helm/manifests/personal-services/` are picked up automatically | add path to `cloud/oracle/manifests/kustomization.yaml` `resources` |

### Step 2 — Create the Deployment + Service manifest

Use this template (adjust ports and add storage/env as needed):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <service-name>
  namespace: <namespace>
  labels:
    app: <service-name>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <service-name>
  template:
    metadata:
      labels:
        app: <service-name>
    spec:
      containers:
        - name: <service-name>
          image: <image>
          ports:
            - containerPort: <container-port>
---
apiVersion: v1
kind: Service
metadata:
  name: <service-name>
  namespace: <namespace>
spec:
  selector:
    app: <service-name>
  ports:
    - protocol: TCP
      port: <service-port>
      targetPort: <container-port>
```

**Storage**: if a PVC is needed, use `storageClassName: local-path` — k3s's built-in node-local default, and the only storage class on either cluster. (The `nfs-client` provisioner was **uninstalled 2026-07-11**; a PVC referencing it will stay `Pending` forever.) `local-path` has no redundancy, so anything irreplaceable must also be added to the restic backup — see `docs/runbooks/backup-recovery.md`.

If the PVC holds important data (e.g. media libraries), add the `argocd.argoproj.io/sync-options: Prune=false` annotation to protect it from accidental deletion.

**Resource requests**: set explicit `resources.requests`/`limits`. On homelab a LimitRange (`personal-services-defaults`) injects defaults and Kyverno audits `require-requests-limits`; oracle-k3s has neither, so an unbounded pod there is genuinely unbounded.

### Step 3 — Add the HTTPRoute

On **homelab**, create a new file `k8s/helm/manifests/gateway/route-<service-name>.yaml` — one route per file since the 2026-07-31 directory reorg; `gateway.yaml` now holds only the GatewayClass + Gateway itself. On **oracle-k3s**, append to the service's own manifest file. Always include all explicit fields to prevent ArgoCD OutOfSync drift:

```yaml
---
# HTTPRoute: <subdomain>.meirong.dev -> <service-name>
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <service-name>
  namespace: <namespace>
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: <homelab-gateway|oracle-gateway>
      namespace: kube-system
      port: 80          # both gateways listen on 80; TLS terminates at the Cloudflare edge
  hostnames:
    - "<subdomain>.meirong.dev"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: <service-name>
          port: <service-port>
          weight: 1
```

This HTTPRoute is also what creates the DNS record: external-dns watches `gateway-httproute` sources and writes a proxied CNAME + ownership TXT for each hostname. `policy: upsert-only` means **deleting the HTTPRoute does not delete the DNS record** — clean it up by hand if you retire the service.

⚠️ **首次部署必查 `ResolvedRefs`（homelab 侧的排序竞态，2026-08-01 实测）**：路由由 `gateway` App 同步、
工作负载由另一个 App 同步，两者没有先后保证。若路由先落地，Cilium 会记下
`ResolvedRefs=False / BackendNotFound`，而且 **Service 后来创建时它不会自动重算**（`observedGeneration`
停在 1，等 5 分钟也不动），表现为 `gateway` App 一直 Degraded、域名 503。碰一下路由即可强制 reconcile：

```bash
kubectl -n <namespace> get httproute <name> \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}{"\n"}'   # 期望 True
kubectl -n <namespace> annotate httproute <name> reconcile-nudge="$(date +%s)" --overwrite
kubectl -n <namespace> annotate httproute <name> reconcile-nudge-      # 生效后把注解删掉，避免 git 之外的漂移
```

**Important**: the Gateway lives in `kube-system`, so cross-namespace backend refs need a ReferenceGrant in the *target* namespace. Grants already exist for homelab `personal-services`/`monitoring`/`vault`/`argocd`/`bifrost` and oracle `personal-services`/`homepage`/`rss-system` — verify with `kubectl get referencegrant -A`. For any other namespace, prepend:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-to-<namespace>
  namespace: <namespace>
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: <namespace>
  to:
    - group: ""
      kind: Service
```

⚠️ ReferenceGrant is **`v1beta1`** — it was never promoted to `v1`. Declaring `v1` breaks the whole Application with a `ComparisonError`.

### Step 4 — Register with GitOps

**homelab** — nothing to do. The `personal-services` App syncs the whole `k8s/helm/manifests/personal-services/` directory (one directory per Application since 2026-07-31, see `k8s/helm/manifests/README.md`), so the new file is picked up automatically on push.

**oracle-k3s** — add the path under `resources:` in `cloud/oracle/manifests/kustomization.yaml` (its kustomize tree is still an explicit list — a file not registered there silently does nothing):

```yaml
  - personal-services/<service-name>.yaml
```

If the service belongs to a different logical group (e.g. infrastructure), put it in the matching `k8s/helm/manifests/<app>/` directory instead, or create a new directory plus an Application under `argocd/applications/` pointing at it (the `root` App-of-Apps picks it up on push).

### Step 5 — Add service to homepage

Homepage runs on oracle-k3s. Edit `cloud/oracle/manifests/homepage/homepage.yaml`, find the correct section under `services.yaml:` in the ConfigMap, and add:

```yaml
        - <Display Name>:
            icon: <icon>.png
            href: https://<subdomain>.meirong.dev
            description: <Chinese description>
            kubernetes:
              namespace: <namespace>
              container: <service-name>
              label_selector: app=<service-name>
```

⚠️ The ConfigMap is mounted via `subPath`, so ArgoCD syncing it does **not** reload the pod — a `rollout restart` of the homepage Deployment is needed for the entry to appear.

### Step 6 — Add an Uptime Kuma monitor

Append an entry to the `MONITORS` list in the `uptime-kuma-provisioner` ConfigMap at `cloud/oracle/manifests/uptime-kuma/provisioner.yaml`:

```python
    {"name": "My Service", "url": "http://<service-name>.<namespace>.svc:<port>"},
```

Use the in-cluster Service URL for oracle-k3s services, and the public `https://<subdomain>.meirong.dev` URL for homelab ones. For services that redirect to a login page, add `"accepted_statuscodes": ["300-399"], "maxredirects": 0`.

The provisioner is declarative and **prunes monitors not in the list**, so this is also how you retire one. An ArgoCD PostSync hook re-runs the Job on push.

### Step 7 — Commit and push (triggers ArgoCD auto-deploy)

```bash
cd /Users/matthew/projects/homelab
git add <the files you touched>
git commit -m "feat: add <service-name> service"
git push origin main
```

ArgoCD syncs within ~3 minutes — no manual `kubectl apply` needed.

### Step 8 — Verify

```bash
kubectl --context <k3s-homelab|oracle-k3s> get pods -n <namespace> -l app=<service-name>
kubectl --context <k3s-homelab|oracle-k3s> rollout status deployment/<service-name> -n <namespace>
```

Then confirm DNS and the public endpoint (external-dns reconciles on its own interval, so the record may lag the sync by a minute):

```bash
dig +short <subdomain>.meirong.dev
curl -sS -o /dev/null -w '%{http_code}\n' https://<subdomain>.meirong.dev
```

Or check the ArgoCD UI at `https://argocd.meirong.dev` — the Application should show `Synced + Healthy`.

Confirm the pod is Running and report the final URL: `https://<subdomain>.meirong.dev`
