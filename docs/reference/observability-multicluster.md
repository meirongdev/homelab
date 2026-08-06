# Multi-Cluster Observability Architecture

> Last updated: 2026-08-06
> Status: 生效事实

## Overview

⚠️ **2026-08-02 起遥测不再是单向的。** Loki(日志) 与 Tempo(追踪) 已迁到 **oracle-k3s**，
Prometheus/Grafana/Alertmanager 仍在 **homelab**。排查时别默认「所有遥测都往同一个方向走」。

- **日志 / 追踪** → 汇聚在 oracle：homelab 跨 Tailscale 写出，oracle 集群内直达
- **指标** → 仍汇聚在 homelab：oracle 跨 Tailscale `prometheusremotewrite` 写入（方向未变）
- **Grafana** 留在 homelab（贴着 Prometheus），经 NodePort 跨 Tailscale 查询 oracle 的 Loki/Tempo

搬 Loki/Tempo 的理由：homelab 是 12GB 笔记本 VM，**迁移当时（2026-08-02）**内存实测 76%、
磁盘 66%（⚠️ 那两个数字是**当时的迁移动机**，不是现状——搬走后已回落到内存 46% / 磁盘 23%），
而 Loki/Tempo 是纯「写入-存储」组件，不像 Prometheus 需要贴着抓取目标 —— 是 LGTM 里
唯一可安全切分出去的子集。附带收益：homelab 整机故障时**故障前的日志与追踪还在**，
此前它们和被观测对象同归于尽（PVC 在同一块盘上）。
取舍全集见 [../plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md](../plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md)。

```
┌─────────────────────────────────────┐     Tailscale     ┌─────────────────────────────────────┐
│          k3s-homelab                │                    │          oracle-k3s                 │
│  (100.94.186.7)                     │                    │  (100.107.166.37)                   │
│                                     │                    │                                     │
│  Prometheus :31090                 │◄── metrics (PRW) ── │  OTel Collector DaemonSet           │
│  Alertmanager                       │                    │    ├ filelog → logs ──┐              │
│  Grafana ──── logs query :31080 ──►│                    │    ├ otlp → traces ───┤ 集群内直达   │
│         └──── trace query :31320 ──►│                    │    ├ prometheus/* ────┘→ PRW 跨网    │
│                                     │                    │                       │              │
│  OTel Collector ─ logs   :31080 ──►│                    │                       ▼              │
│         (homelab)└trace  :31317 ──►│                    │  Loki   (:31080 gateway / :31320 查询)│
│  node-exporter, kube-state-metrics  │                    │  Tempo  (:31317 ingest)              │
└─────────────────────────────────────┘                    └─────────────────────────────────────┘
```

> Tempo 的写入口(4317/gRPC → 31317)与查询口(3200/HTTP → 31320)是**两个端口**；
> Loki 的 gateway(:80 → 31080) 一个口同时承担写入与查询。只开 31317 的症状是
> 「trace 写得进去、Grafana 查不出来」。

## Cluster Label Strategy

All metrics carry a `cluster` label for multi-cluster dashboard queries:

| Cluster | Mechanism | Label |
|---------|-----------|-------|
| homelab (local scrape) | Prometheus `scrapeClasses` with default relabeling | `cluster=homelab` |
| homelab (metal nodes: proxmox, storage) | `additionalScrapeConfigs` with explicit label | `cluster=homelab` |
| oracle-k3s (all metrics) | OTel `resource` processor + `prometheusremotewrite` `external_labels` | `cluster=oracle-k3s` |
| dgx-spark（2× GB10 裸机，非 K8s） | `additionalScrapeConfigs`（Tailscale pull） | `cluster=dgx-spark` |
| macbook（Apple Silicon 笔记本，非 K8s） | `additionalScrapeConfigs`（Tailscale pull） | `cluster=macbook` |

## Log Pipeline

### Oracle k3s → Homelab Loki

**Component:** `cloud/oracle/manifests/monitoring/otel-collector-config.yaml`（receivers/pipelines
全在这里；同目录的 `otel-collector.yaml` 只有 RBAC/Service/DaemonSet，**没有**管道配置）

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
6. **otlphttp exporter** ships to `http://loki-gateway.monitoring.svc.cluster.local/otlp` —— 2026-08-02 起 Loki 就在本集群，集群内直达（此前是跨 Tailscale 的 `100.94.186.7:31080`）

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

**Component:** `cloud/oracle/manifests/monitoring/otel-collector-config.yaml`（receivers/pipelines
全在这里；同目录的 `otel-collector.yaml` 只有 RBAC/Service/DaemonSet，**没有**管道配置）

**Mechanism:** OTel Collector scrapes local exporters and pushes via `prometheusremotewrite` to homelab Prometheus over Tailscale. No prometheus-agent needed.

| OTel Receiver | Target | Interval | Notes |
|---------------|--------|----------|-------|
| `prometheus/node-exporter` | `10.0.0.26:9100` (hostNetwork) | 15s | |
| `prometheus/kube-state-metrics` | `kube-state-metrics.monitoring.svc:8080` | 30s | |
| `prometheus/cloudflared` | `cloudflared-metrics.cloudflare.svc:2000` | 30s | |
| `prometheus/external-secrets` | `external-secrets-metrics.external-secrets.svc:8080` | 30s | |
| `prometheus/external-dns` | `external-dns.external-dns.svc:7979` | 30s | |
| `prometheus/cilium-envoy` | `cilium-envoy.kube-system.svc:9964` | 30s | keep 正则只留 RED SLI 指标 |
| `prometheus/opencost` | `opencost.opencost.svc:9003` | 60s | `honor_labels: true`；成本指标 |
| `prometheus/cadvisor` | `10.0.0.26:10250/metrics/cadvisor` | 60s | https + SA token；见下 |

All metrics pass through `resource` processor (adds `cluster: oracle-k3s`) → `batch` → `prometheusremotewrite` exporter → `http://100.94.186.7:31090/api/v1/write`

**`prometheus/cadvisor` 的特殊之处**（2026-07-30 为 KRR 新增）：

- 直连 kubelet，ClusterRole 必须含 **`nodes/metrics`** —— 只给 `nodes` 会 403
  （kubelet 走自己的 SubjectAccessReview，`kubectl auth can-i` 在此会误报 yes）
- `tls_config.insecure_skip_verify: true` —— k3s kubelet 服务证书自签且 SAN 不含节点 IP
- `metric_relabel_configs` 只 keep
  `container_(cpu_usage_seconds_total|memory_working_set_bytes)`，
  并 drop `container=""` 的 Pod 级汇总。端点原有 **9223** 条 series，落库仅 ~51 条/指标
- 唯一消费者是 KRR，**不足以**支撑 OpenCost 的 Prometheus 数据源
  （后者还需 `container_fs_*` / `container_network_*`），
  详见 [cost-and-rightsizing.md](cost-and-rightsizing.md)

## Traces Pipeline

> Added: 2026-03-01

### Architecture

Both clusters have OTLP receivers (gRPC :4317, HTTP :4318) on their local OTel Collectors. Applications send traces to the cluster-local Collector via ClusterIP Service. The Collector enriches spans with `cluster` label and forwards to Tempo —— 2026-08-02 起 Tempo 在 **oracle-k3s**（homelab 跨 Tailscale 写出，oracle 集群内直达）。

```
Application Pod                      OTel Collector              Tempo (oracle-k3s)
  OTEL_EXPORTER_OTLP_ENDPOINT  →  otlp receiver (4317/4318)  →  otlp/tempo exporter
     (ClusterIP in-cluster)        memory_limiter → resource     (direct or via Tailscale)
                                   → batch
```

### homelab Traces

**Pipeline:** `otlp → memory_limiter → resource(cluster=homelab) → batch → otlp/tempo`

- ⚠️ 2026-08-02 起 **不再是集群内直达**：Tempo 已迁 oracle，homelab collector 跨 Tailscale
  发到 `100.107.166.37:31317`，并带持久化发送队列（file_storage，链路中断不丢缓冲）
- ClusterIP Service: `opentelemetry-collector.monitoring.svc:4317/4318`

### oracle-k3s Traces

**Pipeline:** `otlp → memory_limiter → resource(cluster=oracle-k3s) → batch → otlp/tempo`

- Collector forwards traces to `tempo.monitoring.svc.cluster.local:4317` —— 同上，2026-08-02 起集群内直达
- ClusterIP Service: `otel-collector.monitoring.svc:4317/4318`

### Sampling Strategy

Head sampling at application SDK level via environment variable:
- `OTEL_TRACES_SAMPLER=parentbased_traceidratio`
- `OTEL_TRACES_SAMPLER_ARG=0.1` (10% sampling)

### Application Instrumentation (Env Var Template)

```yaml
env:
  - name: OTEL_SERVICE_NAME
    value: "<service-name>"
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector.monitoring.svc.cluster.local:4318"  # or opentelemetry-collector for homelab
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "http/protobuf"
  - name: OTEL_TRACES_SAMPLER
    value: "parentbased_traceidratio"
  - name: OTEL_TRACES_SAMPLER_ARG
    value: "0.1"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "deployment.environment=prod,service.namespace=<namespace>"
```

### Grafana Integration

- **Tempo datasource** at `http://100.107.166.37:31320`（Tempo 2026-08-02 迁 oracle，Grafana 经 oracle `tempo-query-external` NodePort 查询；写入走 `:31317` OTLP gRPC，见 [otel-logging](observability-otel-logging.md)）
- **tracesToLogs**: Links traces to Loki logs with `filterByTraceID` and `filterBySpanID`
- **tracesToMetrics**: Links traces to Prometheus RED metrics
- **nodeGraph**: Enabled for visual service dependency graph
- **Explore → Tempo**: Search traces by service name, duration, or TraceQL

### Homelab Prometheus (local scrape)

Standard kube-prometheus-stack in-cluster scraping with `scrapeClasses` default relabeling (`cluster: homelab`).

**Additional scrape targets** (`additionalScrapeConfigs`；⚠️ 这些配置**逐字注入**，
scrapeClasses 不会给它们 relabel，`cluster`/`nodename` 必须逐 target 写)：

| Job | Target | Labels |
|-----|--------|--------|
| `node-exporter-metal-nodes` | `192.168.50.106:9100` (storage-node) | `cluster=homelab` |
| `node-exporter-metal-nodes` | `192.168.50.4:9100` (proxmox-node) | `cluster=homelab` |
| `node-exporter-dgx-spark` | `100.97.87.120:9100` / `100.67.164.92:9100`（经 Tailscale） | `cluster=dgx-spark` |
| `node-exporter-macbook` | `100.89.15.120:9100`（经 Tailscale） | `cluster=macbook` / `nodename=macbook-pro` |
| `smartctl-storage-106` / `smartctl-proxmox-pve` / `smartctl-dgx-spark` | `:9633`，120s | `nodename` 与 node-exporter job 对齐 |

### 外部主机（非 K8s，metrics-only）

- **dgx-spark**（2× GB10）: node_exporter 从 **`nv-dgx-spark` repo** 部署
  （`make node-exporter-deploy`，docker `--net=host --pid=host`）。看板 Grafana
  「DGX Spark / Node Exporter」（`dashboards/dgx-spark-node-dashboard.yaml`）。
  Tailnet ACL 已放行 `tag:homelab → *:*`。
- **macbook**（Apple Silicon 笔记本）: node_exporter 是预编译 **`darwin-arm64` 二进制**
  （`~/.local/bin/node_exporter`，非 Homebrew——那台 Mac 出不了 GitHub，tarball 是 `scp` 进去的），
  由 LaunchAgent 拉起（`com.prometheus.node_exporter.plist`，`:9100`，无 sudo）。
  SSH: `ssh -i ~/.ssh/vgio matthew@100.89.15.120`。主机配置已固化为 Ansible
  （`macbook/ansible/`，`just node-exporter` / `just power`）；GUI-only 步骤在其 README。
  ⚠️ 笔记本会睡眠/登出，target 抖动导致间歇 `TargetDown`(warning) → Telegram 噪音，
  烦了就在 Alertmanager silence 掉 `node-exporter-macbook` job。
- **SMART 磁盘健康**（2026-06-27）: Linux 裸机跑 `smartctl_exporter`（:9633）。
  部署：storage-106 + pve（amd64）走 `cd proxmox/ansible && just node-exporter`（一个 playbook
  同装 node_exporter + smartctl_exporter）；DGX ×2（arm64）走 `nv-dgx-spark` repo
  `make smartctl-exporter-deploy`——**不是容器**（`quay.io/...` 的镜像 amd64-only，GB10 是
  aarch64，GitHub `linux-arm64` 二进制在控制机下载后 SSH 分发）。macbook 无 SMART
  （Apple Silicon 内置 NVMe 不暴露标准 SMART 属性，只有文件系统/IO）。
  看板：Grafana **Hardware** 文件夹（health / 温度 / SSD 磨损 / 通电时长）。
  - **⚠️ 指标名坑**: 磁盘温度是 `smartctl_device_temperature{temperature_type="current"}`
    （NVMe+SATA 统一），**不是** `smartctl_device_temperature_celsius`（v0.14.0 无此指标，
    用了面板静默空白）。SSD 磨损：NVMe `100 - smartctl_device_percentage_used`，SATA
    `smartctl_attr_normalized_value{attribute_name=~"Media_Wearout_Indicator|Wear_Leveling_Count|SSD_Life_Left|Percent_Lifetime_Remain"}`
    （磨损 bargauge 两个 target 都带，覆盖两种盘型）。

## NodePort Services on Homelab

`k8s/helm/manifests/monitoring/monitoring-external.yaml`

| Service | NodePort | Purpose |
|---------|----------|---------|
| ~~`loki-gateway-external`~~ | ~~31080~~ | 已随 Loki 迁往 oracle，homelab 侧 Service 已从 Git 移除 |
| ~~`tempo-otlp-external`~~ | ~~31317~~ | 已随 Tempo 迁往 oracle，homelab 侧 Service 已从 Git 移除 |
| `prometheus-otlp-external` | 31090 | Receives Prometheus remote_write from oracle OTel（**方向未变**，Prometheus 仍在 homelab）|

oracle-k3s 侧新增（`cloud/oracle/manifests/monitoring/monitoring-external.yaml`）：

| Service | NodePort | Purpose |
|---------|----------|---------|
| `loki-gateway-external` | 31080 | 收 homelab OTel 的日志；同时是 Grafana 的日志查询口 |
| `tempo-otlp-external` | 31317 | 收 homelab OTel 的追踪（OTLP gRPC 写入口）|
| `tempo-query-external` | 31320 | Grafana 的追踪**查询**口（3200/HTTP，与写入口不同）|
> **Note:** kube-state-metrics NodePort (31082) on oracle-k3s is no longer used for cross-cluster scrape. OTel Collector scrapes it locally via ClusterIP and pushes via remote_write.

## Grafana Dashboards

All 4 Loki dashboards (`k8s/helm/manifests/monitoring/dashboards/grafana-dashboards.yaml`) have a `cluster` dropdown variable:

- **k8s-logs-overview** — log volume by namespace, grouped by cluster
- **k8s-logs-pod** — per-pod log browser, namespace filtered by cluster
- **k8s-logs-errors** — error rate aggregation, per cluster
- **k8s-logs-search** — full-text search across selected cluster(s)

> ~~Cloudflare Tunnel dashboard (`k8s/helm/manifests/cloudflare-tunnel-dashboard.yaml`)~~ —
> **该面板已随 Traefik→Cilium Gateway 切换一并删除**（commit `76b285a`），文件与 ConfigMap 均不存在。
> 隧道本身仍有指标可采，但没有现成看板；能观测/看不到什么见
> [`cloudflare-tunnel-observability.md`](cloudflare-tunnel-observability.md)。入口层的 RED 指标现在
> 来自 Cilium Envoy（见 [observability-alerting-slo.md](observability-alerting-slo.md) 的 SLI/SLO 段）。

Multi-cluster resource overview (`k8s/helm/manifests/monitoring/dashboards/multicluster-overview-dashboard.yaml`):

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

All LogQL queries use: `{cluster=~"${cluster}", k8s_namespace_name=~"..."}`

## Service Health Checks

All services have liveness and readiness probes configured:

### oracle-k3s

| Service | Probe Path | Port |
|---------|-----------|------|
| it-tools | `GET /` | 80 |
| stirling-pdf | `GET /api/v1/info` | 8080 |
| squoosh | `GET /` | 8080 |
| miniflux | `GET /healthcheck` | 8080 |
| rsshub | `GET /healthz` | 1200 |

### k3s-homelab

| Service | Probe Path | Port |
|---------|-----------|------|
| calibre-web | `GET /login` | 8083 |

## Troubleshooting

### Oracle logs show as `unknown_service` in Loki

**Cause:** k8sattributes processor cannot associate log with pod — filepath metadata not promoted to resource attributes.

**Check:** `kubectl --context oracle-k3s logs -n monitoring daemonset/otel-collector | grep "evaluating pod identifier"` — all source values should be non-empty.

**Fix:** Ensure the OTel config has `move` operators after `extract-metadata-from-filepath` to promote `uid`, `namespace`, `pod_name`, `container_name` to `resource["k8s.*"]` attributes.

### Loki 收不到日志（Loki 在 oracle，两集群的发送方都可能出问题）

1. 从 homelab 测到 oracle 的连通性：`curl http://100.107.166.37:31080/otlp/v1/logs`（能收到 4xx 而非超时即通）
2. 确认 oracle 侧 NodePort 存在：`kubectl --context oracle-k3s get svc loki-gateway-external -n monitoring`
   （⚠️ homelab 侧同名 Service 已随 2026-08-02 迁移移除，不要再在 `k3s-homelab` 里找）
3. 查发送方 collector：
   - homelab：`kubectl --context k3s-homelab logs -n monitoring daemonset/otel-collector | grep -iE "url:|error"`
   - oracle：`kubectl --context oracle-k3s logs -n monitoring daemonset/otel-collector | grep -iE "url:|error"`

### Prometheus not scraping oracle metrics

Oracle-k3s metrics are pushed (not scraped). Check the OTel Collector:

1. Check OTel logs: `kubectl --context oracle-k3s logs -n monitoring daemonset/otel-collector --tail=30`
2. Look for `Failed to scrape Prometheus endpoint` — means target is unreachable from within the pod
3. Verify Prometheus receives data: Grafana → Explore → Prometheus → `count by (cluster, job) ({cluster="oracle-k3s"})`
4. Check Tailscale connectivity: `kubectl --context oracle-k3s exec -n monitoring daemonset/otel-collector -- wget -qO- http://100.94.186.7:31090/api/v1/status/runtimeinfo 2>/dev/null | head`

### homelab metrics missing `cluster` label

**Cause:** Prometheus `externalLabels` only applies to remote_write/federation, not local queries.

**Fix:** Ensure `prometheusSpec.scrapeClasses` has a default class with `relabelings` that sets `cluster: homelab`. See `k8s/helm/values/kube-prometheus-stack.yaml`.

> 该默认类是 `default: true`，**对所有 ServiceMonitor 自动生效**，新增组件无需在自己的
> ServiceMonitor 上重复配 `relabelings` / `metricRelabelings`。
> 验证方式：chart 自带的 kube-state-metrics ServiceMonitor 没有任何 relabeling，
> 其指标依然带 `cluster="homelab"`。
> （2026-07-31：OpenCost 上线时曾误以为需要 per-ServiceMonitor 补标签，加了冗余配置后移除。）
>
> 例外：`additionalScrapeConfigs` 是原样注入的，**scrapeClasses 不作用于它们**，
> 必须在每个 target 上显式写 `labels: {cluster: …}`（见 dgx-spark / macbook / storage-106 各 job）。

### otel-collector 配置改了不生效 —— ✅ 已根治（2026-08-02），别再手动重启

**曾经的症状：** 改了 oracle 的 otel ConfigMap 并推送，ArgoCD 显示 **Synced / Healthy**，
但新的 receiver / pipeline 一条数据都没有。**原因**是 DaemonSet 的 pod template 没有 config
checksum 注解，ConfigMap 内容变了**不会**触发滚动，Pod 继续挂着旧配置跑；ArgoCD 只比对对象
本身，看不出这层。2026-07 引入 OpenCost 和 KRR 时各踩了一次（homelab 侧没这问题——Helm chart
会自动打 checksum 注解）。

**根治做法（已生效）：** 配置改由根 `cloud/oracle/manifests/kustomization.yaml` 的
**`configMapGenerator`** 生成 —— 生成的 ConfigMap 名字带内容哈希后缀，并自动重写 DaemonSet 的
volume 引用，所以**内容一变名字就变，DaemonSet 随之滚动**。改配置只需编辑
`cloud/oracle/manifests/monitoring/otel-collector-config.yaml` 后 push，**不需要任何手动重启**。

2026-08-06 实测复核：新增 `prometheus/readlist` receiver 后，ConfigMap 名变成
`otel-collector-config-2g4gm5979k`，DaemonSet 自动滚动、Pod age 归零、新指标立即上来。

**要守住的不变量：** 那份配置**必须**留在 `configMapGenerator` 里。谁要是把它改回普通
ConfigMap 资源（比如为了"看起来整齐"），上面那个静默失败立刻回来，而且照样是 Synced/Healthy。

```bash
# 只在怀疑没生效时核对：ConfigMap 名应带哈希后缀，且 DS 引用的就是它
kubectl --context oracle-k3s -n monitoring get cm | grep otel-collector-config
kubectl --context oracle-k3s -n monitoring get ds otel-collector \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}{"\n"}'
```
