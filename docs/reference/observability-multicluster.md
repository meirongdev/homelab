# Multi-Cluster Observability Architecture

> Last updated: 2026-10-28
> Status: 生效事实
>
> 遥测的**采集与汇聚侧**：三条管线怎么跨集群流动、应用怎么接日志/追踪、坏了怎么查。
> 消费侧（告警路由、看板组织约定、SLI/SLO）见
> [observability-alerting-slo.md](observability-alerting-slo.md)。

## Overview

⚠️ 遥测不是单向的，排查时别默认所有信号往同一个方向走：

- **日志 / 追踪**汇聚在 oracle-k3s（Loki/Tempo）：homelab 跨 Tailscale 写出，oracle 集群内直达。
- **指标**汇聚在 homelab（Prometheus/Alertmanager）：oracle 经 `prometheusremotewrite` 跨 Tailscale 写入。
- **Grafana** 留在 homelab 贴着 Prometheus，经 NodePort 跨 Tailscale 查 oracle 的 Loki/Tempo。
- **外部主机**（非 K8s）：dgx-spark ×2、macbook、mac-studio 只有指标，由 homelab Prometheus 经 Tailscale 拉取。

Loki/Tempo 放 oracle：homelab 是内存与磁盘吃紧的笔记本 VM，而 Loki/Tempo 是纯「写入-存储」组件，
不像 Prometheus 要贴着抓取目标，是 LGTM 里唯一能安全切出去的子集。附带收益：homelab 整机故障时
故障前的日志与追踪还在。取舍见
[plans/2026-08-02-homelab-to-oracle-workload-migration.md](../plans/2026-08-02-homelab-to-oracle-workload-migration.md)。

```
homelab (100.94.186.7)                       oracle-k3s (100.107.166.37)
  otel-collector  --logs-->  :31080  ------>  Loki gateway
                  --trace--> :31317  ------>  Tempo (OTLP gRPC)
  Grafana  --query-->  :31080 (Loki) / :31320 (Tempo)
  Prometheus :31090  <------- PRW ---------  otel-collector (prometheus/* receivers)
                                              otel-collector (filelog / otlp) --> Loki / Tempo，集群内直达
```

⚠️ Tempo 的写入口（4317/gRPC → 31317）与查询口（3200/HTTP → 31320）是两个端口，Loki gateway
（:80 → 31080）一个口兼做写入与查询。只开 31317 的症状是「trace 写得进去、Grafana 查不出来」。

## Cluster Label Strategy

所有指标都带 `cluster` 标签，多集群看板与告警按它切分：

| 来源 | 机制 | Label |
|------|------|-------|
| homelab（集群内抓取） | Prometheus `scrapeClasses` 默认类的 relabeling | `cluster=homelab` |
| homelab 宿主（pve、storage-106） | `additionalScrapeConfigs`，逐 target 写 | `cluster=homelab` |
| oracle-k3s（全部指标） | OTel `resource` processor + `prometheusremotewrite` `external_labels` | `cluster=oracle-k3s` |
| dgx-spark（2× GB10 裸机） | `additionalScrapeConfigs`（Tailscale 拉取） | `cluster=dgx-spark` |
| macbook / mac-studio | 同上 | `cluster=macbook` / `cluster=mac-studio` |

- 默认类是 `default: true`，对所有 ServiceMonitor 自动生效，新组件不用自己补 `relabelings`（判据：chart 自带的
  kube-state-metrics ServiceMonitor 没有任何 relabeling，指标照样带 `cluster="homelab"`）。
- ⚠️ `additionalScrapeConfigs` 原样注入，scrapeClasses 不作用于它们，`cluster` / `nodename` 必须逐 target 写。
- ⚠️ Prometheus `externalLabels` 只作用于 remote_write/federation，本地查询看不到，靠它给 homelab 打 `cluster` 无效。
- ⚠️ `cluster` 表示「谁报的这个指标」，不是集群成员：pve 与 storage-106 承载 homelab 的节点 VM，
  也标 `cluster=homelab`。按 cluster 数节点、算节点内存时要钉 `job="node-exporter"`。

## Log Pipeline

### oracle-k3s → Loki（集群内直达）

配置在 `cloud/oracle/manifests/monitoring/otel-collector-config.yaml`（receivers/pipelines 全在这里，同目录
`otel-collector.yaml` 只有 RBAC/Service/DaemonSet）。管道 `filelog → k8sattributes → resource → batch → otlphttp`：

1. filelog 读 `/var/log/pods/*/*/*.log`，从文件路径提取 namespace / pod / uid / container，提升为 `resource["k8s.*"]`
2. k8sattributes 按 `k8s.pod.uid` 查 K8s API，补 `k8s.deployment.name`、`k8s.node.name` 等
3. resource 打 `cluster: oracle-k3s`
4. otlphttp 发到 `http://loki-gateway.monitoring.svc.cluster.local/otlp`

☠️ 路径提取的属性必须先进 resource，k8sattributes 才关联得上 pod，否则日志在 Loki 里全是
`unknown_service`、没有 namespace/pod 标签（见 [Troubleshooting](#oracle-日志在-loki-里是-unknown_service)）。

### homelab → Loki（oracle，跨 Tailscale）

- Helm chart `open-telemetry/opentelemetry-collector` 0.165.0，镜像 `otel/opentelemetry-collector-k8s`（k8s 官方裁剪
  发行版），values `k8s/helm/values/opentelemetry-collector.yaml`，ArgoCD `otel-collector` App（改 values → push → 自动同步）。
- preset `logsCollection` 挂 `/var/log/pods` 并注入 filelog（`container` operator 自动解析路径、关联 pod）；
  preset `kubernetesAttributes` 申请 RBAC，从 K8s API 补 pod metadata。
- 发往 oracle `http://100.107.166.37:31080/otlp`。oracle 侧不是这个形态，那边是手写清单。

### Loki 标签

Loki 3.x 原生收 OTLP（`/otlp/v1/logs`），把 OTel resource attributes 提升为 stream label。
索引标签全集（2026-07-31 对 `/loki/api/v1/labels` 实测）：

| Label | 来源 | 示例 |
|-------|------|------|
| `cluster` | resource processor（与 Prometheus 侧一致） | `homelab` / `oracle-k3s` |
| `k8s_namespace_name` | container operator + k8sattributes | `personal-services` |
| `k8s_pod_name` | 同上 | `calibre-web-569cc4444d-rfw67` |
| `k8s_container_name` | 同上；同 pod 多容器各成一路 | `calibre-web` / `permission-fixer` |
| `k8s_deployment_name` | k8sattributes | `calibre-web` |
| `service_name` | OTel resource attr（SDK 上报的服务） | `calibre-web` |

`k8s.node.name`、`log.iostream` 等在 structured metadata 里，不是索引标签，用管道过滤：
`{k8s_namespace_name="x"} | log_iostream="stderr"`。

filelog 有 `file_storage` checkpoint，collector 重启后从断点续读，不重复不漏采；只有首次部署因
`start_at: end` 只采新增行。

## 应用日志接入模式

新服务接日志前先对一遍这四种，多数是模式 A、零配置。

### 模式 A：标准 stdout/stderr（推荐）

应用写 stdout/stderr，容器运行时落到 `/var/log/pods/<namespace>_<pod>/<container>/*.log`，filelog 自动采集。
查询：`{k8s_namespace_name="personal-services", k8s_container_name="it-tools"}`

### 模式 B：文件日志 + log-exporter sidecar

☠️ 这个模式的失败是静默的，不验证等于没加。当前没有在用的实例：唯一那个（calibre-web）2026-08-29
删除，它 tail 的文件在镜像里根本不存在，`tail -F` + `2>/dev/null` 永久无输出，无告警无报错
（`cloud/oracle/manifests/personal-services/calibre-web.yaml` 里留有删除注释）。

只给日志只写容器内文件、不写 stdout 的应用用。⚠️ 别按镜像血统预设：linuxserver.io 系列（含 Calibre-Web）
如今输出 stdout。先看 `kubectl logs` 有没有东西，有就用模式 A。做法是同 Pod 加一个 `busybox` sidecar，
共享应用的 volume，`tail -F` 到自己的 stdout：

```yaml
- name: log-exporter
  image: busybox
  command: ["sh", "-c", "tail -F /path/to/app.log 2>/dev/null"]
  resources:
    requests: {cpu: 1m, memory: 8Mi}
    limits: {memory: 16Mi}
  volumeMounts:
    - name: <shared-volume-name>
      mountPath: /path/to/log/dir
      readOnly: true
```

```bash
# 加之前：主容器 stdout 确实是空的？（不空就用模式 A）
kubectl --context <ctx> logs -n <ns> <pod> -c <app-container> --tail=20
# 找实际日志路径（会随上游版本变，别照抄常量）
kubectl --context <ctx> exec -n <ns> <pod> -c <app-container> -- find / -name "*.log" 2>/dev/null | grep -v proc
# 加完必做：sidecar 自己有输出吗？空 = tail 的路径不对，不是「还没有日志」
kubectl --context <ctx> logs -n <ns> <pod> -c log-exporter --tail=5
```

再到 Grafana Explore → Loki 查 `{k8s_namespace_name="<ns>", k8s_container_name="log-exporter"}`，无数据 = 没接上。

### 模式 C：OTel SDK 直推（结构化日志 / 追踪）

自研服务在代码里集成 OTel SDK，经 OTLP 直推本集群 collector，带 traceID/spanID，Grafana 里能
Loki ↔ Tempo 联动。要改代码或 Dockerfile，适合新服务。环境变量模板见 [Traces Pipeline](#traces-pipeline)。

SDK：Go `go.opentelemetry.io/otel`（`otlptracegrpc`、`otelhttp`）· Java (Spring Boot) `opentelemetry-javaagent.jar`
（零代码，`ENV JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"`）· Node.js `@opentelemetry/sdk-node`
（`@opentelemetry/auto-instrumentations-node`）· Rust `opentelemetry-otlp`（`tracing-opentelemetry`、`tonic`）。

### 模式 D：已有 Prometheus exporter 的应用

指标走抓取，日志照模式 A/B 走 filelog，两者并行，无需特殊配置。

## Metrics Pipeline

### oracle-k3s → homelab Prometheus（OTel 推送）

collector（同一份 `otel-collector-config.yaml`）抓本集群的 exporter，经 `resource`（打 `cluster: oracle-k3s`）
→ `batch` → `prometheusremotewrite` 跨 Tailscale 推到 `http://100.94.186.7:31090/api/v1/write`，不需要 prometheus-agent。

| Receiver | Target | Interval | 备注 |
|----------|--------|----------|------|
| `prometheus/node-exporter` | `10.0.0.26:9100`（hostNetwork） | 15s | |
| `prometheus/kube-state-metrics` | `kube-state-metrics.monitoring.svc:8080` | 30s | |
| `prometheus/cloudflared` | `cloudflared-metrics.cloudflare.svc:2000` | 30s | |
| `prometheus/external-secrets` | `external-secrets-metrics.external-secrets.svc:8080` | 30s | |
| `prometheus/external-dns` | `external-dns.external-dns.svc:7979` | 30s | |
| `prometheus/cilium-envoy` | `cilium-envoy.kube-system.svc:9964` | 30s | keep 正则只留 RED SLI 指标 |
| `prometheus/opencost` | `opencost.opencost.svc:9003` | 60s | `honor_labels: true` |
| `prometheus/cadvisor` | `10.0.0.26:10250/metrics/cadvisor` | 60s | https + SA token，见下 |
| `prometheus/clustermesh` | `clustermesh-apiserver-metrics.kube-system.svc:9964` | 60s | 只 keep `cilium_kvstoremesh_remote_cluster*` |
| `prometheus/trivy-operator` | `trivy-operator.trivy-system.svc:8080` | 60s | |
| `prometheus/readlist` | `readlist.personal-services.svc:8080` | 300s | 数据一天才变一次 |
| `prometheus/falco` | `falco-metrics.falco.svc:8765` | 60s | 需 values 里两个开关同时开 |
| `prometheus/falcosidekick` | `falco-falcosidekick.falco.svc:2801` | 60s | 投递链路（Telegram ok/error） |
| `prometheus/argocd` | pod 发现：`argocd` ns 里 application-controller 的 `metrics`(8082) 端口 | 60s | 只 keep `argocd_app_info` / `argocd_cluster_connection_status`；ArgoCD 是 manual-helm，不开 chart 的 metrics Service |

`prometheus/cadvisor` 直连 kubelet：

- ClusterRole 必须含 `nodes/metrics`，只给 `nodes` 会 403（kubelet 自己做 SubjectAccessReview，`kubectl auth can-i` 在这里会误报 yes）。
- `insecure_skip_verify: true`：k3s kubelet 服务证书自签，且 SAN 不含节点 IP。
- keep 正则只留少数容器指标（清单与各自的消费者写在配置里正则旁的注释），并 drop `container=""` 的 Pod 级汇总。
- 不够给 OpenCost 当 Prometheus 数据源（缺 `container_fs_*` / `container_network_*`），见 [cost-and-rightsizing.md](cost-and-rightsizing.md)。

### homelab Prometheus（集群内抓取）

kube-prometheus-stack 原生抓取，`scrapeClasses` 默认类打 `cluster: homelab`。采集面按消费者裁剪过
（`values/kube-prometheus-stack.yaml` 末尾 `kubelet` / `kubeApiServer` 的 `serviceMonitor.metricRelabelings`）：

- ☠️ k3s 的 apiserver 与 kubelet 是同一个进程，kubelet 的 `/metrics` 吐出整个进程的 registry，全套
  `apiserver_*` / `etcd_*` 会被抓两遍。所以 kubelet 侧整族 drop `(apiserver|etcd)_.*`，apiserver 侧另 drop 7 族
  无 rule、无面板引用的 histogram；保留 `apiserver_request_sli_duration_seconds_bucket`（`kube-apiserver-histogram.rules`
  两条 recording rule 在用）。
- ⚠️ 两个 key 的 chart 默认 `metricRelabelings` 不是空的，list 是整体覆盖，所以默认值原样抄进来再追加
  （当前抄自 chart 87.6.0），升 chart 时要重新比对。
- ⚠️ 面板查的是 recording rule 输出（`cluster_quantile:...`），不受影响；但原始 bucket 已无法 ad-hoc 查询。

判据、被否决的选项、验证方法与前后数值见 [decisions/prometheus-series-reduction.md](../decisions/prometheus-series-reduction.md)。

`additionalScrapeConfigs`（`100.x` 地址都经 Tailscale）：

| Job | Target | Labels / 备注 |
|-----|--------|---------------|
| `node-exporter-metal-nodes` | `192.168.50.106:9100`（storage-106）· `192.168.50.4:9100`（pve） | `cluster=homelab` |
| `node-exporter-dgx-spark` | `100.97.87.120:9100` / `100.67.164.92:9100` | `cluster=dgx-spark` |
| `node-exporter-macbook` | `100.89.15.120:9100` | `cluster=macbook` / `nodename=macbook-pro`；`metric_relabel_configs` 把 `omlx_*` 改名 `omlx_alltime_*` |
| `node-exporter-mac-studio` | `100.98.220.75:9100` | `cluster=mac-studio` / `nodename=mac-studio`；YAML 锚点共用同一条改名规则 |
| `macmon` | 两台 Mac 的 `:9090` | 同上；`metric_relabel_configs` 丢掉坏读数（见下） |
| `omlx-status` / `omlx-models` | 每台 Mac 的 `:8000` 一个 target，relabel 进 `?target=`，实际抓 `json-exporter.monitoring.svc:7979/probe` | 同上，`instance` = Mac 的 URL |
| `smartctl-storage-106` / `smartctl-proxmox-pve` / `smartctl-dgx-spark` | `:9633`，120s | `nodename` 与 node-exporter job 对齐 |
| `dgx-inference` | DGX 推理引擎 `/metrics`；target、端口、引擎以 values 里该 job 的注释为准 | `cluster=dgx-spark`。☠️ 端口与指标前缀（`vllm:*` / `sglang:*`）随上游换栈而变，过期不报错，只是 target 掉线、规则恒空；告警/面板对两个前缀取 `or` 并集。job 名刻意中性（原 `vllm-dgx-spark`），换引擎不用改 |

### 外部主机（非 K8s，metrics-only）

- **dgx-spark**（2× GB10）：node_exporter 在 `nv-dgx-spark` 仓库用 `make node-exporter-deploy` 部署（docker
  `--net=host --pid=host`）。看板「DGX Spark / Node Exporter」。Tailnet ACL 已放行 `tag:homelab → *:*`。
- **macbook**（Apple Silicon 笔记本）：node_exporter 是预编译 `darwin-arm64` 二进制 `~/.local/bin/node_exporter`
  （不是 Homebrew：那台 Mac 出不了 GitHub，tarball 是 `scp` 进去的），LaunchAgent `com.prometheus.node_exporter.plist`
  拉起（`:9100`，无 sudo）。SSH `ssh -i ~/.ssh/vgio matthew@100.89.15.120`。⚠️ 它无头常开（`pmset disablesleep`），
  `TargetDown` 响了就是真故障，别当睡眠抖动 silence；`omlx-*` 挂而 `node-exporter-macbook` 活 = Mac 在、OMLX 不在
  （排查见 [omlx-inference-metrics.md](omlx-inference-metrics.md) 陷阱第 4 条）。
- **mac-studio**（M5 Max / 128G 台式机）：链路与 macbook 相同。SSH `ssh -i ~/.ssh/vgio matstudio@100.98.220.75`
  （⚠️ 用户名是 `matstudio`）。`just power` 给它加了 `pmset autorestart 1`（断电恢复后自己开机），所以它在
  `NodeRebooted` 覆盖面里，macbook 不在。看板与 macbook 共用（「Mac / Node Exporter」「Mac OMLX 推理」，顶部选机器）。
- 两台 Mac 同一套 Ansible `macbook/ansible/`，配方带主机名只跑那台（如 `cd macbook/ansible && just node-exporter mac-studio`），
  GUI-only 步骤在其 README。
  - 功耗/温度/风扇来自 macmon（`cd macbook/ansible && just macmon`，LaunchAgent `:9090`，无 sudo）→ job `macmon`
    →「Mac / Node Exporter」的「🌡️ 功耗 / 温度」行；Darwin 版 node_exporter 没有温度/功耗指标。
    ☠️ macOS 27 上 CPU/内存/ANE 功耗恒为 0（满载也是 0，是读不到），抓取时已丢，面板只拆「整机 / GPU / 其余」；
    整机功耗是 SMC `PSTR`（SoC 侧，不是墙插功率）。☠️ macbook 的 CPU 温度是坏的（P 核断电时探头读数接近 0），
    也已丢，看它的 GPU 温度。口径与压测数字见 `macbook/ansible/playbooks/macmon.yaml` 文件头。
  - OMLX 推理计数器经 node_exporter 的 textfile collector 吐出，抓取时改名 `omlx_alltime_*`。部署要跑两个配方，
    少一个不报错、指标静默不出现，见 [omlx-inference-metrics.md](omlx-inference-metrics.md)（唯一真相源）。
  - ☠️ 再加一台 Mac 要改四处，漏哪处都不报错：inventory（`macbook/ansible/inventory.yaml`）· 新的
    `node-exporter-<mac>` job 挂上 `*omlx_alltime_rename` · `omlx-*` 两个 job 各加一个 target ·
    「Mac / Node Exporter」面板里写死的 job 正则（常开的台式机另把 job 加进 `NodeRebooted`）。功耗/温度再加两处：
    inventory 的 `macmon` 组 + `macmon` job 的一个 target（先在那台上压测一次，看哪些读数是坏的）。
- **SMART 磁盘健康**：Linux 裸机跑 `smartctl_exporter`（`:9633`）。storage-106 + pve（amd64）走
  `cd proxmox/ansible && just node-exporter`（同一 playbook 装 node_exporter + smartctl_exporter）；DGX ×2（arm64）在
  `nv-dgx-spark` 仓库跑 `make smartctl-exporter-deploy`，不是容器（`quay.io/...` 镜像只有 amd64，`linux-arm64`
  二进制在控制机下载后 SSH 分发）。macbook 无 SMART（Apple Silicon 内置 NVMe 不暴露标准属性）。看板在 Grafana
  `Hardware` 文件夹。
  - ⚠️ 指标名（v0.14.0）写错，面板静默空白：磁盘温度是 `smartctl_device_temperature{temperature_type="current"}`
    （NVMe+SATA 统一），不是 `smartctl_device_temperature_celsius`。SSD 磨损：NVMe 用 `100 - smartctl_device_percentage_used`；
    SATA 用 `smartctl_device_attribute{attribute_value_type="value", attribute_name=~"Media_Wearout_Indicator|Wear_Leveling_Count|SSD_Life_Left|Percent_Lifetime_Remain"}`
    （`"value"` = 归一化，100 = 新），旧名 `smartctl_attr_normalized_value` 已不存在。

## Traces Pipeline

两集群的 collector 都开 OTLP receiver（gRPC `:4317` / HTTP `:4318`）。应用发给本集群 ClusterIP
`otel-collector.monitoring.svc`，collector 打 `cluster` 后转给 oracle 上的 Tempo。
管道：`otlp → memory_limiter → resource → batch → otlp/tempo`。

- homelab：跨 Tailscale 写 `100.107.166.37:31317`，带持久化发送队列（file_storage，链路中断不丢缓冲）。
- oracle-k3s：集群内直达 `tempo.monitoring.svc.cluster.local:4317`。

采样在应用 SDK 侧做 head sampling（`parentbased_traceidratio`，0.1）。`cluster` 由 collector 统一打，应用不用设。
接入模板：

```yaml
env:
  - name: OTEL_SERVICE_NAME
    value: "<service-name>"
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector.monitoring.svc.cluster.local:4318"   # gRPC 用 :4317
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "http/protobuf"
  - name: OTEL_TRACES_SAMPLER
    value: "parentbased_traceidratio"
  - name: OTEL_TRACES_SAMPLER_ARG
    value: "0.1"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "deployment.environment=prod,service.namespace=<namespace>"
```

Grafana 的 Tempo 数据源是 `http://100.107.166.37:31320`（oracle `tempo-query-external`），已配 tracesToLogs
（`filterByTraceID` / `filterBySpanID`）、tracesToMetrics、nodeGraph、serviceMap。

## 跨集群 NodePort

| 集群 | Service | NodePort | 用途 |
|------|---------|----------|------|
| homelab | `prometheus-otlp-external` | 31090 | 收 oracle collector 的 remote_write |
| oracle-k3s | `loki-gateway-external` | 31080 | 收 homelab 的日志，兼 Grafana 日志查询口 |
| oracle-k3s | `tempo-otlp-external` | 31317 | 收 homelab 的追踪（OTLP gRPC） |
| oracle-k3s | `tempo-query-external` | 31320 | Grafana 追踪查询口（3200/HTTP） |

清单：`k8s/helm/manifests/monitoring/monitoring-external.yaml`（homelab）·
`cloud/oracle/manifests/monitoring/monitoring-external.yaml`（oracle）。

- ⚠️ homelab 侧已没有 Loki/Tempo 的 NodePort，别在 `k3s-homelab` 里找。
- oracle 的 kube-state-metrics NodePort（31082）不再用于跨集群抓取：collector 在集群内经 ClusterIP 抓。

## Grafana Dashboards

- 4 个 Loki 看板（`k8s/helm/manifests/monitoring/dashboards/grafana-dashboards.yaml`），都有 `cluster` 下拉：
  `k8s-logs-overview` · `k8s-logs-pod` · `k8s-logs-errors` · `k8s-logs-search`。变量 `cluster` =
  `label_values(cluster)`，multi + includeAll，`allValue: ".+"`；LogQL 一律 `{cluster=~"${cluster}", ...}`。
- 多集群资源总览（`uid: k8s-multicluster-overview`，`dashboards/multicluster-overview-dashboard.yaml`）：节点、Pod、
  工作负载健康与容器用量对 limit，变量 `cluster` / `namespace` / `phase`。「📦 容器资源使用」行有两张按容器取 TOP10
  的面板，红线对齐告警：CPU 节流率 25%（`ContainerCPUThrottlingSustained`）、内存 RSS / Limit 80%（`ContainerMemoryNearLimit`）。
  - ⚠️ RSS 面板与左边的 working_set 面板口径不同，并排就是为了看差别：working_set 含页缓存，对 mmap/文件重的负载
    显著偏高（[records/2026-08-30-memory-alert-page-cache-false-alarm.md](../records/2026-08-30-memory-alert-page-cache-false-alarm.md)）。
  - ⚠️ 没设 CPU limit 的容器在节流面板里整个缺席：cAdvisor 只为有 quota 的容器吐 `container_cpu_cfs_*`，是无数据，不是节流为 0。
- 没有 Cloudflare 隧道看板，隧道能看到什么见 [cloudflare-tunnel-observability.md](cloudflare-tunnel-observability.md)；
  入口层 RED 指标来自 Cilium Envoy（[observability-alerting-slo.md](observability-alerting-slo.md)）。
- 看板加载：Grafana 的 `grafana-sc-dashboard` sidecar watch `monitoring` ns 里带 `grafana_dashboard: "1"` label 的
  ConfigMap，增改即热重载、删除即移除，`data` 的 key 必须以 `.json` 结尾。这些 ConfigMap 由 ArgoCD
  `monitoring-dashboards` App 管理。

### ☠️ chart 内置 mixin 看板选 `oracle-k3s` 恒为空（已知、刻意，不是故障）

kube-prometheus-stack 自带的 Compute Resources / Namespace(Pods) / Pod / Node 看板（开了
`sidecar.dashboards.multicluster.global.enabled`，所以有 `$cluster` 下拉）查的是
`node_namespace_pod_container:*` 这类录制规则，规则选择器写死 `{image!="", job="kubelet", metrics_path="/metrics/cadvisor"}`。
oracle 的容器指标经 OTel 进来，是 `job="kubelet-cadvisor"` 且没有 `metrics_path`，永远匹配不上；往 keep 正则加指标也没用。

- ⚠️ 别靠改 job 名去「修」：`kubelet-cadvisor` 是 `values/kube-prometheus-stack.yaml` 里 disable `KubeletDown`、自建版本
  硬写 `cluster="homelab"` 的前提（设计说明在那里）；而且 mixin 还依赖一大批没进 keep 正则的 `container_network_*` /
  `container_fs_*`，改了也只有 CPU/内存有数，半残比明确的空更难排查。
- oracle 的容器视图看自建的多集群资源总览（查原始 `container_*` 指标 + `cluster=~"$cluster"`），或在 Explore 直接查。

## Troubleshooting

### 常用命令

```bash
# collector 状态与日志（两集群的 DaemonSet 都叫 otel-collector）
kubectl --context k3s-homelab -n monitoring get ds otel-collector
kubectl --context oracle-k3s  -n monitoring get ds otel-collector
kubectl --context <ctx> -n monitoring logs daemonset/otel-collector -f
```

LogQL（Grafana Explore → Loki）：某 ns 全部日志、按容器名过滤（同 pod 的 sidecar 是独立一路）、错误聚合：

```logql
{k8s_namespace_name="personal-services"}
{k8s_namespace_name="personal-services", k8s_container_name="permission-fixer"}
{k8s_namespace_name=~".+"} |~ "(?i)(error|exception|fatal|panic)"
```

### oracle 日志在 Loki 里是 `unknown_service`

k8sattributes 关联不上 pod：从文件路径提取的属性没有提升成 resource 属性。

- 查：`kubectl --context oracle-k3s -n monitoring logs daemonset/otel-collector | grep "evaluating pod identifier"`，各 source 值都应非空。
- 修：确认 filelog 的 operators 把 uid / namespace / pod / container 提升到 `resource["k8s.*"]`（见 [Log Pipeline](#log-pipeline)）。

### Loki 收不到日志

Loki 在 oracle，两集群的发送方都可能出问题：

1. 在 homelab 节点上测连通性：`curl http://100.107.166.37:31080/otlp/v1/logs`，返回 4xx 而不是超时即通。
2. oracle 侧 NodePort 在不在：`kubectl --context oracle-k3s -n monitoring get svc loki-gateway-external`。
3. 发送方：`kubectl --context k3s-homelab -n monitoring logs daemonset/otel-collector | grep -iE "url:|error"`，oracle 换 `--context oracle-k3s`。

### Prometheus 里没有 oracle 指标

oracle 的指标是推过来的，查 collector：

1. `kubectl --context oracle-k3s -n monitoring logs daemonset/otel-collector --tail=30`；`Failed to scrape Prometheus endpoint` = pod 内够不着那个 target。
2. Grafana Explore → Prometheus：`count by (cluster, job) ({cluster="oracle-k3s"})`
3. Tailscale 连通：`kubectl --context oracle-k3s exec -n monitoring daemonset/otel-collector -- wget -qO- http://100.94.186.7:31090/api/v1/status/runtimeinfo 2>/dev/null | head`

### homelab 指标缺 `cluster` 标签

确认 `k8s/helm/values/kube-prometheus-stack.yaml` 的 `prometheusSpec.scrapeClasses` 有默认类且其 `relabelings` 打
`cluster: homelab`；`additionalScrapeConfigs` 的 job 要逐 target 写。见 [Cluster Label Strategy](#cluster-label-strategy)。

### otel-collector 配置改了不生效

已根治，别再手动 rollout restart。oracle collector 的配置由 `cloud/oracle/manifests/` 下 kustomize 的
`configMapGenerator` 生成：ConfigMap 名带内容哈希，并自动重写 DaemonSet 的 volume 引用，内容一变 DaemonSet
就滚动，改 `otel-collector-config.yaml` 后 push 即可。homelab 侧本来就没这个问题（Helm chart 在 pod template 上打 checksum 注解）。

☠️ 这份配置必须留在 `configMapGenerator` 里。改回普通 ConfigMap 资源，「ConfigMap 变了 pod 不重启」的静默失败
立刻回来，而 ArgoCD 照样 Synced/Healthy。经过见
[records/2026-08-02-oracle-otel-config-not-reloaded.md](../records/2026-08-02-oracle-otel-config-not-reloaded.md)。

```bash
# 怀疑没生效时核对：ConfigMap 名应带哈希后缀，且 DaemonSet 引用的就是它
kubectl --context oracle-k3s -n monitoring get cm | grep otel-collector-config
kubectl --context oracle-k3s -n monitoring get ds otel-collector \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}{"\n"}'
```

## 历史决策与 Tradeoff

| 决策 | 选择 | 原因 |
|------|------|------|
| 采集层 | OTel Collector DaemonSet | 取代 Promtail；logs/metrics/traces 统一 OTel 语义 |
| 日志传输 | OTLP HTTP → Loki `/otlp` | `loki` exporter 在 contrib v0.145.0 已移除；OTLP 是 Loki 3.x 原生协议 |
| 追踪传输 | OTLP gRPC → Tempo :4317 | gRPC 双向流更适合 trace；跨集群走 NodePort 31317 |
| 文件日志 | log-exporter sidecar，当前无实例 | 前提「linuxserver.io 镜像不写 stdout」已不成立，模式保留备用 |
| 看板管理 | ConfigMap + ArgoCD | 不依赖 Grafana DB，重建集群无损 |
| 标签 | OTel 语义标签 | 与 Grafana Labs 官方看板兼容，无需自定义映射 |
| 内存保护 | `memory_limiter` | 防 collector OOM，背压式流控；限值见两侧配置 |

collector 选型见 [decisions/otel-2026-alignment.md](../decisions/otel-2026-alignment.md)；原始方案见
[plans/2026-02-21-otel-log-migration.md](../plans/2026-02-21-otel-log-migration.md)、
[plans/2026-02-21-grafana-loki-dashboards.md](../plans/2026-02-21-grafana-loki-dashboards.md)。

## 相关文件索引

- homelab collector：`k8s/helm/values/opentelemetry-collector.yaml` · `argocd/applications/otel-collector.yaml`（chart 版本）
- oracle collector：`cloud/oracle/manifests/monitoring/otel-collector-config.yaml`（管道）· `otel-collector.yaml`（RBAC/DS）
- Prometheus 抓取与 Grafana 数据源：`k8s/helm/values/kube-prometheus-stack.yaml`
- Loki / Tempo：`cloud/oracle/values/loki.yaml`（promtail 已关）· `cloud/oracle/values/tempo.yaml`
- 跨集群 NodePort：两侧的 `monitoring-external.yaml`（见上表）
- 看板：`k8s/helm/manifests/monitoring/dashboards/` · `argocd/applications/monitoring-dashboards.yaml`
