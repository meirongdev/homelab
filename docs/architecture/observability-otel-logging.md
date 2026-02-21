# Observability — OTel 日志架构

**更新日期：** 2026-02-21
**状态：** 生产运行中

---

## 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│  K8s Node (10.10.10.10)                                         │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  OTel Collector DaemonSet (monitoring namespace)        │   │
│  │  image: otel/opentelemetry-collector-contrib            │   │
│  │                                                         │   │
│  │  Receivers:                                             │   │
│  │    filelog ──── /var/log/pods/**/*.log (hostPath)      │   │
│  │                                                         │   │
│  │  Processors:                                            │   │
│  │    k8sattributes ── 注入 k8s 元数据到 resource attrs   │   │
│  │    batch ─────────── 10000 条 / 5s 批量发送            │   │
│  │                                                         │   │
│  │  Exporters:                                             │   │
│  │    otlp_http ──── loki-gateway:80/otlp                 │   │
│  └─────────────────────────────────────────────────────────┘   │
│            │                        ▲                           │
│            │ /var/log/pods/         │ stdout/stderr             │
│            ▼                        │                           │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  应用 Pod                                                 │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │  │
│  │  │ 标准应用      │  │ 文件日志应用  │  │ 其他          │  │  │
│  │  │ stdout/stderr│  │ + log-exporter│  │               │  │  │
│  │  │              │  │   sidecar    │  │               │  │  │
│  │  └──────────────┘  └──────────────┘  └───────────────┘  │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
          │
          ▼ OTLP HTTP (port 80, path /otlp/v1/logs)
┌─────────────────────────┐
│  Loki Gateway           │
│  (loki-gateway svc)     │
│         │               │
│         ▼               │
│  Loki 3.x SingleBinary  │
│  (loki-0 pod)           │
│  OTLP 原生支持           │
│  auto-promotes labels   │
└─────────────────────────┘
          │
          ▼ LogQL
┌─────────────────────────┐
│  Grafana 12.3.3         │
│  grafana.meirong.dev    │
│                         │
│  Dashboards (via sidecar│
│  ConfigMap auto-load):  │
│  · Logs / Overview      │
│  · Logs / Pod Browser   │
│  · Logs / Errors        │
│  · Logs / Cluster Search│
└─────────────────────────┘
```

---

## 关键组件

### OTel Collector (DaemonSet)

- **Helm chart**: `open-telemetry/opentelemetry-collector`
- **Values**: `k8s/helm/values/opentelemetry-collector.yaml`
- **Deploy**: `cd k8s/helm && just deploy-otel-collector`
- **Preset `logsCollection`**: 自动挂载 `/var/log/pods` hostPath，注入 `filelog` receiver
- **Preset `kubernetesAttributes`**: 自动申请 RBAC，从 K8s API 查询 Pod metadata 并注入到日志 resource attributes

### Loki 3.x OTLP 支持

Loki 3.x 原生支持 OTLP 协议（`/otlp/v1/logs`），自动将 OTel resource attributes 提升为 Loki stream labels。

**当前可用 Loki Labels（已验证）：**

| Label | 来源 | 示例 |
|-------|------|------|
| `service_namespace` | OTel resource attr | `personal-services` |
| `service_name` | OTel resource attr | `calibre-web` |
| `k8s_namespace_name` | k8sattributes processor | `personal-services` |
| `k8s_pod_name` | k8sattributes processor | `calibre-web-569cc4444d-rfw67` |
| `k8s_container_name` | k8sattributes processor | `calibre-web` / `log-exporter` |
| `k8s_deployment_name` | k8sattributes processor | `calibre-web` |
| `k8s_node_name` | k8sattributes processor | `k8s-node` |
| `stream` | filelog receiver | `stdout` / `stderr` |

> **注意**：`start_at: end`（OTel Collector 默认值）— Collector 重启后只采集**新写入**的日志行，历史日志不会回溯。

### Grafana Sidecar Dashboard 机制

kube-prometheus-stack 的 Grafana 包含 `grafana-sc-dashboard` sidecar 容器，持续 watch `monitoring` namespace 下带 `grafana_dashboard: "1"` label 的 ConfigMap：

- ConfigMap 新增/更新 → 热重载，无需重启 Grafana Pod
- ConfigMap 删除 → Dashboard 自动移除
- `data` 中的 key 必须以 `.json` 结尾

Dashboard ConfigMaps 通过 ArgoCD Application `monitoring-dashboards` 管理（`argocd/applications/monitoring-dashboards.yaml`）。

---

## 应用日志接入模式

### 模式 A：标准 stdout/stderr（推荐）

**适用场景：** 大多数现代容器化应用（it-tools、stirling-pdf、squoosh 等）

**原理：** 应用直接向 stdout/stderr 输出日志，容器运行时写入 `/var/log/pods/<namespace>_<pod>/<container>/*.log`，OTel Collector 的 filelog receiver 自动采集。

**接入成本：** 零配置，开箱即用。

**LogQL 查询示例：**
```logql
{service_namespace="personal-services", k8s_container_name="it-tools"}
```

---

### 模式 B：文件日志 + log-exporter Sidecar

**适用场景：** 将日志写入容器内部文件而非 stdout 的应用（linuxserver.io 镜像系列，如 Calibre-Web）

**原理：** 在同一 Pod 中添加 `busybox` sidecar 容器，共享应用的 volume，通过 `tail -F` 将文件内容输出到 stdout，OTel Collector 再从该 sidecar 的 stdout 采集。

**sidecar 模板：**
```yaml
- name: log-exporter
  image: busybox
  command: ["sh", "-c", "tail -F /path/to/app.log 2>/dev/null"]
  resources:
    requests:
      cpu: 1m
      memory: 8Mi
    limits:
      memory: 16Mi
  volumeMounts:
    - name: <shared-volume-name>
      mountPath: /path/to/log/dir
      readOnly: true
```

**查找日志文件路径的方法：**
```bash
# 先部署不带 sidecar，找到实际日志路径
kubectl exec -n <ns> <pod> -c <app-container> -- find / -name "*.log" 2>/dev/null | grep -v proc
```

**LogQL 查询示例（Calibre-Web）：**
```logql
{service_namespace="personal-services", k8s_container_name="log-exporter"}
```

**已实施案例：**
- `k8s/helm/manifests/calibre-web.yaml` — 日志文件：`/config/calibre-web.log`

---

### 模式 C：OTel SDK 直接推送（应用原生）

**适用场景：** 自研服务，可在代码层集成 OTel SDK

**原理：** 应用内嵌 OTel SDK，通过 OTLP gRPC/HTTP 直接向 OTel Collector 或 Loki 推送结构化日志，携带完整 trace context（traceID、spanID）。

**接入方式（以 Python 为例）：**
```python
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter

# 指向 OTel Collector ClusterIP service
exporter = OTLPLogExporter(endpoint="http://opentelemetry-collector-agent.monitoring.svc:4317")
```

**优势：** 可携带 traceID，实现 Grafana 中 Loki → Tempo 的日志-追踪联动。

**接入成本：** 需修改应用代码，适合新服务。

---

### 模式 D：Prometheus Exporter 的结构化日志（混合）

**适用场景：** 已有 Prometheus metrics 的应用，希望同时采集日志

与模式 A/B 并行使用，metrics 走 Prometheus scrape，logs 走 OTel filelog。无需特殊配置。

---

## 运维操作速查

```bash
# 查看 OTel Collector 运行状态
kubectl get ds -n monitoring | grep otel
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector -f

# 查看 Calibre-Web 日志实时输出（sidecar）
kubectl logs -n personal-services -l app=calibre-web -c log-exporter -f

# 在 Loki 查询某 namespace 所有日志
{service_namespace="personal-services"}

# 按容器名过滤（sidecar 日志）
{service_namespace="personal-services", k8s_container_name="log-exporter"}

# 错误日志聚合
{service_namespace=~".+"} |~ "(?i)(error|exception|fatal|panic)"

# 部署 / 移除 OTel Collector
cd k8s/helm && just deploy-otel-collector
cd k8s/helm && just remove-otel-collector
```

---

## 重要历史决策与 Tradeoff

| 决策 | 选择 | 原因 |
|------|------|------|
| 采集层 | OTel Collector DaemonSet | 替换 Promtail；统一 OTel 语义，未来可扩展 metrics/traces |
| 传输协议 | OTLP HTTP → Loki `/otlp` | `loki` exporter 在 contrib v0.145.0 已移除；OTLP 是 Loki 3.x 原生协议 |
| 文件日志方案 | log-exporter sidecar (busybox) | linuxserver.io 镜像不输出 stdout；sidecar 比修改镜像更轻量 |
| Dashboard 管理 | ConfigMap + ArgoCD GitOps | 持久化，不依赖 Grafana DB，重建集群无损 |
| label 设计 | 使用 OTel 语义标签 | 与 Grafana Labs 官方 Dashboard 兼容，无需自定义映射 |

---

## 相关文件索引

| 文件 | 说明 |
|------|------|
| `k8s/helm/values/opentelemetry-collector.yaml` | OTel Collector Helm values |
| `k8s/helm/values/loki.yaml` | Loki config（promtail.enabled: false） |
| `k8s/helm/manifests/grafana-dashboards.yaml` | 4 个 Loki Dashboard ConfigMap |
| `k8s/helm/manifests/calibre-web.yaml` | log-exporter sidecar 示例 |
| `argocd/applications/monitoring-dashboards.yaml` | Dashboard GitOps Application |
| `k8s/helm/justfile` | deploy-otel-collector / remove-otel-collector |
| `docs/plans/2026-02-21-otel-log-migration-design.md` | 迁移设计决策文档 |
| `docs/plans/2026-02-21-grafana-loki-dashboards-design.md` | Dashboard 设计决策文档 |
