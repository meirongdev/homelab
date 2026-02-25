# Multi-Cluster Observability Architecture

> Date: 2026-02-25
> Status: Production

## Overview

Two k3s clusters are monitored from a single Grafana/Loki/Prometheus stack on the homelab cluster. Cross-cluster connectivity is provided by Tailscale. All oracle-k3s telemetry (logs + metrics) is pushed via a single OTel Collector DaemonSet.

```
┌─────────────────────────────────────┐     Tailscale     ┌─────────────────────────────────────┐
│          k3s-homelab                │                    │          oracle-k3s                 │
│  (100.107.254.112)                  │                    │  (100.107.166.37)                   │
│                                     │                    │                                     │
│  Grafana ◄── Loki      :31080/otlp │◄── logs (OTLP) ─── │  OTel Collector DaemonSet           │
│  Grafana ◄── Prometheus :31090     │◄── metrics (PRW) ── │    ├ filelog → logs pipeline         │
│                                     │                    │    ├ prometheus/node-exporter        │
│  scrapeClasses:                     │                    │    ├ prometheus/kube-state-metrics   │
│    cluster=homelab (all local jobs) │                    │    ├ prometheus/cloudflared          │
│                                     │                    │    └ prometheus/traefik              │
│  OTel Collector (homelab logs)      │                    │  node-exporter (hostNetwork:9100)    │
│  node-exporter, kube-state-metrics  │                    │  kube-state-metrics (:8080)          │
└─────────────────────────────────────┘                    └─────────────────────────────────────┘
```

## Cluster Label Strategy

All metrics carry a `cluster` label for multi-cluster dashboard queries:

| Cluster | Mechanism | Label |
|---------|-----------|-------|
| homelab (local scrape) | Prometheus `scrapeClasses` with default relabeling | `cluster=homelab` |
| homelab (metal nodes: proxmox, storage) | `additionalScrapeConfigs` with explicit label | `cluster=homelab` |
| oracle-k3s (all metrics) | OTel `resource` processor + `prometheusremotewrite` `external_labels` | `cluster=oracle-k3s` |

## Log Pipeline

### Oracle k3s → Homelab Loki

**Component:** `cloud/oracle/manifests/monitoring/otel-collector.yaml`

**Pipeline:** `filelog → k8sattributes → resource → batch → otlphttp`

**Key configuration details:**

1. **filelog receiver** reads `/var/log/pods/*/*/*.log` (containerd format)
2. **Filepath regex** extracts `namespace`, `pod_name`, `uid`, `container_name` from the log file path
3. **Move operators** promote extracted values to OTel resource attributes:
   - `attributes.uid` → `resource["k8s.pod.uid"]`
   - `attributes.namespace` → `resource["k8s.namespace.name"]`
   - `attributes.pod_name` → `resource["k8s.pod.name"]`
   - `attributes.container_name` → `resource["k8s.container.name"]`
4. **k8sattributes processor** uses `k8s.pod.uid` (resource attribute) to look up the pod in the K8s API and enrich with `k8s.deployment.name`, `k8s.node.name`, etc.
5. **resource processor** adds `cluster: oracle-k3s` label
6. **otlphttp exporter** ships to `http://100.107.254.112:31080/otlp/v1/logs` (Loki gateway NodePort via Tailscale)

> **Bug fixed 2026-02-22:** The original config did not promote filepath-extracted attributes to resource attributes, so `k8sattributes` could never find the pod (all identifier values were empty strings). Logs arrived in Loki as `unknown_service` with no namespace/pod labels.

### Homelab → Loki (built-in)

**Component:** `opentelemetry-collector-agent` DaemonSet (deployed via Helm `opentelemetry-collector` chart)

Uses the `container` operator type which automatically handles filepath parsing and k8s attribute association. Exports directly to `loki-gateway.monitoring.svc.cluster.local`.

### Loki Label Mapping

OTel resource attributes are converted to Loki stream labels (dots replaced with underscores):

| OTel Resource Attribute | Loki Label |
|------------------------|------------|
| `cluster` | `cluster` |
| `k8s.namespace.name` | `k8s_namespace_name` |
| `k8s.pod.name` | `k8s_pod_name` |
| `k8s.deployment.name` | `k8s_deployment_name` |
| `k8s.container.name` | `k8s_container_name` |
| `service.name` | `service_name` |

## Metrics Pipeline

### Oracle k3s → Homelab Prometheus (push via OTel)

**Component:** `cloud/oracle/manifests/monitoring/otel-collector.yaml`

**Mechanism:** OTel Collector scrapes local exporters and pushes via `prometheusremotewrite` to homelab Prometheus over Tailscale. No prometheus-agent needed.

| OTel Receiver | Target | Interval |
|---------------|--------|----------|
| `prometheus/node-exporter` | `10.0.0.26:9100` (hostNetwork) | 15s |
| `prometheus/kube-state-metrics` | `kube-state-metrics.monitoring.svc:8080` | 30s |
| `prometheus/cloudflared` | `cloudflared-metrics.cloudflare.svc:2000` | 30s |
| `prometheus/traefik` | `traefik-metrics.kube-system.svc:9100` | 15s |

All metrics pass through `resource` processor (adds `cluster: oracle-k3s`) → `batch` → `prometheusremotewrite` exporter → `http://100.107.254.112:31090/api/v1/write`

### Homelab Prometheus (local scrape)

Standard kube-prometheus-stack in-cluster scraping with `scrapeClasses` default relabeling (`cluster: homelab`).

**Additional scrape targets** (`additionalScrapeConfigs`):

| Job | Target | Labels |
|-----|--------|--------|
| `node-exporter-metal-nodes` | `192.168.50.106:9100` (storage-node) | `cluster=homelab` |
| `node-exporter-metal-nodes` | `192.168.50.4:9100` (proxmox-node) | `cluster=homelab` |

## NodePort Services on Homelab

`k8s/helm/manifests/monitoring-external.yaml`

| Service | NodePort | Purpose |
|---------|----------|---------|
| `loki-gateway-external` | 31080 | Receives OTLP logs from oracle OTel |
| `prometheus-otlp-external` | 31090 | Receives Prometheus remote_write from oracle OTel |

> **Note:** kube-state-metrics NodePort (31082) on oracle-k3s is no longer used for cross-cluster scrape. OTel Collector scrapes it locally via ClusterIP and pushes via remote_write.

## Grafana Dashboards

All 4 Loki dashboards (`k8s/helm/manifests/grafana-dashboards.yaml`) have a `cluster` dropdown variable:

- **k8s-logs-overview** — log volume by namespace, grouped by cluster
- **k8s-logs-pod** — per-pod log browser, namespace filtered by cluster
- **k8s-logs-errors** — error rate aggregation, per cluster
- **k8s-logs-search** — full-text search across selected cluster(s)

Cloudflare Tunnel dashboard (`k8s/helm/manifests/cloudflare-tunnel-dashboard.yaml`):

- **Cloudflare Tunnel + Per-Domain Traffic** — tunnel health, Traefik router metrics by cluster

Multi-cluster resource overview (`k8s/helm/manifests/multicluster-overview-dashboard.yaml`):

- **Kubernetes / Multi-Cluster / Resource Overview** (`uid: k8s-multicluster-overview`) — node CPU/memory/disk/network, Pod status table, Deployment/StatefulSet health, container resource usage vs Limit; supports `cluster`, `namespace`, `phase` variables

**Dashboard variable configuration:**
```json
{
  "name": "cluster",
  "type": "query",
  "query": "label_values(cluster)",
  "multi": true,
  "includeAll": true,
  "allValue": ".+"
}
```

All LogQL queries use: `{cluster=~"${cluster}", service_namespace=~"..."}`

## Service Health Checks

All services have liveness and readiness probes configured:

### oracle-k3s

| Service | Probe Path | Port |
|---------|-----------|------|
| it-tools | `GET /` | 80 |
| stirling-pdf | `GET /api/v1/info` | 8080 |
| squoosh | `GET /` | 8080 |
| miniflux | `GET /healthcheck` | 8080 |
| n8n | `GET /healthz` | 5678 |
| rsshub | `GET /healthcheck` | 1200 |

### k3s-homelab

| Service | Probe Path | Port |
|---------|-----------|------|
| calibre-web | `GET /login` | 8083 |

## Troubleshooting

### Oracle logs show as `unknown_service` in Loki

**Cause:** k8sattributes processor cannot associate log with pod — filepath metadata not promoted to resource attributes.

**Check:** `kubectl --context oracle-k3s logs -n monitoring daemonset/otel-collector | grep "evaluating pod identifier"` — all source values should be non-empty.

**Fix:** Ensure the OTel config has `move` operators after `extract-metadata-from-filepath` to promote `uid`, `namespace`, `pod_name`, `container_name` to `resource["k8s.*"]` attributes.

### Loki not receiving oracle logs

1. Check Tailscale connectivity: `curl http://100.107.166.37:9100/metrics` (from homelab)
2. Check NodePort: `kubectl --context k3s-homelab get svc loki-gateway-external -n monitoring`
3. Check OTel pod: `kubectl --context oracle-k3s logs -n monitoring daemonset/otel-collector | grep "url:"`

### Prometheus not scraping oracle metrics

Oracle-k3s metrics are pushed (not scraped). Check the OTel Collector:

1. Check OTel logs: `kubectl --context oracle-k3s logs -n monitoring daemonset/otel-collector --tail=30`
2. Look for `Failed to scrape Prometheus endpoint` — means target is unreachable from within the pod
3. Verify Prometheus receives data: Grafana → Explore → Prometheus → `count by (cluster, job) ({cluster="oracle-k3s"})`
4. Check Tailscale connectivity: `kubectl --context oracle-k3s exec -n monitoring daemonset/otel-collector -- wget -qO- http://100.107.254.112:31090/api/v1/status/runtimeinfo 2>/dev/null | head`

### homelab metrics missing `cluster` label

**Cause:** Prometheus `externalLabels` only applies to remote_write/federation, not local queries.

**Fix:** Ensure `prometheusSpec.scrapeClasses` has a default class with `relabelings` that sets `cluster: homelab`. See `k8s/helm/values/kube-prometheus-stack.yaml`.
