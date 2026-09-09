# Multi-Cluster Observability Architecture

> Last updated: 2026-09-09
> Status: 生效事实
>
> 遥测的**采集与汇聚侧**：三条管线怎么跨集群流动、应用怎么接日志/追踪、坏了怎么查。
> 消费侧（告警路由、看板组织约定、SLI/SLO）见
> [observability-alerting-slo.md](observability-alerting-slo.md)。
> 2026-09-09 合并 `observability-otel-logging.md`——两页描述的是同一条管线的两个视角，
> 拓扑图和组件表各维护一份必然分头漂。

## 速览

- **遥测不是单向的**：日志/追踪（Loki/Tempo）汇聚在 oracle-k3s；指标
  （Prometheus/Grafana/Alertmanager）仍汇聚在 homelab。
- **方向**：homelab 跨 Tailscale 写出遥测；oracle 跨 Tailscale `prometheusremotewrite` 写指标。
- **外部主机**：dgx-spark ×2 与 macbook 也接入采集（node_exporter / smartctl）。

## Overview

⚠️ **2026-08-02 起遥测不再是单向的。** Loki(日志) 与 Tempo(追踪) 已迁到 oracle-k3s，
Prometheus/Grafana/Alertmanager 仍在 homelab。排查时别默认「所有遥测都往同一个方向走」。

- **日志 / 追踪** → 汇聚在 oracle：homelab 跨 Tailscale 写出，oracle 集群内直达
- **指标** → 仍汇聚在 homelab：oracle 跨 Tailscale `prometheusremotewrite` 写入（方向未变）
- Grafana 留在 homelab（贴着 Prometheus），经 NodePort 跨 Tailscale 查询 oracle 的 Loki/Tempo

搬 Loki/Tempo 的理由：homelab 是 12GB 笔记本 VM，迁移当时（2026-08-02）内存实测 76%、
磁盘 66%（⚠️ 那两个数字是当时的迁移动机，不是现状：搬走后已回落到内存 46% / 磁盘 23%），
而 Loki/Tempo 是纯「写入-存储」组件，不像 Prometheus 需要贴着抓取目标，是 LGTM 里
唯一可安全切分出去的子集。附带收益：homelab 整机故障时**故障前的日志与追踪还在**，
此前它们和被观测对象同归于尽（PVC 在同一块盘上）。
取舍全集见 [../plans/2026-08-02-homelab-to-oracle-workload-migration.md](../plans/2026-08-02-homelab-to-oracle-workload-migration.md)。

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

### Oracle k3s → Loki（集群内直达）

**Component:** `cloud/oracle/manifests/monitoring/otel-collector-config.yaml`（receivers/pipelines
全在这里；同目录的 `otel-collector.yaml` 只有 RBAC/Service/DaemonSet，没有管道配置）

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
6. **otlphttp exporter** ships to `http://loki-gateway.monitoring.svc.cluster.local/otlp`。2026-08-02 起 Loki 就在本集群，集群内直达（此前是跨 Tailscale 的 `100.94.186.7:31080`）

> **Bug fixed 2026-02-22:** The original config did not promote filepath-extracted attributes to resource attributes, so `k8sattributes` could never find the pod (all identifier values were empty strings). Logs arrived in Loki as `unknown_service` with no namespace/pod labels.

### Homelab → Loki（oracle，跨 Tailscale）

**Component:** `opentelemetry-collector-agent` DaemonSet (deployed via Helm `opentelemetry-collector` chart)

Uses the `container` operator type which automatically handles filepath parsing and k8s attribute association. Exports to oracle `http://100.107.166.37:31080/otlp`（2026-08-02 起 Loki 在 oracle，跨 Tailscale）。

### homelab Collector 的部署形态（Helm chart）

> oracle 侧不是这个形态——那边是手写 manifest，见本节开头的 `otel-collector-config.yaml`。

- **Helm chart**: `open-telemetry/opentelemetry-collector` 0.165.0（镜像 `otel/opentelemetry-collector-k8s`，k8s 官方裁剪发行版）
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
| `k8s_container_name` | 同上 | `calibre-web` / `permission-fixer`（同 pod 多容器各成一路） |
| `k8s_deployment_name` | k8sattributes processor | `calibre-web` |
| `service_name` | OTel resource attr（SDK 上报的服务用） | `calibre-web` |

（以上 6 个是 2026-07-31 对 Loki `/loki/api/v1/labels` 的实测全集。`k8s.node.name`、
`log.iostream` 等其余属性在 structured metadata 里，不是索引标签，查询时用管道过滤：
`{k8s_namespace_name="x"} | log_iostream="stderr"`。）

> **注意**：filelog 断点（`file_storage` checkpoint，2026-07-31 起）：Collector 重启后从
> 断点续读，不重复不漏采；仅首次部署时 `start_at: end` 只采新增行。

## 应用日志接入模式

新服务接日志前先对一遍这四种模式，**多数情况是模式 A、零配置**。

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

> ⚠️ **本仓库当前没有在用的实例，且加之前必须先做下面的「验证」一步。**
> 唯一那个实例（calibre-web）2026-08-29 已删除：它 tail 的
> `/config/calibre-web.log` 在镜像里根本不存在，`tail -F` + `2>/dev/null`
> 于是永久静默，Loki 近 7 天 0 行，而同 pod 主容器有 1898 行。
> 即「加了个 sidecar」和「加了个什么都不干的 sidecar」现象完全一致，无告警、无报错。
> 教训：**这个模式的失败是静默的，不验证等于没加。**

**适用场景：** 只把日志写进容器内文件、不写 stdout 的应用。
⚠️ **别按镜像血统预设**：linuxserver.io 系列（含 Calibre-Web）如今是输出 stdout 的，
模式 A 就够了。先看 `kubectl logs` 有没有东西，有就别加 sidecar。

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
# 先部署不带 sidecar，确认主容器 stdout 确实是空的（不空则用模式 A，到此为止）
kubectl logs -n <ns> <pod> -c <app-container> --tail=20
# 再找实际日志路径（路径会随上游版本变，别照抄文档里的常量）
kubectl exec -n <ns> <pod> -c <app-container> -- find / -name "*.log" 2>/dev/null | grep -v proc
```

**验证（加完 sidecar 必做，否则前功尽弃）：**
```bash
# 1) sidecar 自己有输出吗？空 = tail 的路径不对，不是"还没有日志"
kubectl logs -n <ns> <pod> -c log-exporter --tail=5
# 2) 真的进 Loki 了吗？（端口转发，见本文档「查询」一节）
#    返回 0 或无数据 = 没接上
{k8s_namespace_name="<ns>", k8s_container_name="log-exporter"}
```

**已实施案例：** 无。
`cloud/oracle/manifests/personal-services/calibre-web.yaml` 曾是唯一实例，
2026-08-29 删除（原因见本节顶部警告；该文件内留有删除注释）。

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
>   ⚠️ 历史更正：**2026-07-31 才首次真正部署**，2026-03 声称的"上线"从未发生
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

## Metrics Pipeline

### Oracle k3s → Homelab Prometheus (push via OTel)

**Component:** `cloud/oracle/manifests/monitoring/otel-collector-config.yaml`（receivers/pipelines
全在这里；同目录的 `otel-collector.yaml` 只有 RBAC/Service/DaemonSet，没有管道配置）

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

- 直连 kubelet，ClusterRole 必须含 `nodes/metrics`，只给 `nodes` 会 403
  （kubelet 走自己的 SubjectAccessReview，`kubectl auth can-i` 在此会误报 yes）
- `tls_config.insecure_skip_verify: true`：k3s kubelet 服务证书自签且 SAN 不含节点 IP
- `metric_relabel_configs` 只 keep
  `container_(cpu_usage_seconds_total|memory_working_set_bytes)`，
  并 drop `container=""` 的 Pod 级汇总。端点原有 9223 条 series，落库仅 ~51 条/指标
- 唯一消费者是 KRR，不足以支撑 OpenCost 的 Prometheus 数据源
  （后者还需 `container_fs_*` / `container_network_*`），
  详见 [cost-and-rightsizing.md](cost-and-rightsizing.md)

### Homelab Prometheus (local scrape)

Standard kube-prometheus-stack in-cluster scraping with `scrapeClasses` default relabeling (`cluster: homelab`).

**采集面已按消费者裁剪**（2026-08-18，`values/kube-prometheus-stack.yaml` 末尾的
`kubelet` / `kubeApiServer` `serviceMonitor.metricRelabelings`）：

- ☠️ **k3s 把 apiserver 与 kubelet 跑在同一个进程里**，kubelet 的 `/metrics` 会把整个
  进程的 registry 全吐出来，于是全套 `apiserver_*` / `etcd_*` 被抓进来两遍。
  实测这批重复副本占 `job="kubelet"` 全部 93,056 条 series 的 80%。
- 现状：kubelet 侧整族 drop `(apiserver|etcd)_.*`；apiserver 侧另 drop 7 族无 rule/无
  panel 引用的 histogram。**保留** `apiserver_request_sli_duration_seconds_bucket`
  的 apiserver 副本：`kube-apiserver-histogram.rules` 两条 recording rule 在用它。
- 效果：active series 234,532 → 109,566（−53%）、摄入 7,562 → 2,879 samples/s，
  Prometheus limit 随之从 4Gi 收回 3Gi（cgroup peak 758Mi = 24%）。
- ⚠️ 两个 key 的 chart 默认 `metricRelabelings` **不是空的**，list 是整体覆盖，
  默认值原样抄进来再追加（当前抄自 chart 87.6.0），升 chart 时要重新比对。
- ⚠️ 面板查的是 recording rule 输出（`cluster_quantile:...`）而非原始 bucket，
  所以看板不受影响；但原始 bucket 已无法 ad-hoc 查询。

判据、被否决的选项与三层验证方法见
[decisions/prometheus-series-reduction.md](../decisions/prometheus-series-reduction.md)。

**Additional scrape targets** (`additionalScrapeConfigs`；⚠️ 这些配置逐字注入，
scrapeClasses 不会给它们 relabel，`cluster`/`nodename` 必须逐 target 写)：

| Job | Target | Labels |
|-----|--------|--------|
| `node-exporter-metal-nodes` | `192.168.50.106:9100` (storage-node) | `cluster=homelab` |
| `node-exporter-metal-nodes` | `192.168.50.4:9100` (proxmox-node) | `cluster=homelab` |
| `node-exporter-dgx-spark` | `100.97.87.120:9100` / `100.67.164.92:9100`（经 Tailscale） | `cluster=dgx-spark` |
| `node-exporter-macbook` | `100.89.15.120:9100`（经 Tailscale） | `cluster=macbook` / `nodename=macbook-pro`；⚠️ 唯一带 `metric_relabel_configs` 的 job（OMLX 那批 `omlx_*` → `omlx_alltime_*`，见下）|
| `smartctl-storage-106` / `smartctl-proxmox-pve` / `smartctl-dgx-spark` | `:9633`，120s | `nodename` 与 node-exporter job 对齐 |

### 外部主机（非 K8s，metrics-only）

- **dgx-spark**（2× GB10）: node_exporter 从 `nv-dgx-spark` repo 部署
  （`make node-exporter-deploy`，docker `--net=host --pid=host`）。看板 Grafana
  「DGX Spark / Node Exporter」（`dashboards/dgx-spark-node-dashboard.yaml`）。
  Tailnet ACL 已放行 `tag:homelab → *:*`。
- **macbook**（Apple Silicon 笔记本）: node_exporter 是预编译的 `darwin-arm64` 二进制
  （`~/.local/bin/node_exporter`，不是 Homebrew：那台 Mac 出不了 GitHub，tarball 是 `scp` 进去的），
  由 LaunchAgent 拉起（`com.prometheus.node_exporter.plist`，`:9100`，无 sudo）。
  SSH: `ssh -i ~/.ssh/vgio matthew@100.89.15.120`。主机配置已固化为 Ansible
  （`macbook/ansible/`，`just node-exporter` / `just power`）；GUI-only 步骤在其 README。
  ⚠️ 笔记本会睡眠/登出，target 抖动导致间歇 `TargetDown`(warning) → Telegram 噪音，
  烦了就在 Alertmanager silence 掉 `node-exporter-macbook` job。
  - **它同时驮着 OMLX 的推理计数器**（2026-08-23 起）：Mac 上另一个 LaunchAgent
    每 60s 把 `~/.omlx/stats.json` 渲染成 `.prom`，node_exporter 用
    `--collector.textfile.directory` 一起吐出来，抓取时改名为 `omlx_alltime_*`。
    部署 `cd macbook/ansible && just omlx-metrics`（读取端的 flag 由 `just node-exporter` 加，
    **两个都要跑**，少一个不报错、指标静默不出现）。
    口径/陷阱/验收 → [omlx-inference-metrics.md](omlx-inference-metrics.md)（唯一真相源）。
- **SMART 磁盘健康**（2026-06-27）: Linux 裸机跑 `smartctl_exporter`（:9633）。
  部署：storage-106 + pve（amd64）走 `cd proxmox/ansible && just node-exporter`（一个 playbook
  同装 node_exporter + smartctl_exporter）；DGX ×2（arm64）走 `nv-dgx-spark` repo
  `make smartctl-exporter-deploy`，**不是容器**（`quay.io/...` 的镜像 amd64-only，GB10 是
  aarch64，GitHub `linux-arm64` 二进制在控制机下载后 SSH 分发）。macbook 无 SMART
  （Apple Silicon 内置 NVMe 不暴露标准 SMART 属性，只有文件系统/IO）。
  看板：Grafana `Hardware` 文件夹（health / 温度 / SSD 磨损 / 通电时长）。
  - **⚠️ 指标名坑**: 磁盘温度是 `smartctl_device_temperature{temperature_type="current"}`
    （NVMe+SATA 统一），**不是** `smartctl_device_temperature_celsius`（v0.14.0 无此指标，
    用了面板静默空白）。SSD 磨损：NVMe `100 - smartctl_device_percentage_used`，SATA
    `smartctl_device_attribute{attribute_value_type="value", attribute_name=~"Media_Wearout_Indicator|Wear_Leveling_Count|SSD_Life_Left|Percent_Lifetime_Remain"}`
    （磨损 bargauge 两个 target 都带，覆盖两种盘型）。**不是** `smartctl_attr_normalized_value`：
    v0.14.0 已把该指标改名 `smartctl_device_attribute` 并加 `attribute_value_type` 标签
    （`"value"`=归一化 100=new），旧名直接查不到、面板静默空白（2026-08-17 三个 dashboard 同修）。

## Traces Pipeline

> Added: 2026-03-01

### Architecture

Both clusters have OTLP receivers (gRPC :4317, HTTP :4318) on their local OTel Collectors. Applications send traces to the cluster-local Collector via ClusterIP Service. The Collector enriches spans with `cluster` label and forwards to Tempo。2026-08-02 起 Tempo 在 oracle-k3s（homelab 跨 Tailscale 写出，oracle 集群内直达）。

```
Application Pod                      OTel Collector              Tempo (oracle-k3s)
  OTEL_EXPORTER_OTLP_ENDPOINT  →  otlp receiver (4317/4318)  →  otlp/tempo exporter
     (ClusterIP in-cluster)        memory_limiter → resource     (direct or via Tailscale)
                                   → batch
```

### homelab Traces

**Pipeline:** `otlp → memory_limiter → resource(cluster=homelab) → batch → otlp/tempo`

- ⚠️ 2026-08-02 起**不再是集群内直达**：Tempo 已迁 oracle，homelab collector 跨 Tailscale
  发到 `100.107.166.37:31317`，并带持久化发送队列（file_storage，链路中断不丢缓冲）
- ClusterIP Service: `opentelemetry-collector.monitoring.svc:4317/4318`

### oracle-k3s Traces

**Pipeline:** `otlp → memory_limiter → resource(cluster=oracle-k3s) → batch → otlp/tempo`

- Collector forwards traces to `tempo.monitoring.svc.cluster.local:4317`，同上，2026-08-02 起集群内直达
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

- **Tempo datasource** at `http://100.107.166.37:31320`（Tempo 2026-08-02 迁 oracle，Grafana 经 oracle `tempo-query-external` NodePort 查询；写入走 `:31317` OTLP gRPC，见本页 NodePort 一节）
- **tracesToLogs**: Links traces to Loki logs with `filterByTraceID` and `filterBySpanID`
- **tracesToMetrics**: Links traces to Prometheus RED metrics
- **nodeGraph**: Enabled for visual service dependency graph
- **Explore → Tempo**: Search traces by service name, duration, or TraceQL

## NodePort Services on Homelab

`k8s/helm/manifests/monitoring/monitoring-external.yaml`

| Service | NodePort | Purpose |
|---------|----------|---------|
| ~~`loki-gateway-external`~~ | ~~31080~~ | 已随 Loki 迁往 oracle，homelab 侧 Service 已从 Git 移除 |
| ~~`tempo-otlp-external`~~ | ~~31317~~ | 已随 Tempo 迁往 oracle，homelab 侧 Service 已从 Git 移除 |
| `prometheus-otlp-external` | 31090 | Receives Prometheus remote_write from oracle OTel（方向未变，Prometheus 仍在 homelab）|

oracle-k3s 侧新增（`cloud/oracle/manifests/monitoring/monitoring-external.yaml`）：

| Service | NodePort | Purpose |
|---------|----------|---------|
| `loki-gateway-external` | 31080 | 收 homelab OTel 的日志；同时是 Grafana 的日志查询口 |
| `tempo-otlp-external` | 31317 | 收 homelab OTel 的追踪（OTLP gRPC 写入口）|
| `tempo-query-external` | 31320 | Grafana 的追踪查询口（3200/HTTP，与写入口不同）|
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
  - 「📦 容器资源使用」行 2026-08-30 从 2 个面板扩到 4 个，新增的两个按**容器**取 TOP10、
    红色阈值线直接对齐告警：CPU 节流率 TOP10（红线 25% = `ContainerCPUThrottlingSustained`）
    与内存 RSS / Limit TOP10（红线 80% = `ContainerMemoryNearLimit`）。
    ⚠️ RSS 面板与它左边的 working_set 面板口径不同，两张图并排就是为了看出差别：
    working_set 含页缓存，对 mmap/文件重的负载会显著偏高
    （[records/2026-08-30-…](../records/2026-08-30-memory-alert-page-cache-false-alarm.md)）。
    ⚠️ 节流面板里**没设 CPU limit 的容器整个缺席**：cAdvisor 只为有 quota 的容器吐
    `container_cpu_cfs_*`，那是无数据，不是「节流为 0」。

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

### Grafana Sidecar Dashboard 机制

kube-prometheus-stack 的 Grafana 包含 `grafana-sc-dashboard` sidecar 容器，持续 watch `monitoring` namespace 下带 `grafana_dashboard: "1"` label 的 ConfigMap：

- ConfigMap 新增/更新 → 热重载，无需重启 Grafana Pod
- ConfigMap 删除 → Dashboard 自动移除
- `data` 中的 key 必须以 `.json` 结尾

Dashboard ConfigMaps 通过 ArgoCD Application `monitoring-dashboards` 管理（`argocd/applications/monitoring-dashboards.yaml`）。

---

### ☠️ chart 内置 mixin 看板选 `oracle-k3s` 恒为空（已知、刻意，不是故障）

kube-prometheus-stack 自带的 **Compute Resources / Namespace(Pods) / Pod / Node** 那组看板
（`defaultDashboardsEnabled` 未关，且开了 `sidecar.dashboards.multicluster.global.enabled`，
所以有 `$cluster` 下拉）**选 oracle-k3s 只会得到空图**。原因不在看板，在录制规则：

```
面板查的是录制规则，不是原始指标：
  node_namespace_pod_container:container_memory_working_set_bytes   homelab 111 · oracle 0
规则的选择器（chart 内置，不可改）：
  {image!="", job="kubelet", metrics_path="/metrics/cadvisor"}
```

oracle 的容器指标经 OTel `prometheusreceiver` remote-write 进来，标签是
`job="kubelet-cadvisor"`，且没有 `metrics_path` 标签（那两个标签是 homelab 侧
ServiceMonitor 加的，OTel 不加），两个条件都不匹配，录制规则永远算不到 oracle。
**给 cadvisor keep 正则加指标不会改变这一点**（2026-08-30 从 2 个加到 8 个，mixin 面板照旧空）。

⚠️ **别试图靠改写 job 名去"修"它**：`job="kubelet-cadvisor"` 这个名字是
`values/kube-prometheus-stack.yaml` 里 `KubeletDown` 被 disable、自建版本硬写
`cluster="homelab"` 的前提（那里有完整设计说明）。而且 mixin 面板还依赖
`container_network_*` / `container_fs_*` 等一大批没进 keep 正则的指标，改了 job 名
也只有 CPU/内存两块有数，结果是"看起来支持了其实半残"，比现在明确的空更难排查。

**oracle 的容器视图看这两处**：本仓库自建的 `multicluster-overview`（查原始的
`container_cpu_usage_seconds_total` / `container_memory_working_set_bytes` +
`cluster=~"$cluster"`，两集群都有数），或 Grafana Explore 直接查原始指标。

## Service Health Checks

All services have liveness and readiness probes configured:

### oracle-k3s

| Service | Probe Path | Port |
|---------|-----------|------|
| it-tools | `GET /` | 80 |
| bentopdf | `GET /` | 8080 |
| squoosh | `GET /` | 8080 |
| miniflux | `GET /healthcheck` | 8080 |
| rsshub | `GET /healthz` | 1200 |

### k3s-homelab

| Service | Probe Path | Port |
|---------|-----------|------|
| calibre-web | `GET /login` | 8083 |

## Troubleshooting

### 常用命令

```bash
# 查看 OTel Collector 运行状态
kubectl get ds -n monitoring | grep otel
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector -f

# 查看 Calibre-Web 日志实时输出（主容器直接输出 stdout，无需 sidecar）
kubectl logs -n personal-services -l app=calibre-web -c calibre-web -f

# 在 Loki 查询某 namespace 所有日志
{k8s_namespace_name="personal-services"}

# 按容器名过滤（同 pod 内的 sidecar 是独立一路日志流）
{k8s_namespace_name="personal-services", k8s_container_name="permission-fixer"}

# 错误日志聚合
{k8s_namespace_name=~".+"} |~ "(?i)(error|exception|fatal|panic)"

# 部署 / 移除 OTel Collector（ArgoCD `otel-collector` App）
# 改 values/opentelemetry-collector.yaml → git push → ArgoCD 自动同步
```

---

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
但新的 receiver / pipeline 一条数据都没有。原因是 DaemonSet 的 pod template 没有 config
checksum 注解，ConfigMap 内容变了不会触发滚动，Pod 继续挂着旧配置跑；ArgoCD 只比对对象
本身，看不出这层。2026-07 引入 OpenCost 和 KRR 时各踩了一次（homelab 侧没这问题，Helm chart
会自动打 checksum 注解）。

**根治做法（已生效）：** 配置改由根 `cloud/oracle/manifests/kustomization.yaml` 的
`configMapGenerator` 生成：生成的 ConfigMap 名字带内容哈希后缀，并自动重写 DaemonSet 的
volume 引用，所以内容一变名字就变，DaemonSet 随之滚动。改配置只需编辑
`cloud/oracle/manifests/monitoring/otel-collector-config.yaml` 后 push，**不需要任何手动重启**。

2026-08-06 实测复核：新增 `prometheus/readlist` receiver 后，ConfigMap 名变成
`otel-collector-config-2g4gm5979k`，DaemonSet 自动滚动、Pod age 归零、新指标立即上来。

**要守住的不变量：** 那份配置必须留在 `configMapGenerator` 里。谁要是把它改回普通
ConfigMap 资源（比如为了"看起来整齐"），上面那个静默失败立刻回来，而且照样是 Synced/Healthy。

```bash
# 只在怀疑没生效时核对：ConfigMap 名应带哈希后缀，且 DS 引用的就是它
kubectl --context oracle-k3s -n monitoring get cm | grep otel-collector-config
kubectl --context oracle-k3s -n monitoring get ds otel-collector \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}{"\n"}'
```

## 历史决策与 Tradeoff

| 决策 | 选择 | 原因 |
|------|------|------|
| 采集层 | OTel Collector DaemonSet | 替换 Promtail；统一 OTel 语义，支持 logs/metrics/traces 三个信号 |
| 传输协议 | OTLP HTTP → Loki `/otlp` | `loki` exporter 在 contrib v0.145.0 已移除；OTLP 是 Loki 3.x 原生协议 |
| 追踪传输 | OTLP gRPC → Tempo :4317 | gRPC 双向流更适合 trace 数据；跨集群走 Tailscale NodePort :31317 |
| 文件日志方案 | log-exporter sidecar (busybox)，当前无实例 | 当年判断「linuxserver.io 镜像不输出 stdout」；2026-08-29 复核该前提已不成立（CWA 输出 stdout），唯一实例删除，模式保留备用 |
| Dashboard 管理 | ConfigMap + ArgoCD GitOps | 持久化，不依赖 Grafana DB，重建集群无损 |
| label 设计 | 使用 OTel 语义标签 | 与 Grafana Labs 官方 Dashboard 兼容，无需自定义映射 |
| 内存保护 | memory_limiter 200MiB/50MiB | 防止 OTel Collector OOM，背压式流控 |

---

## 相关文件索引

| 文件 | 说明 |
|------|------|
| `k8s/helm/values/opentelemetry-collector.yaml` | OTel Collector Helm values（logs + traces） |
| `cloud/oracle/values/tempo.yaml` | Tempo Helm values（traces backend） |
| `k8s/helm/values/kube-prometheus-stack.yaml` | Grafana datasources（Tempo tracesToLogs/Metrics） |
| `cloud/oracle/manifests/monitoring/monitoring-external.yaml` | oracle 侧跨集群 NodePort：Loki 31080 / Tempo 写 31317 / 查询 31320（homelab 侧仅剩 Prometheus remote_write 31090） |
| `cloud/oracle/manifests/monitoring/otel-collector.yaml` | Oracle-k3s OTel Collector（logs + metrics + traces） |
| `cloud/oracle/values/loki.yaml` | Loki config（promtail.enabled: false） |
| `k8s/helm/manifests/monitoring/dashboards/grafana-dashboards.yaml` | 4 个 Loki Dashboard ConfigMap |
| `cloud/oracle/manifests/personal-services/calibre-web.yaml` | 曾是 log-exporter sidecar 的唯一实例；2026-08-29 删除（文件内留有原因注释） |
| `argocd/applications/monitoring-dashboards.yaml` | Dashboard GitOps Application |
| `argocd/applications/otel-collector.yaml` | OTel Collector GitOps Application（chart + values） |
| `docs/plans/2026-02-21-otel-log-migration.md` | Promtail → OTel 迁移的实施与选型（含原设计的 tradeoff） |
| `docs/plans/2026-02-21-grafana-loki-dashboards.md` | Loki 看板的实施与选型（含原设计的 tradeoff） |
