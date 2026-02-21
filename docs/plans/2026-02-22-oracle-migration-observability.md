# Oracle K3s Migration & Cross-Cluster Observability

**Date:** 2026-02-22
**Status:** Approved, ready for implementation

## Goal

1. **Migrate Homepage and Uptime Kuma** from k3s-homelab to oracle-k3s.
2. **Deploy cross-cluster observability** on oracle-k3s, sending metrics and logs back to the homelab monitoring stack (Prometheus, Loki, Grafana).
3. **Add PostgreSQL monitoring** with a dedicated Grafana dashboard.
4. Achieve a unified Grafana view that covers **both clusters** from a single pane of glass.

---

## Current State

### oracle-k3s (4 OCPUs ARM, 24GB RAM — Oracle Cloud Free Tier)

| Component | Namespace | Notes |
|-----------|-----------|-------|
| Miniflux | `rss-system` | RSS reader + PostgreSQL sidecar |
| RSSHub | `rss-system` | RSS feed generator |
| n8n | `rss-system` | Workflow automation |
| cloudflared | `cloudflare` | Independent tunnel (ID: `bc630e77`) |
| Traefik | `kube-system` | Gateway API enabled |
| ESO | `external-secrets` | ClusterSecretStore → Vault via Tailscale |

**Resource usage:** CPU 61m/4000m (1%), Memory 2039Mi/22456Mi (9%) — ample headroom.

### k3s-homelab (Proxmox single-node)

| Component | Namespace | Notes |
|-----------|-----------|-------|
| Homepage | `homepage` | Dashboard at `home.meirong.dev` |
| Uptime Kuma | `personal-services` | Status page at `status.meirong.dev` |
| Prometheus + Grafana + Alertmanager | `monitoring` | kube-prometheus-stack |
| Loki | `monitoring` | SingleBinary, filesystem storage, 7-day retention |
| Tempo | `monitoring` | Trace backend |
| OTel Collector | `monitoring` | DaemonSet: filelog → k8sattributes → Loki |
| Vault | `vault` | Secret management, NodePort 31144 |
| ArgoCD | `argocd` | GitOps for homelab apps |

### Network Topology

```
                  Internet
                     │
        ┌────────────┴────────────┐
        ▼                         ▼
  Cloudflare Tunnel          Cloudflare Tunnel
  (homelab ce9fd9fe)         (oracle bc630e77)
        │                         │
        ▼                         ▼
  k3s-homelab                oracle-k3s
  10.10.10.10                152.69.195.151
  TS: 100.107.254.112        TS: 100.107.166.37
        │                         │
        └────── Tailscale ────────┘
              (private mesh)
```

---

## Architecture Design

### Phase 1 — Migrate Homepage & Uptime Kuma

#### Homepage

**Changes from homelab version:**
- Remove `NodePort` service → use `ClusterIP` (routed via Traefik Gateway API)
- Remove homelab-specific K8s service discovery references (calibre-web, it-tools, etc.) from `services.yaml` — replace with oracle-k3s services
- Keep RBAC (ServiceAccount + ClusterRole) for K8s widget support
- No persistent storage needed (stateless)

**Namespace:** `homepage` (dedicated, same as homelab)

#### Uptime Kuma

**Changes from homelab version:**
- Replace `storageClassName: nfs-client` → `local-path` (oracle-k3s has no NFS)
- Reduce PVC size: 10Gi → 2Gi (status data is tiny)
- Remove ArgoCD annotations (`argocd.argoproj.io/sync-options`, hook annotations)
- Change provisioner Job from ArgoCD PostSync hook → standalone Job (run manually via `just`)
- ExternalSecret: change Vault path from `homelab/uptime-kuma` → `oracle-k3s/uptime-kuma`
- Add RSS-related monitors to the provisioner (rss.meirong.dev)

**Namespace:** `personal-services` (dedicated, for uptime-kuma)

#### Cloudflare & Gateway Updates

**Oracle Cloudflare Terraform** (`cloud/oracle/cloudflare/terraform.tfvars`):
```hcl
ingress_rules = {
  "rss"    = { service = "http://traefik.kube-system.svc:80" }
  "home"   = { service = "http://traefik.kube-system.svc:80" }
  "status" = { service = "http://traefik.kube-system.svc:80" }
}
```

**Homelab Cloudflare Terraform** (`cloudflare/terraform/terraform.tfvars`):
- Remove `"home"` and `"status"` entries (they move to oracle tunnel)

**Oracle Gateway** (`cloud/oracle/manifests/base/gateway.yaml`):
- Add HTTPRoutes for `home.meirong.dev → homepage:3000` (ns: homepage)
- Add HTTPRoute for `status.meirong.dev → uptime-kuma:3001` (ns: personal-services)
- Add ReferenceGrants for cross-namespace routing

**Homelab Gateway** (`k8s/helm/manifests/gateway.yaml`):
- Remove HTTPRoutes for `home.meirong.dev` and `status.meirong.dev`

### Phase 2 — Cross-Cluster Observability

#### Design Principles

1. **Homelab is the monitoring hub** — all telemetry flows to the existing LGTM stack
2. **Oracle-k3s is a remote data source** — runs lightweight collectors that export via Tailscale
3. **No duplicate storage** — oracle-k3s does not run Loki, Prometheus, or Grafana
4. **Unified labels** — `cluster` label on all metrics/logs to distinguish origin

#### Logs: OTel Collector → Homelab Loki

Deploy an OTel Collector DaemonSet on oracle-k3s, identical architecture to homelab's existing collector:

```
oracle-k3s:
  /var/log/pods/**/*.log
      ↓ filelog receiver
  OTel Collector DaemonSet (monitoring namespace)
      ↓ k8sattributes processor (inject pod/namespace/node metadata)
      ↓ resource processor (add cluster=oracle-k3s)
      ↓ batch processor
      ↓ otlphttp exporter
      │
      │  HTTP via Tailscale (100.107.254.112)
      ▼
  k3s-homelab:
      Loki Gateway (:80/otlp) → Loki SingleBinary → Grafana
```

**Key difference from homelab collector:** The exporter URL points to the homelab Loki via Tailscale IP instead of cluster-internal service:
```yaml
exporters:
  otlphttp:
    endpoint: "http://100.107.254.112:80"  # Loki Gateway via Tailscale
    # Loki Gateway on homelab is ClusterIP — needs NodePort or port-forward
```

**Problem:** Loki Gateway is a ClusterIP service on homelab (10.43.221.63:80). Oracle-k3s cannot reach it directly via Tailscale since Tailscale only exposes the node IP, not cluster IPs.

**Solution:** Create a NodePort service for Loki Gateway on homelab:
```yaml
# On k3s-homelab: loki-gateway-external NodePort
apiVersion: v1
kind: Service
metadata:
  name: loki-gateway-external
  namespace: monitoring
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: loki
    app.kubernetes.io/component: gateway
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 31080  # Loki Gateway
```

Then the oracle OTel exporter targets: `http://100.107.254.112:31080/otlp`

#### Metrics: Prometheus Remote Write → Homelab Prometheus

Deploy a lightweight Prometheus instance (via `kube-prometheus-stack` with most components disabled) on oracle-k3s that scrapes local targets and remote-writes to homelab:

```
oracle-k3s:
  prometheus-agent (monitoring namespace)
      ↓ scrape: node-exporter, kube-state-metrics, postgres-exporter
      ↓ external_labels: {cluster: "oracle-k3s"}
      ↓ remote_write
      │
      │  HTTP via Tailscale (100.107.254.112)
      ▼
  k3s-homelab:
      Prometheus (:9090 via NodePort 31090) → Grafana
```

**Homelab Prometheus NodePort:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: prometheus-external
  namespace: monitoring
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: prometheus
    operator.prometheus.io/name: kube-prometheus-stack-prometheus
  ports:
    - port: 9090
      targetPort: 9090
      nodePort: 31090
```

**Oracle-k3s Prometheus config (agent mode, minimal):**
- `prometheusSpec.remoteWrite` → `http://100.107.254.112:31090/api/v1/write`
- `prometheusSpec.externalLabels.cluster: oracle-k3s`
- Disable: Grafana, Alertmanager, Prometheus persistence (agent mode)
- Enable: node-exporter, kube-state-metrics (lightweight)

**Homelab Prometheus update:**
- Add `externalLabels.cluster: homelab` to distinguish local metrics
- Enable remote write receiver: `prometheusSpec.enableRemoteWriteReceiver: true`

### Phase 3 — PostgreSQL Monitoring

#### postgres-exporter Sidecar

The miniflux deployment on oracle-k3s already runs PostgreSQL as a sidecar container. Add a `postgres-exporter` sidecar to expose metrics:

```yaml
# Added to miniflux.yaml deployment
- name: postgres-exporter
  image: prometheuscommunity/postgres-exporter:v0.16.0
  ports:
    - containerPort: 9187
      name: metrics
  env:
    - name: DATA_SOURCE_NAME
      value: "postgresql://miniflux:$(POSTGRES_PASSWORD)@localhost:5432/miniflux?sslmode=disable"
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 64Mi
```

#### ServiceMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: postgres-exporter
  namespace: rss-system
  labels:
    release: kube-prometheus-stack  # matches Prometheus serviceMonitorSelector
spec:
  selector:
    matchLabels:
      app: miniflux
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

#### Grafana Dashboard

Import the community PostgreSQL dashboard (ID: `9628` — "PostgreSQL Database") into homelab Grafana. This dashboard covers:
- Active connections, transactions/sec, cache hit ratio
- Tuple operations (inserts, updates, deletes, reads)
- Database size, bloat, replication lag
- Lock monitoring, deadlocks

The dashboard works automatically once postgres-exporter metrics arrive at homelab Prometheus via remote write.

---

## Implementation Plan

### Pre-requisites

1. Store uptime-kuma credentials in Vault:
   ```bash
   vault kv put secret/oracle-k3s/uptime-kuma \
     admin_username=admin \
     admin_password=<password>
   ```

### Step 1 — Homelab: Create External NodePort Services

Create NodePort services on homelab so oracle-k3s can reach Loki and Prometheus via Tailscale.

**File:** `k8s/helm/manifests/monitoring-external.yaml`
- `loki-gateway-external` NodePort 31080
- `prometheus-external` NodePort 31090

**Apply:** `kubectl --context k3s-homelab apply -f k8s/helm/manifests/monitoring-external.yaml`

### Step 2 — Homelab: Enable Prometheus Remote Write Receiver

Update `k8s/helm/values/kube-prometheus-stack.yaml`:
- Add `enableRemoteWriteReceiver: true` to `prometheus.prometheusSpec`
- Add `externalLabels: {cluster: homelab}`

**Apply:** `cd k8s/helm && just deploy-monitoring` (or `helm upgrade`)

### Step 3 — Homelab: Add cluster label to OTel Collector

Update `k8s/helm/values/opentelemetry-collector.yaml`:
- Add resource processor to inject `cluster=homelab` attribute

### Step 4 — Oracle: Create Observability Manifests

**Directory:** `cloud/oracle/manifests/monitoring/`

| File | Contents |
|------|----------|
| `namespace.yaml` | monitoring namespace |
| `otel-collector.yaml` | DaemonSet: filelog → k8sattributes → resource(cluster=oracle-k3s) → batch → otlphttp(homelab Loki) |
| `prometheus-stack.yaml` | HelmChartConfig for kube-prometheus-stack in agent mode: node-exporter + kube-state-metrics + remote_write to homelab |
| `postgres-exporter.yaml` | Sidecar addition + ServiceMonitor (or standalone deployment) |

### Step 5 — Oracle: Deploy Homepage

**Directory:** `cloud/oracle/manifests/homepage/`

| File | Contents |
|------|----------|
| `namespace.yaml` | homepage namespace |
| `homepage.yaml` | ServiceAccount, RBAC, ConfigMap (updated for oracle services), Deployment, Service |

### Step 6 — Oracle: Deploy Uptime Kuma

**Directory:** `cloud/oracle/manifests/uptime-kuma/`

| File | Contents |
|------|----------|
| `namespace.yaml` | personal-services namespace |
| `uptime-kuma.yaml` | PVC (local-path), Deployment, Service |
| `secrets.yaml` | ExternalSecret (Vault: oracle-k3s/uptime-kuma) |
| `provisioner.yaml` | ConfigMap + Job (manual trigger, not ArgoCD hook) |

### Step 7 — Oracle: Update Gateway & Cloudflare

- Add HTTPRoutes for `home.meirong.dev` and `status.meirong.dev` to `cloud/oracle/manifests/base/gateway.yaml`
- Add ReferenceGrants for `homepage` and `personal-services` namespaces
- Update `cloud/oracle/cloudflare/terraform.tfvars`: add `home` and `status` ingress rules
- Apply terraform: `cd cloud/oracle/cloudflare && just apply`

### Step 8 — Homelab: Remove Migrated Services

- Remove `home` and `status` HTTPRoutes from `k8s/helm/manifests/gateway.yaml`
- Remove `home` and `status` from `cloudflare/terraform/terraform.tfvars`
- Apply homelab cloudflare terraform: `cd cloudflare/terraform && just apply`
- (Optional) Delete homelab Homepage/Uptime Kuma deployments after verifying oracle

### Step 9 — Oracle: Deploy All & Verify

```bash
cd cloud/oracle
just deploy-manifests        # Apply all kustomize manifests
just deploy-cloudflare-dns   # Apply Cloudflare terraform
```

Verification:
- `curl -s -o /dev/null -w '%{http_code}' https://home.meirong.dev` → 200
- `curl -s -o /dev/null -w '%{http_code}' https://status.meirong.dev` → 200
- Grafana: check Loki for `{cluster="oracle-k3s"}` logs
- Grafana: check Prometheus for `{cluster="oracle-k3s"}` metrics
- Grafana: import PostgreSQL dashboard, verify miniflux-db metrics

### Step 10 — PostgreSQL Grafana Dashboard

- Import dashboard ID `9628` into Grafana
- Customize: filter by `cluster="oracle-k3s"`, `job="postgres-exporter"`
- (Alternative: provision via ConfigMap + Grafana sidecar if desired)

---

## Oracle K3s Manifest Directory Structure (Final)

```
cloud/oracle/manifests/
├── kustomization.yaml
├── base/
│   ├── vault-store.yaml          # ClusterSecretStore → Vault via Tailscale
│   ├── cloudflare-tunnel.yaml    # cloudflared deployment + ExternalSecret
│   └── gateway.yaml              # Gateway + all HTTPRoutes
├── rss-system/
│   ├── namespace.yaml
│   ├── secrets.yaml              # ExternalSecrets for miniflux
│   ├── miniflux.yaml             # + postgres-exporter sidecar
│   ├── rsshub.yaml
│   └── n8n.yaml
├── homepage/
│   ├── namespace.yaml
│   └── homepage.yaml             # RBAC + ConfigMap + Deployment + Service
├── uptime-kuma/
│   ├── namespace.yaml
│   ├── uptime-kuma.yaml          # PVC + Deployment + Service
│   ├── secrets.yaml              # ExternalSecret
│   └── provisioner.yaml          # ConfigMap + Job
└── monitoring/
    ├── namespace.yaml
    ├── otel-collector.yaml       # DaemonSet → homelab Loki via Tailscale
    └── prometheus-agent.yaml     # HelmChartConfig: agent mode → homelab Prometheus
```

---

## Resource Budget (oracle-k3s)

| Component | CPU Request | Memory Request | Memory Limit |
|-----------|-------------|----------------|--------------|
| Existing (rss-system + cloudflared) | ~350m | ~1228Mi | ~3882Mi |
| Homepage | 50m | 128Mi | 256Mi |
| Uptime Kuma | 50m | 128Mi | 256Mi |
| OTel Collector (DaemonSet) | 50m | 64Mi | 256Mi |
| Prometheus Agent | 100m | 256Mi | 512Mi |
| Node Exporter | 50m | 64Mi | 128Mi |
| Kube State Metrics | 50m | 64Mi | 128Mi |
| postgres-exporter | 10m | 32Mi | 64Mi |
| **Total New** | **360m** | **736Mi** | **1600Mi** |
| **Grand Total** | **~710m** | **~1964Mi** | **~5482Mi** |

Available: 4000m CPU, 22456Mi Memory. **Utilization after migration: ~18% CPU, ~9% Memory** — well within capacity.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Tailscale link down → observability gap | Logs/metrics stop flowing to homelab | OTel Collector has batch/retry; Prometheus has WAL. Data queues and catches up when link restores. |
| Loki/Prometheus NodePort exposed on homelab node | Security surface increase | Tailscale ACLs restrict access to known nodes only; NodePorts only reachable via Tailscale IP |
| Homepage loses K8s service discovery for homelab services | Dashboard shows fewer services | Update services.yaml to reflect oracle-k3s services; homelab services reference by external URL |
| Uptime Kuma data loss on migration | Historical monitoring data lost | Acceptable — Uptime Kuma starts fresh on oracle-k3s with provisioner recreating monitors |
| PostgreSQL exporter adds load to miniflux-db | Slight performance impact | Exporter is read-only, 30s scrape interval, minimal overhead |

---

## Rollback Plan

1. Re-add `home` and `status` to homelab Cloudflare terraform and apply
2. Re-add HTTPRoutes to homelab gateway.yaml
3. ArgoCD auto-syncs homelab Homepage/Uptime Kuma back
4. Remove oracle manifests: `kubectl --context oracle-k3s delete -k manifests/`
