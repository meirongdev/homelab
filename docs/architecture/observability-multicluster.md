# Multi-Cluster Observability Architecture

> Date: 2026-02-22  
> Status: Production

## Overview

Two k3s clusters are monitored from a single Grafana/Loki/Prometheus stack on the homelab cluster. Cross-cluster connectivity is provided by Tailscale.

```
┌─────────────────────────────────────┐     Tailscale     ┌─────────────────────────────────────┐
│          k3s-homelab                │◄──────────────────►│          oracle-k3s                 │
│  (100.107.254.112)                  │                    │  (100.107.166.37)                   │
│                                     │                    │                                     │
│  Grafana  ◄── Loki  ◄── NodePort    │◄── OTLP logs ──── │  OTel DaemonSet                     │
│  Grafana  ◄── Prometheus            │◄── scrape ──────── │  node-exporter :9100                │
│                          :31080     │                    │  kube-state-metrics :31082          │
│                          :31090     │                    │  postgres-exporter :31087            │
└─────────────────────────────────────┘                    └─────────────────────────────────────┘
```

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

### Oracle k3s → Homelab Prometheus

**Mechanism:** Homelab Prometheus pulls (scrape) oracle metrics over Tailscale — no push required.

**Configuration:** `k8s/helm/values/kube-prometheus-stack.yaml` → `additionalScrapeConfigs`

| Job | Target | Labels |
|-----|--------|--------|
| `oracle-k3s-node-exporter` | `100.107.166.37:9100` | `cluster=oracle-k3s` |
| `oracle-k3s-kube-state-metrics` | `100.107.166.37:31082` | `cluster=oracle-k3s` |
| `oracle-k3s-postgres-exporter` | `100.107.166.37:31087` | `cluster=oracle-k3s` |

**Exposed NodePorts on oracle-k3s:** (`cloud/oracle/manifests/monitoring/exporters.yaml`)

| Service | NodePort | Target |
|---------|----------|--------|
| `node-exporter` | 9100 | node-exporter pod |
| `kube-state-metrics` | 31082 | kube-state-metrics pod |
| `postgres-exporter` | 31087 | postgres-exporter pod |

### Homelab Prometheus → itself

Standard kube-prometheus-stack in-cluster scraping.

## NodePort Services on Homelab

`k8s/helm/manifests/monitoring-external.yaml`

| Service | NodePort | Purpose |
|---------|----------|---------|
| `loki-gateway-external` | 31080 | Receives OTLP logs from oracle OTel |
| `prometheus-external` | 31090 | Exposes Prometheus for future remote_write |

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

1. Check Prometheus targets: Grafana → Explore → Prometheus → `up{cluster="oracle-k3s"}`
2. Verify NodePorts accessible: `curl http://100.107.166.37:9100/metrics | head -5`
