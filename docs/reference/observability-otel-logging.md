# Observability — OTel 日志与追踪架构

> Last updated: 2026-08-03
> Status: 生效事实
>
> 2026-07-31 homelab collector 首次真实落地 + 2026 OTel 对齐，见 [`decisions/otel-2026-alignment.md`](../decisions/otel-2026-alignment.md)。

---

## 整体架构

```
                    ┌──────────────────────────────────────────────┐
                    │  homelab K8s Node (10.10.10.10)              │
                    │                                              │
                    │  OTel Collector DaemonSet (monitoring)       │
                    │   image: otel/opentelemetry-collector-k8s:0.156.0 │
                    │   filelog → /var/log/pods/** (hostPath)     │
                    │   otlp    → gRPC :4317 / HTTP :4318          │
                    │   ── logs:   otlphttp → oracle 31080/otlp    │
                    │              (via Tailscale)                 │
                    │   ── traces: otlp/gRPC → oracle 31317        │
                    │              (via Tailscale)                 │
                    │                                              │
                    │  应用 Pod（stdout/stderr 或 log-exporter sidecar）│
                    │                                              │
                    │  Grafana 12.3.3（grafana.meirong.dev）       │
                    │   查询 Loki 31080 / Tempo 31320（跨集群）    │
                    └──────────────────────┬───────────────────────┘
                                           │  logs / traces（跨 Tailscale）
                                           ▼
                    ┌──────────────────────────────────────────────┐
                    │  oracle-k3s node (100.107.166.37)            │
                    │                                              │
                    │  Loki Gateway (svc :80 → NodePort 31080)     │
                    │    └→ Loki 3.x SingleBinary (local-path)     │
                    │  Tempo 2.8.2 (svc :4317)                     │
                    │    写 :31317 / 查 :31320 (local-path)        │
                    │                                              │
                    │  oracle 本地 OTel Collector 集群内直达：      │
                    │   loki-gateway.svc:80/otlp / tempo.svc:4317  │
                    └──────────────────────────────────────────────┘
```

> ⚠️ **Loki/Tempo 2026-08-02 才迁到 oracle**。更早的文档/记忆里 homelab collector
> 指向集群内 `loki-gateway:80` / `tempo:4317` —— 那个拓扑已不存在，别照着排障。

---

## 关键组件

### OTel Collector (DaemonSet)

- **Helm chart**: `open-telemetry/opentelemetry-collector` 0.165.0（镜像 `otel/opentelemetry-collector-k8s`——k8s 官方裁剪发行版）
- **Values**: `k8s/helm/values/opentelemetry-collector.yaml`
- **Deploy**: ArgoCD `otel-collector` App（改 `values/opentelemetry-collector.yaml` → push → 自动同步）
- **Preset `logsCollection`**: 自动挂载 `/var/log/pods` hostPath，注入 `filelog` receiver
- **Preset `kubernetesAttributes`**: 自动申请 RBAC，从 K8s API 查询 Pod metadata 并注入到日志 resource attributes

### Loki 3.x OTLP 支持

Loki 3.x 原生支持 OTLP 协议（`/otlp/v1/logs`），自动将 OTel resource attributes 提升为 Loki stream labels。

**当前可用 Loki Labels（已验证）：**

| Label | 来源 | 示例 |
|-------|------|------|
| `cluster` | resource processor（运营标签，与 Prometheus 侧一致） | `homelab` / `oracle-k3s` |
| `k8s_namespace_name` | container operator + k8sattributes → Loki 默认索引标签 | `personal-services` |
| `k8s_pod_name` | 同上 | `calibre-web-569cc4444d-rfw67` |
| `k8s_container_name` | 同上 | `calibre-web` / `log-exporter` |
| `k8s_deployment_name` | k8sattributes processor | `calibre-web` |
| `service_name` | OTel resource attr（SDK 上报的服务用） | `calibre-web` |

（以上 6 个是 2026-07-31 对 Loki `/loki/api/v1/labels` 的实测全集。`k8s.node.name`、
`log.iostream` 等其余属性在 **structured metadata** 里，不是索引标签——查询时用管道过滤：
`{k8s_namespace_name="x"} | log_iostream="stderr"`。）

> **注意**：filelog 断点（`file_storage` checkpoint，2026-07-31 起）— Collector 重启后从
> 断点续读，不重复不漏采；仅**首次**部署时 `start_at: end` 只采新增行。

### Grafana Sidecar Dashboard 机制

kube-prometheus-stack 的 Grafana 包含 `grafana-sc-dashboard` sidecar 容器，持续 watch `monitoring` namespace 下带 `grafana_dashboard: "1"` label 的 ConfigMap：

- ConfigMap 新增/更新 → 热重载，无需重启 Grafana Pod
- ConfigMap 删除 → Dashboard 自动移除
- `data` 中的 key 必须以 `.json` 结尾

Dashboard ConfigMaps 通过 ArgoCD Application `monitoring-dashboards` 管理（`argocd/applications/monitoring-dashboards.yaml`）。

---

## 应用日志接入模式

### 模式 A：标准 stdout/stderr（推荐）

**适用场景：** 大多数现代容器化应用（it-tools、bentopdf、squoosh 等）

**原理：** 应用直接向 stdout/stderr 输出日志，容器运行时写入 `/var/log/pods/<namespace>_<pod>/<container>/*.log`，OTel Collector 的 filelog receiver 自动采集。

**接入成本：** 零配置，开箱即用。

**LogQL 查询示例：**
```logql
{k8s_namespace_name="personal-services", k8s_container_name="it-tools"}
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
{k8s_namespace_name="personal-services", k8s_container_name="log-exporter"}
```

**已实施案例：**
- `k8s/helm/manifests/personal-services/calibre-web.yaml` — 日志文件：`/config/calibre-web.log`

---

### 模式 C：OTel SDK 直接推送（应用原生 / 追踪）

**适用场景：** 自研服务，可在代码层集成 OTel SDK

**原理：** 应用内嵌 OTel SDK，通过 OTLP gRPC/HTTP 直接向 OTel Collector 推送结构化日志和分布式追踪（traces），携带完整 trace context（traceID、spanID）。

**环境变量配置（所有语言通用）：**
```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector.monitoring.svc:4317"   # gRPC
  - name: OTEL_SERVICE_NAME
    value: "<service-name>"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "cluster=<homelab|oracle-k3s>,k8s.namespace.name=<ns>"
```

**各语言接入指南：**

| 语言 | SDK | 关键依赖 |
|------|-----|----------|
| Go | `go.opentelemetry.io/otel` | `otlptracegrpc`, `otelhttp` |
| Java (Spring Boot) | `opentelemetry-javaagent.jar` | 零代码修改，`-javaagent` JVM 参数 |
| Node.js | `@opentelemetry/sdk-node` | `@opentelemetry/auto-instrumentations-node` |
| Rust | `opentelemetry-otlp` | `tracing-opentelemetry`, `tonic` |

**Go 示例：**
```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

func initTracer() (*sdktrace.TracerProvider, error) {
    exp, _ := otlptracegrpc.New(ctx)  // 读取 OTEL_EXPORTER_OTLP_ENDPOINT 环境变量
    tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp))
    otel.SetTracerProvider(tp)
    return tp, nil
}
```

**Java Spring Boot 示例（零代码）：**
```dockerfile
ENV JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
```

**优势：** 可携带 traceID，实现 Grafana 中 Loki → Tempo 的日志-追踪联动。

**接入成本：** 需修改应用代码或 Dockerfile，适合新服务。

> **追踪架构**：
> - homelab: App → OTel Collector (`otel-collector.monitoring.svc:4317`) → **oracle Tempo** `100.107.166.37:31317` (via Tailscale；2026-08-02 起 Tempo 在 oracle，写 NodePort 31317)
>   ⚠️ 历史更正：**2026-07-31 才首次真正部署**——2026-03 声称的"上线"从未发生
>   （实测无 release、无 pod），homelab 容器日志同日首次进 Loki。
>   现由 ArgoCD `otel-collector` App 管理，取舍见 `docs/decisions/otel-2026-alignment.md`。
> - oracle-k3s: App → OTel Collector (ClusterIP :4317) → **Tempo 集群内直达** `tempo.monitoring.svc:4317`（2026-08-02 起 Tempo 就在本集群）
> - Grafana 已配置 tracesToLogs / tracesToMetrics / nodeGraph / serviceMap
> - 详见 `docs/reference/observability-multicluster.md` ⇢ Traces Pipeline 章节

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
{k8s_namespace_name="personal-services"}

# 按容器名过滤（sidecar 日志）
{k8s_namespace_name="personal-services", k8s_container_name="log-exporter"}

# 错误日志聚合
{k8s_namespace_name=~".+"} |~ "(?i)(error|exception|fatal|panic)"

# 部署 / 移除 OTel Collector（ArgoCD `otel-collector` App）
# 改 values/opentelemetry-collector.yaml → git push → ArgoCD 自动同步
```

---

## 重要历史决策与 Tradeoff

| 决策 | 选择 | 原因 |
|------|------|------|
| 采集层 | OTel Collector DaemonSet | 替换 Promtail；统一 OTel 语义，支持 logs/metrics/traces 三个信号 |
| 传输协议 | OTLP HTTP → Loki `/otlp` | `loki` exporter 在 contrib v0.145.0 已移除；OTLP 是 Loki 3.x 原生协议 |
| 追踪传输 | OTLP gRPC → Tempo :4317 | gRPC 双向流更适合 trace 数据；跨集群走 Tailscale NodePort :31317 |
| 文件日志方案 | log-exporter sidecar (busybox) | linuxserver.io 镜像不输出 stdout；sidecar 比修改镜像更轻量 |
| Dashboard 管理 | ConfigMap + ArgoCD GitOps | 持久化，不依赖 Grafana DB，重建集群无损 |
| label 设计 | 使用 OTel 语义标签 | 与 Grafana Labs 官方 Dashboard 兼容，无需自定义映射 |
| 内存保护 | memory_limiter 200MiB/50MiB | 防止 OTel Collector OOM，背压式流控 |

---

## 相关文件索引

| 文件 | 说明 |
|------|------|
| `k8s/helm/values/opentelemetry-collector.yaml` | OTel Collector Helm values（logs + traces） |
| `k8s/helm/values/tempo.yaml` | Tempo Helm values（traces backend） |
| `k8s/helm/values/kube-prometheus-stack.yaml` | Grafana datasources（Tempo tracesToLogs/Metrics） |
| `cloud/oracle/manifests/monitoring/monitoring-external.yaml` | oracle 侧跨集群 NodePort：Loki 31080 / Tempo 写 31317 / 查询 31320（homelab 侧仅剩 Prometheus remote_write 31090） |
| `cloud/oracle/manifests/monitoring/otel-collector.yaml` | Oracle-k3s OTel Collector（logs + metrics + traces） |
| `k8s/helm/values/loki.yaml` | Loki config（promtail.enabled: false） |
| `k8s/helm/manifests/monitoring/dashboards/grafana-dashboards.yaml` | 4 个 Loki Dashboard ConfigMap |
| `k8s/helm/manifests/personal-services/calibre-web.yaml` | log-exporter sidecar 示例 |
| `argocd/applications/monitoring-dashboards.yaml` | Dashboard GitOps Application |
| `argocd/applications/otel-collector.yaml` | OTel Collector GitOps Application（chart + values） |
| `docs/plans/archive/2026-02-21-otel-log-migration-design.md` | 迁移设计决策文档 |
| `docs/plans/observability/2026-02-21-grafana-loki-dashboards.md` | Dashboard 设计决策文档 |
