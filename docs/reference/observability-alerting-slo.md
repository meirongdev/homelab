# Observability — 告警、看板组织与 SLO

> Last updated: 2026-08-03
> Status: 生效事实
>
> 遥测的**消费侧**：告警路由与覆盖盲区、Grafana 看板组织约定、SLI/SLO 体系。
> **采集侧**（日志/指标/追踪怎么跨集群汇聚）见
> [observability-multicluster.md](observability-multicluster.md) 与
> [observability-otel-logging.md](observability-otel-logging.md)。

## 告警（Alertmanager → Telegram）

- **路由**（2026-07-18 起）: `severity: warning|critical` 经 Alertmanager 原生 `telegramConfigs`
  （零中间 bridge）发到群 **MatthewDaily** 的「🚨 Homelab 告警」话题
  （`chatID: -1003981213530` + `messageThreadID: 2`）；`info` 丢弃。bot token:
  Vault `secret/homelab/telegram` → ESO（`alertmanager-telegram-secret.yaml`）。
  一条规则覆盖双集群（oracle 指标带 `cluster=oracle-k3s` remote-write 过来）。
  旧 `alertmanager-gotify-bridge` 与 Gotify 本体已于 2026-07 下线，取舍见
  [../decisions/alerting-telegram-migration.md](../decisions/alerting-telegram-migration.md)。
- **`Watchdog` 不丢弃** —— `watchdog` AlertmanagerConfig CRD 抢先把它 webhook 到 oracle
  Uptime Kuma 的 push monitor（dead-man's switch：告警链路本身死了会在状态页变红）；
  静态路由树的 `null` receiver 只接真正没人认领的告警。
- **⚠️ 新增 `PrometheusRule`/`ServiceMonitor` 必须带 label `release: kube-prometheus-stack`**，
  否则 operator 的 `ruleSelector`/`serviceMonitorSelector` 静默忽略。
- oracle 侧 Falco 告警走独立的 Falcosidekick 原生 Telegram output（同 bot 同话题、代码路径
  不同、互不依赖），见 [security.md §8.5](security.md)。
- **ESO 健康告警**（第一条自建规则，`manifests/monitoring/alerts/eso-alerts.yaml`）:
  `externalsecret`/`(cluster)secretstore` `Ready=False` 即报——堵住"Vault 封印/token 过期 →
  Secret 停止刷新但 app 还在用旧值"的静默盲区。前置的一次性 metrics 开关：homelab
  `just deploy-eso`（`serviceMonitor.enabled`）、oracle `just install-eso`
  （`--set metrics.service.enabled=true`）。

- **ClusterMesh 告警**（`manifests/monitoring/alerts/clustermesh-alerts.yaml`，2026-08-05 新增）:
  当天发现跨集群 mesh 双向断开且**零告警**，事后连"断了多久"都无法确定——`cilium_kvstoremesh_*`
  一条都没被抓。抓的是 clustermesh-apiserver 的 **kvstoremesh** 容器 `:9964`
  （homelab 走 `clustermesh-servicemonitor.yaml`，oracle 走 otel `prometheus/clustermesh`），
  **刻意不抓 cilium-agent 的同类指标**：那要开 `prometheus.enabled` 即对 Cilium 做 helm
  upgrade，而 oracle 侧 peer 配置未固化在仓库、升级会静默抹掉（见
  [tailscale-network.md](tailscale-network.md)）；且 agent 只连本集群缓存，
  真正断掉的那一跳恰恰是 kvstoremesh。
  三种**互不蕴含**的故障各一条规则：`readiness_status == 0`（配了连不上）·
  `remote_clusters == 0`（**peer 配置整个消失**——此时前者无序列可判，故必须单列）·
  `absent(...)`（看不见了，即 2026-08-05 那个盲区本身）。

### ⚠️ 告警覆盖 ≠ 抓取覆盖（2026-08-02 核实）

kube-prometheus-stack 的 node-exporter mixin 规则（`NodeMemoryHighUtilization` /
`NodeFilesystemAlmostOutOfSpace` / CPU 组）**全部硬编码 `job="node-exporter"`**，只覆盖两个
K3s 节点。裸机与外部主机跑在别的 job 名下（`node-exporter-metal-nodes` pve+106、
`node-exporter-dgx-spark`、`node-exporter-macbook`），mixin 一条都不匹配——实测症状：
pve `MemAvailable` 4.4% 而 `NodeMemoryHighUtilization` 恒 `inactive`。

**2026-08-02 已补齐**（`prometheus-rules.yaml` 的 `metal-nodes-resources` 组），且**刻意不做**
统一放宽 `job=~"node-exporter.*"`——几台机的正常态差别太大，统一阈值必然误报或漏报，
改成按主机定阈值。两个实测结论：

- **pve 的 ZFS ARC ≈ 0**（`node_zfs_arc_size` ≈ 0），低 `MemAvailable` 是**虚拟机分配**
  （K3s VM 独占 12.6GiB/15GiB）而非可回收缓存，且已用 1.07G swap → pve 用**绝对下限**
  （<300Mi），百分比阈值在 pve 上是永久误报。
- **106 正相反**: ARC 3.8G 可回收，`MemAvailable` 1.4G 严重低估（真实可用 ≈ 4.98G/7.57G）
  → 106 的表达式必须 `+ node_zfs_arc_size - node_zfs_arc_c_min`。

**⚠️ 写新规则前先确认指标存在**（否则写出永不触发的死规则）：DGX ×2 **没有
`node_filesystem_*`**（容器化 node_exporter 未挂宿主根，磁盘只能靠 SMART）；macbook
**没有 `node_memory_MemAvailable_bytes`**（darwin 无此指标）。
查法：`count by (job) (node_filesystem_size_bytes)`。

## Dashboards 组织

2026-06-15 整改（治理面板平铺混乱 + 跨集群指标叠加）。核心配置在
`values/kube-prometheus-stack.yaml` 的 `grafana.sidecar.dashboards`：

- **文件夹**: `folderAnnotation: grafana_folder` + `provider.foldersFromFilesStructure: true`。
  每个 dashboard ConfigMap 用注解 `grafana_folder: <名称>` 指定文件夹。当前布局:
  `Platform`（多集群总览, Home）/ `Logs` / `Hardware`（裸金属主机 + SMART）/ `Security` /
  `SLO` / `Kubernetes Built-in`（chart 自带 mixin 面板统一归档，不污染顶层）。
  - ⚠️ **归档 ≠ 禁用**: `nodeExporter.operatingSystem.{aix,darwin}.enabled: false` 只 gate
    mixin 的 **PrometheusRule** 不 gate dashboard——chart 87.6.0 仍渲染 aix/darwin 两个
    ConfigMap。kube-prometheus-stack **没有单面板开关**，真要移除只能整关
    `defaultDashboardsEnabled`（连带丢 20+ 张有用面板），不划算——维持归档现状。
- **多集群选择器**: `multicluster.global.enabled: true` 让 ~21 张内置 mixin 面板出现 `cluster`
  下拉；关闭时它们把多集群指标求和叠加，无法分析。
- **Home 面板**: `grafana.ini` 的
  `dashboards.default_home_dashboard_path: /tmp/dashboards/Platform/multicluster-overview.json`
  （sidecar 按 folder 注解写入子目录，故路径含 `Platform/`）。
- **数据源稳定 uid**: `prometheus` / `loki` / `tempo`。
  - **⚠️ 给已存在的数据源赋 uid 必须走 `grafana.deleteDatasources` + `additionalDataSources`
    删建重建**——Grafana 有持久化 PVC，库里已有按 name 自动生成随机 uid 的记录，直接在
    provisioning 加 `uid:` 会 `Datasource provisioning error: data source not found` 且
    **整 Pod CrashLoop**（2026-06-15 踩坑）。删建同 uid，幂等。
- **trace↔log↔metric 关联**: Tempo 数据源配 `tracesToLogsV2`→`loki` /
  `tracesToMetrics`→`prometheus` / `serviceMap`→`prometheus`（都是**后向引用**，Tempo 必须
  排在 Loki/Prometheus 之后）。**不要在 Loki 侧配指向 Tempo 的 `datasourceUid`**（前向引用
  → not found 崩溃）；logs→trace 跳转用 Grafana Correlations 单独加。
- **门户下钻用 tag 不用 UID**（内置面板 UID 会变）；自定义面板统一带 `curated` + 信号 tag
  （`logs`/`metrics`）。

**新增/修改 dashboard 的约定**（ConfigMap 放 `k8s/helm/manifests/monitoring/dashboards/`，
ArgoCD `monitoring-dashboards` App 目录源自动捡起——**无需登记文件清单**，该 App 已是
recurse 目录源）：

1. ConfigMap 带 label `grafana_dashboard: "1"`、annotation `grafana_folder: <文件夹>`
   （否则掉进顶层 General），data key 以 `.json` 结尾。
2. JSON 的 `datasource` 模板变量固定并隐藏（`hide:2`，值 `loki`/`prometheus`）；查询尽量用
   `cluster=~"$cluster"` 支持多集群过滤。
3. tag 带 `curated` + 信号 tag。
4. `git push` → ArgoCD 同步；若改动落在 `grafana.sidecar`/`grafana.ini`（folder/多集群/Home/uid），
   一并改 `values/kube-prometheus-stack.yaml` 并 push（`kube-prometheus-stack` App 同步）。

## SLI / SLO（Sloth + Cilium Envoy 一手指标）

服务可用性 SLO 基于**真实入口请求**（Cilium Gateway 的 Envoy L7 指标），非合成探测；
用 **Sloth** 生成多窗口燃尽率规则。2026-06-16 上线，2026-07-12 扩展至 oracle 网关。

- **一手指标 (homelab)**: `cilium-envoy` DaemonSet `:9964`（`cilium-config`
  `enable-metrics=true`/`external-envoy-proxy=true`），
  `manifests/monitoring/cilium-envoy-servicemonitor.yaml` 抓取（metricRelabelings 只留 RED）。
  关键指标 `envoy_cluster_upstream_rq_xx{envoy_cluster_name="<gw>/<ns>_<svc>_<port>",
  envoy_response_code_class="2|3|4|5"}`。无需改 Cilium 数据面。
- **一手指标 (oracle)**: 无 Prometheus Operator——otel-collector 的 `prometheus/cilium-envoy`
  receiver 直抓同款 `:9964`（`cloud/oracle/manifests/monitoring/otel-collector.yaml`，keep 正则
  与 homelab 一致），remote-write 到 homelab Prometheus。
  ⚠️ 改该 ConfigMap 后必须手动 `kubectl --context oracle-k3s rollout restart
  ds/otel-collector -n monitoring`（ConfigMap 名无 hash 后缀，不热加载）。
- **⚠️ 跨集群指标名差异（2026-07-12 踩坑）**: otel prometheus receiver→remote-write 链路按
  OpenMetrics 给 counter 补 `_total`——同一指标 homelab 叫 `envoy_cluster_upstream_rq_xx`，
  oracle 侧叫 `…_xx_total`。查 oracle 指标的 PromQL 都要注意。**勿改 exporter 的
  `add_metric_suffixes`**（会把 oracle 全部既有指标改名，破坏现有面板/告警）。
- **Sloth**: ArgoCD `sloth` App（chart + `values/sloth.yaml`，评估留在 homelab）。
  `sloth.extraLabels.release=kube-prometheus-stack` 让生成的 PrometheusRule 被 operator 选中；
  `defaultSloPeriod=30d`；关 commonPlugins 的 git-sync sidecar。
- **SLO 定义**: `manifests/monitoring/slos.yaml` —— 两个 `PrometheusServiceLevel`：
  `homelab-gateway-availability`（grafana/vault/bifrost）+ `oracle-gateway-availability`
  （zitadel/calibre-web/argocd——后两个 2026-08-02/03 随迁移移入），共 6 服务 99%/30d
  （error=5xx, total=全部）。**新增/改**: 在对应 `spec.slos[]` 追加
  （`errorQuery`/`totalQuery` 用 `envoy_cluster_name=~".*/<ns>_<svc>_.*"`；oracle 侧记得
  `_total` 指标名 + `cluster="oracle-k3s"`）→ `git push`。
- **⚠️ errorQuery 末尾必须 `OR on() vector(0)`（2026-07-12 踩坑）**: envoy 按响应码类
  **惰性创建**序列——服务从未返回过 5xx（或 envoy 重启计数器重置）时 errorQuery 为空集，
  SLI 除法整体消失 → **SLO 序列与燃尽率告警静默失效**。现有 6 条已统一加固，新增必须沿用
  （见 slos.yaml 头部注释）。
- **告警**: 每个 SLO 生成多窗口燃尽率告警，`pageAlert→critical` / `ticketAlert→warning`，
  经现有 Alertmanager 路由到 Telegram。
- **看板**: Grafana `SLO` 文件夹 → "SLO / Service Availability"
  （`manifests/monitoring/dashboards/slo-dashboard.yaml`）。
- **⚠️ 零流量盲区**: 真实流量 SLI 在服务无人访问时为 NaN（vector(0) 加固后序列恒存在，
  不再整体消失）。这是一手指标的固有特性；燃尽率告警只在真出现 5xx 时触发。闲置服务要稳定
  可用性信号，叠一层合成探测（Uptime Kuma）兜底。
