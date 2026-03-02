# OTel Tracing & Collector Improvement Plan

> Date: 2026-03-01
> Status: Implementing

## Background

The homelab project has a mature OTel-based observability stack for **logs** and **metrics** across two clusters (homelab + oracle-k3s). However, **distributed tracing** (the "T" in LGTM) is not yet wired up — Tempo is deployed but no traces pipeline exists in either Collector, and no applications are instrumented.

### Current State

| Signal | homelab Collector | oracle-k3s Collector | Backend |
|--------|-------------------|----------------------|---------|
| Logs | filelog → k8sattributes → Loki (OTLP) | filelog → k8sattributes → Loki (OTLP via Tailscale) | Loki 3.x |
| Metrics | prometheus/cloudflared, traefik → Prometheus (OTLP) | prometheus/* → Prometheus (remote_write via Tailscale) | Prometheus |
| Traces | ❌ No pipeline | ❌ No pipeline | Tempo (deployed, idle) |

### Gaps Identified

1. **No traces pipeline** in either Collector — applications have nowhere to send spans even if instrumented
2. **No `memory_limiter` processor** — OOM risk under load spikes
3. **No `health_check` extension** — no liveness/readiness probes on Collector pods
4. **Collector version drift** — oracle-k3s pinned at `0.120.0`, homelab uses chart default
5. **No Tempo NodePort** — oracle-k3s traces cannot reach homelab Tempo
6. **Grafana Tempo datasource** incomplete — `tracesToLogs` lacks `filterByTraceID`/`filterBySpanID`, `tracesToMetrics` not configured, `nodeGraph` not enabled
7. **No sampling strategy** — 2Gi Tempo storage will fill quickly without head sampling
8. **No application instrumentation guidance** — no env var template or SDK examples for Go/Java/Node/Rust

## Design Decisions

### 1. Traces Pipeline Architecture

```
┌──────────────────────────────────────────────────────┐
│  Application Pod                                      │
│  OTEL_EXPORTER_OTLP_ENDPOINT=                        │
│    http://otel-collector.monitoring.svc:4318          │
│  (or for oracle-k3s, same local ClusterIP)           │
└────────────────────┬─────────────────────────────────┘
                     │ OTLP HTTP/gRPC
                     ▼
┌──────────────────────────────────────────────────────┐
│  OTel Collector (per cluster)                         │
│  receivers: otlp (grpc:4317, http:4318)              │
│  processors: memory_limiter → resource → batch       │
│  exporters:                                           │
│    homelab  → otlp://tempo.monitoring.svc:4317       │
│    oracle   → otlp://100.107.254.112:31317 (Tailscale)│
└──────────────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────┐
│  Tempo (homelab only)                                 │
│  OTLP gRPC :4317 / HTTP :4318                        │
│  Query :3100 → Grafana                                │
└──────────────────────────────────────────────────────┘
```

**Decision**: Direct OTLP to each cluster's local Collector, which forwards to homelab Tempo. No separate "gateway" Deployment — the existing DaemonSet/Helm Collector already runs on every node and can receive OTLP. Adding a Deployment gateway adds complexity without benefit for a single-node-per-cluster setup.

### 2. Sampling Strategy

- **Head sampling** at application SDK level: `parentbased_traceidratio` at 10% (`0.1`)
- Set via environment variables — no Collector-side tail sampling needed for now
- Tempo storage bumped from 2Gi → 5Gi to accommodate trace data

### 3. Memory Limiter

Add `memory_limiter` processor to all pipelines (logs, metrics, traces):
- `limit_mib: 200` (homelab) / `limit_mib: 200` (oracle)
- `spike_limit_mib: 50`
- `check_interval: 5s`

### 4. Health Check Extension

Add `health_check` extension to both Collectors, enabling Kubernetes liveness/readiness probes on `:13133`.

### 5. Grafana Datasource Improvements

Enhance Tempo datasource configuration:
- `tracesToLogs`: add `filterByTraceID: true`, `filterBySpanID: true`, tag mappings
- `tracesToMetrics`: link to Prometheus for RED metrics
- `nodeGraph.enabled: true` — visual service dependency graph
- `serviceMap.datasourceUid: prometheus` — service map powered by span metrics

### 6. Tempo NodePort for oracle-k3s

Add NodePort `31317` on homelab for Tempo gRPC receiver, so oracle-k3s Collector can push traces over Tailscale.

### 7. Application Instrumentation Template

Standardized env vars for any new service deployment:
```yaml
env:
  - name: OTEL_SERVICE_NAME
    value: "<service-name>"
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector.monitoring.svc.cluster.local:4318"
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "http/protobuf"
  - name: OTEL_TRACES_SAMPLER
    value: "parentbased_traceidratio"
  - name: OTEL_TRACES_SAMPLER_ARG
    value: "0.1"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "deployment.environment=prod,service.namespace=<namespace>"
```

Language-specific guidance:
- **Go**: `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp` + `otelgrpc`
- **Java/Spring Boot**: `-javaagent:opentelemetry-javaagent.jar` (zero-code)
- **Node.js**: `@opentelemetry/sdk-node` + `auto-instrumentations-node`
- **Rust**: `tracing` + `tracing-opentelemetry` + `opentelemetry-otlp`

## Implementation Checklist

- [x] Create this design document
- [ ] Add `otlp` receiver + `traces` pipeline to homelab Collector values
- [ ] Add `memory_limiter` + `health_check` to homelab Collector
- [ ] Add `otlp` receiver + `traces` pipeline to oracle-k3s Collector manifest
- [ ] Add `memory_limiter` + `health_check` to oracle-k3s Collector
- [ ] Add Tempo gRPC NodePort (31317) to monitoring-external.yaml
- [ ] Expose Collector OTLP ports via ClusterIP Service (oracle-k3s)
- [ ] Bump Tempo storage to 5Gi
- [ ] Improve Grafana Tempo datasource config  
- [ ] Deploy changes to homelab cluster
- [ ] Deploy changes to oracle-k3s cluster
- [ ] Verify traces visible in Grafana
- [ ] Update architecture documentation
- [ ] Update CLAUDE.md / CONVENTIONS.md
- [ ] Write blog post

## Files Changed

| File | Change |
|------|--------|
| `k8s/helm/values/opentelemetry-collector.yaml` | Add OTLP receiver, traces pipeline, memory_limiter, health_check |
| `cloud/oracle/manifests/monitoring/otel-collector.yaml` | Add OTLP receiver, traces pipeline, memory_limiter, health_check, ClusterIP Service |
| `k8s/helm/manifests/monitoring-external.yaml` | Add Tempo gRPC NodePort (31317) |
| `k8s/helm/values/tempo.yaml` | Bump storage 2Gi → 5Gi |
| `k8s/helm/values/kube-prometheus-stack.yaml` | Improve Tempo datasource config |
| `docs/architecture/observability-otel-logging.md` | Update with tracing section |
| `docs/architecture/observability-multicluster.md` | Add traces pipeline docs |
| `docs/CONVENTIONS.md` | Add tracing instrumentation guide |
