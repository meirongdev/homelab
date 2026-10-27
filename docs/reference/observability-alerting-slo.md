# Observability — 告警、看板组织与 SLO

> Last updated: 2026-10-28
> Status: 生效事实
>
> 遥测的消费侧：告警路由与覆盖盲区、Grafana 看板组织约定、SLI/SLO 体系。
> 采集侧（日志/指标/追踪怎么跨集群汇聚）见
> [observability-multicluster.md](observability-multicluster.md)。

## 告警（Alertmanager → Telegram）

### 通知链路

- 规则全部在 homelab Prometheus 评估，一条规则覆盖双集群（oracle 指标经 remote-write 进来，
  带 `cluster=oracle-k3s`）。
- `severity: critical|warning` 由 `telegram` AlertmanagerConfig
  （`k8s/helm/manifests/monitoring/alerts/alertmanager-config.yaml`）经原生 `telegramConfigs`
  直投群 MatthewDaily 的「🚨 Homelab 告警」话题（`chatID: -1003981213530` + `messageThreadID: 2`），
  critical 每 30m 重复、warning 每 4h；`info` 不进 Telegram。bot token：Vault
  `secret/homelab/telegram` → ESO（`alertmanager-telegram-secret.yaml`）。
  取舍见 [decisions/alerting-telegram-migration.md](../decisions/alerting-telegram-migration.md)。
- `Watchdog` 由 `watchdog` AlertmanagerConfig 每 30s webhook 到 oracle Uptime Kuma 的 push monitor
  （死人开关）；静态路由树的 `null` 只接没人认领的告警。☠️ 接收方与发送方一起挂（oracle 重启、
  uptime-kuma 下线）时它静默失明，`DeadMansSwitchReceiverDown` 只让失明可见。细节只在
  [dead-mans-switch.md](dead-mans-switch.md) 维护，事故见
  [records/2026-08-14-…](../records/2026-08-14-oracle-reboot-loop-and-blind-dead-mans-switch.md)。
- oracle 的 Falco 告警走 Falcosidekick 原生 Telegram output（同 bot 同话题，与 Alertmanager
  互不依赖），见 [security.md §8.5](security.md)。

☠️ 判投递健康只看指标，不看 AM 日志：默认 `info` 级别下首次投递成功只打 DEBUG（重试成功才 INFO，
失败打 WARN），日志连日空白只说明没有投递失败，别据此重启 AM。

```bash
# 查 homelab Prometheus（Tailscale NodePort）：telegram 的 failed 恒为 0，total 随告警递增
P=http://100.94.186.7:31090/api/v1/query
curl -s "$P" --data-urlencode 'query=sum by (integration) (alertmanager_notifications_total)'
curl -s "$P" --data-urlencode 'query=sum by (integration) (alertmanager_notifications_failed_total)'
```

### 写告警规则的不变量

- ⚠️ `PrometheusRule`/`ServiceMonitor` 必须带 label `release: kube-prometheus-stack`，否则
  operator 的 `ruleSelector`/`serviceMonitorSelector` 静默忽略。
- ☠️ 只对实际部署镜像吐出的指标写规则：先 `curl` 运行中 pod 的 `/metrics`，别照上游源码（工作区
  常跑在已发布 tag 前面）。对不存在的序列写的规则永不触发。
- ☠️ 存活规则写成 `up == 0 or absent(up{...})`：采集端（OTel Collector）挂掉时序列整体消失，
  单写 `up == 0` 永不触发。「序列消失」要单列 `absent` 类规则。
- ☠️ 别写死 `cluster="homelab"`：采集面变了以后规则照常评估、health=ok，只是看不到另半个舰队，
  按 `sum by (cluster)` 聚合（确需锁集群的在注释写明理由，如 `KubeletDown`）。`absent()` 只能断言一个具名
  标签集，覆盖多集群用参照序列
  `count by (cluster) (<参照> > 0) unless count by (cluster) (<目标>)`（范例：
  `external-dns-alerts.yaml`、`argocd-alerts.yaml` 的 `*MetricsAbsent`）。
- ☠️ 标签集不同的两个指标做比较或 `and`，要写 `ignoring(...)`/`on(...)`，否则默认 vector matching
  永远返回空（范例：`readlist-alerts.yaml` 的 `ignoring(grade)`、`ignoring(dim)`）。
- ⚠️ `time() - <时间戳>` 要带 `<时间戳> > 0` 前置：首刷未成功时是 0，每次重启都假阳性
  （`CFAnalyticsDataStale`）。只在失败时才产生的序列（如 `status="error"`）查不到 = 正常，存活性
  不能靠它兜。
- ⚠️ CronJob 新鲜度看 `kube_cronjob_status_last_successful_time`，不看 `KubeJobFailed`（对 suspend、
  对象被删、节点长期下线都不响）。从未成功过时 KSM 不发这个序列，所以只守「成功过、然后停了」。
- ⚠️ exporter 的 readiness 只探进程，不探数据新鲜度：否则抓取一坏 pod 就被踢出 Endpoints，连
  `scrape_success=0` 都抓不到，告警自己关掉自己。
- ⚠️ Prometheus 换 pod IP 后 `instance` 变、`pod` 不变，新旧副本共存于回看窗：对裸指标做 min/avg
  前先 `max by (...)` 折叠 `instance`。
- ⚠️ `kube_node_status_allocatable` 限定 `job="kube-state-metrics"`：opencost 吐同名指标，不过滤
  分母翻倍。核对：`count by (job) (kube_node_status_allocatable{resource="cpu"})`。
- ⚠️ 两集群都上报的指标做 join 报 `found duplicate series for the match group` 时，照抄 chart 的
  `topk by (cluster, …)` + `max without (instance, job, type)` 去重形状。
- ☠️ annotation 正文不能出现 `<xxx>`：`parseMode: HTML` 下 Telegram 回 400，这条告警永远发不出去。
  占位符写 `$name`，反引号不提供保护（见 `alertmanager-config.yaml` 注释）。

上线前在 live Prometheus 上双向验（`absent()` 对存在的序列返回空、对不存在的返回 1；选择器确实
选得中），再过 promtool。Prometheus 容器是 distroless，从 stdin 喂：

```bash
# 仓库根执行；promtool 只认裸 rules 文件，先剥出 PrometheusRule 的 .spec
yq '.spec' k8s/helm/manifests/monitoring/alerts/<file>.yaml \
  | kubectl --context k3s-homelab -n monitoring exec -i svc/kube-prometheus-stack-prometheus \
      -c prometheus -- promtool check rules /dev/stdin
```

### 自建规则

清单在 `k8s/helm/manifests/monitoring/alerts/`（ArgoCD `monitoring-dashboards` App）。这里只记
各组守什么与刻意的取舍；未列出的文件与组，设计说明在各自的注释里。

- `eso-alerts.yaml`：`externalsecret`/`(cluster)secretstore` `Ready=False` 即报，堵「Vault 封印或
  token 过期 → Secret 停刷而 app 还在用旧值」。前置的一次性 metrics 开关：homelab
  `cd k8s/helm && just deploy-eso`（`serviceMonitor.enabled`）、oracle
  `cd cloud/oracle && just install-eso`（`--set metrics.service.enabled=true`）。
- `clustermesh-alerts.yaml`：抓 clustermesh-apiserver 的 kvstoremesh 容器 `:9964`（homelab
  `clustermesh-servicemonitor.yaml`，oracle otel `prometheus/clustermesh`）。刻意不抓 cilium-agent：
  agent 只连本集群缓存，跨集群那一跳是 kvstoremesh，开 agent 指标还要对 Cilium 做 helm upgrade。
  三种互不蕴含的故障分开写：`readiness_status == 0`（配了连不上）、`remote_clusters == 0`
  （peer 配置消失，前者此时无序列可判）、`absent(...)`（看不见了）。→ [tailscale-network.md](tailscale-network.md)
  · 起因 [records/2026-08-05-…](../records/2026-08-05-clustermesh-up-but-stuck.md)
- `readlist-alerts.yaml`（9 条，指标经 oracle otel `prometheus/readlist`）：夜间管道（UTC 01:05
  snapshot → 01:20 ingest → 01:40 score）全挂时 web 仍回 200，HTTP 探测原理上看不见。三条新鲜度互不
  蕴含：score >36h、snapshot >36h（score 会对旧快照照常打分）、ingest >3d（证据约 180 天才刷新）。
  C/F 维全库为 0 的两条用 `and ignoring(dim) works_total > 0` 兜空库，D/P/A 三维刻意不告警。处置见
  [runbooks/readlist-bootstrap.md](../runbooks/readlist-bootstrap.md)。
- `falco-alerts.yaml`（oracle，5 条）：Falco 安静不等于健康。oracle otel 抓 `falco`（:8765，要同时开
  `metrics.enabled` 与 `falco.webserver.prometheus_metrics_enabled`）与 `falcosidekick`（:2801）。
  存活分两条（`FalcoDown` critical；`FalcosidekickDown` warning，只影响通知）、Telegram 投递失败、
  `scap_n_drops_total`（内核丢事件，见 [records/2026-09-12-…](../records/2026-09-12-falco-syscall-drops-apt-upgrade.md)）、
  `outputs_queue_num_drops_total`（看见了没送出）。⚠️ 前缀别混：引擎 `falcosecurity_falco_*` /
  `falcosecurity_scap_*`，转发器 `falcosecurity_falcosidekick_*`。
- `cf-analytics-alerts.yaml`（6 条）：exporter 每 6h 拉 Cloudflare Analytics API（→
  [public-traffic-analysis.md](public-traffic-analysis.md)），失效全静默。`CFAnalyticsScrapeFailing`、
  `CFAnalyticsDataStale`（>24h 无成功）、`CFAnalyticsMetricsAbsent`、`CFAnalyticsRowsTruncated` /
  `CFAnalyticsPageRowsTruncated`（撞 API 10000 行上限，IP 数 / 页面长尾被低估）、
  `BlogStatsRollupStale`（rollup 超 3 天没成功；Cloudflare 按 path 只留 8 天，再过 5 天就永久丢数）。
- `argocd-alerts.yaml`（4 条）：oracle otel `prometheus/argocd` 按 pod 发现抓 application-controller
  `:8082`，只 keep `argocd_app_info`、`argocd_cluster_connection_status`；刻意不开 chart 的
  `controller.metrics.enabled`（ArgoCD 本体是 manual-helm）。OutOfSync 只看 autosync 的 App
  （`Unknown` = ComparisonError）；`ArgoCDClusterUnreachable` 是 Tailscale 通而 API/凭据坏，整条链路断
  归 `OracleTelemetryAbsent`。⚠️ 序列上的 `cluster` 恒为 `oracle-k3s`（控制面），App 部署在哪看 `dest_server`。
- `prometheus-rules.yaml` 的 `prometheus-self` 组：`PrometheusHeadSeriesHigh`（>180k 持续 2h）守
  [prometheus-series-reduction](../decisions/prometheus-series-reduction.md) 砍掉的 series 被静默改回
  （升 chart 后默认 `metricRelabelings` 变了没跟，或改 values 漏抄 chart 默认值）。不按 cluster 拆：
  量的是本机 head 总内存压力，含 oracle remote-write 的部分。阈值校准与排查命令在规则注释与
  annotation（用零成本的 `/api/v1/status/tsdb`）。📌 只抓量的回退；ADR 复核条件的另两条（重开
  `kubeApiserverBurnrate`/`Slos`/`Availability`、新看板消费原始 bucket）仍靠人核。

#### 容量（`prometheus-rules.yaml` 的 `capacity` 组，覆盖两集群）

- `ClusterCpuRequestsSaturated` / `ClusterMemoryRequestsSaturated`：requests 占总 allocatable
  >90% 持续 30m，即新 pod 开始排不进去。替代 chart 的 `KubeCPUOvercommit`/`KubeMemoryOvercommit`
  （已在 `defaultRules.disabled` 关掉）：上游量 N-1 冗余，在 1 大 + 1 小的不对称双节点上恒真，
  永久黄灯只会训练人忽略告警。`for: 30m` 滤的是 rollout 期间新旧 pod requests 并存的尖峰。
  📌 它只说明排程账面快满，判真实内存压力见 [k8s-qos-resource-management.md](k8s-qos-resource-management.md)。
  📌 出路不对称：homelab 满了可按 [cluster-placement](../decisions/cluster-placement-for-new-services.md)
  挪轻量无状态去 oracle；oracle 已单向缩容，满了只能砍 requests 或退役。
- `ResourceQuotaNearlyExhausted`：任一 ns 配额 ≥90% 持续 30m。替代 chart 的 `KubeQuotaAlmostFull`/
  `KubeQuotaFullyUsed`（同样已关，二者都是 `info`，进不了 Telegram）；唯一 warning 的
  `KubeQuotaExceeded` 判 `>1`，而准入控制让比值封顶 1.0，结构上永不触发。取 `>= 0.9` 不设上界，
  避免恰好满时没告警。☠️ 配额满了准入层静默拒绝建 pod：Job 建得出来、`active=0`、只刷
  `FailedCreate`、不被标 failed，`KubeJobFailed`/`KubeJobNotCompleted` 都不响，这条是唯一前置信号。
  `count/pods` 与 `pods` 的区别、手工一次性 Job 的纪律只写在 `k8s/helm/manifests/jobs-sg/limits.yaml`。

### ⚠️ 告警覆盖 ≠ 抓取覆盖

node-exporter mixin 规则（`NodeMemoryHighUtilization` / `NodeFilesystemAlmostOutOfSpace` / CPU 组）
全部硬编码 `job="node-exporter"`，只覆盖两个 K3s 节点；裸机与外部主机（`node-exporter-metal-nodes`
= pve + 106、`node-exporter-dgx-spark`、`node-exporter-macbook`）一条都不匹配。它们由
`prometheus-rules.yaml` 的 `metal-nodes-resources` 组按主机定阈值，刻意不统一放宽成
`job=~"node-exporter.*"`（几台机的正常态差太多）：

- pve 用绝对下限（`MemAvailable` <300Mi）：ZFS ARC ≈ 0，低 `MemAvailable` 是 K3s VM 的分配，百分比
  阈值在 pve 上是永久误报。
- 106 的 ARC 可回收，`MemAvailable` 严重低估，表达式要 `+ node_zfs_arc_size - node_zfs_arc_c_min`。
- ⚠️ 写新规则前确认指标存在：DGX 没有 `node_filesystem_*`（容器化 node_exporter 未挂宿主根，磁盘
  只能靠 SMART），macbook 没有 `node_memory_MemAvailable_bytes`（darwin 无此指标）。在 homelab
  Prometheus 查 `count by (job) (node_filesystem_size_bytes)`。

## Dashboards 组织

核心配置在 `k8s/helm/values/kube-prometheus-stack.yaml` 的 `grafana.sidecar.dashboards`：

- 文件夹：`folderAnnotation: grafana_folder` + `provider.foldersFromFilesStructure: true`，ConfigMap
  用注解 `grafana_folder: <名称>` 指定。布局：`Platform`（多集群总览，Home）/ `Logs` / `Hardware`
  （裸金属主机 + SMART）/ `Security` / `SLO` / `Kubernetes Built-in`（chart 自带 mixin 面板归档于此）。
  ⚠️ 归档不等于禁用：`nodeExporter.operatingSystem.{aix,darwin}.enabled: false` 只 gate 规则不 gate
  dashboard，chart 没有单面板开关，整关 `defaultDashboardsEnabled` 会连带丢 20+ 张有用面板，故维持归档。
- 多集群选择器：`multicluster.global.enabled: true` 让内置 mixin 面板出现 `cluster` 下拉（关掉时
  多集群指标被求和叠加）。选 `oracle-k3s` 为空是已知的，见
  [observability-multicluster.md](observability-multicluster.md)。
- Home：`grafana.ini` 的 `dashboards.default_home_dashboard_path:
  /tmp/dashboards/Platform/multicluster-overview.json`（sidecar 按 folder 注解写子目录）。
- 数据源稳定 uid：`prometheus` / `loki` / `tempo`。⚠️ 给已存在的数据源赋 uid 必须走
  `grafana.deleteDatasources` + `additionalDataSources` 删了重建：PVC 里已有按 name 生成随机 uid 的
  记录，直接加 `uid:` 会报 `data source not found` 并让 Pod CrashLoop。
- trace↔log↔metric：Tempo 数据源配 `tracesToLogsV2`→`loki` / `tracesToMetrics`→`prometheus` /
  `serviceMap`→`prometheus`（后向引用，Tempo 必须排在 Loki/Prometheus 之后）。⚠️ 不要在 Loki 侧配指向
  Tempo 的 `datasourceUid`（前向引用 → not found 崩溃）；logs→trace 跳转用 Grafana Correlations。
- 门户下钻用 tag 不用 UID（内置面板 UID 会变）。

新增或修改 dashboard：ConfigMap 放 `k8s/helm/manifests/monitoring/dashboards/`（`monitoring-dashboards`
App 是 recurse 目录源，无需登记），`git push` 后 ArgoCD 同步。

1. label `grafana_dashboard: "1"`、annotation `grafana_folder: <文件夹>`（否则掉进顶层 General），
   data key 以 `.json` 结尾；tag 带 `curated` + 信号 tag（`logs`/`metrics`）。
2. JSON 的 `datasource` 模板变量固定并隐藏（`hide:2`，值 `loki`/`prometheus`）；查询尽量用
   `cluster=~"$cluster"`。
3. 改动涉及 `grafana.sidecar`/`grafana.ini`（folder/多集群/Home/uid）时一并改
   `values/kube-prometheus-stack.yaml`（`kube-prometheus-stack` App 同步）。

## SLI / SLO（Sloth + Cilium Envoy 一手指标）

服务可用性 SLO 基于 Cilium Gateway 的 Envoy L7 指标，由 Sloth 生成多窗口燃尽率规则，评估在 homelab。
本节只讲机制；目标值、服务选择判据、错误预算算术见
[decisions/slo-availability-targets.md](../decisions/slo-availability-targets.md)。

⚠️ SLI 分母以合成探测为主：`cloud/oracle/manifests/uptime-kuma/provisioner.yaml` 那组
`https://*.meirong.dev/` 探针（`interval=60`，只收 3xx、不跟随跳转）穿过 gateway 计入分母，部分
服务的真实流量接近 0。这些 SLO 测的是「入口通不通」，不等于用户体验；逐服务占比只在 ADR 维护。

- 一手指标：homelab 是 `cilium-envoy` DaemonSet `:9964`（`cilium-config` 的 `enable-metrics=true` /
  `external-envoy-proxy=true`），由 `k8s/helm/manifests/monitoring/cilium-envoy-servicemonitor.yaml`
  抓取，只留 RED；oracle 没有 Prometheus Operator，由 otel-collector 的 `prometheus/cilium-envoy`
  receiver 直抓同款 `:9964`（`cloud/oracle/manifests/monitoring/otel-collector-config.yaml`，keep 正则
  与 homelab 一致）后 remote-write，改完 push 即可，DaemonSet 自动滚动。关键指标
  `envoy_cluster_upstream_rq_xx{envoy_cluster_name="<gw>/<ns>_<svc>_<port>",envoy_response_code_class="2|3|4|5"}`。
- ⚠️ oracle 侧指标名多一个 `_total`（otel → remote-write 按 OpenMetrics 给 counter 补后缀）：homelab
  `envoy_cluster_upstream_rq_xx`，oracle `…_xx_total`。别改 exporter 的 `add_metric_suffixes`，那会把
  oracle 全部既有指标改名。
- Sloth：ArgoCD `sloth` App（`k8s/helm/values/sloth.yaml`）。`sloth.extraLabels.release=kube-prometheus-stack`
  让生成的 PrometheusRule 被 operator 选中；`defaultSloPeriod=30d`；关掉 commonPlugins 的 git-sync sidecar。
- SLO 定义：`k8s/helm/manifests/monitoring/slos.yaml`，`homelab-gateway-availability` 与
  `oracle-gateway-availability` 两个 `PrometheusServiceLevel`，每个服务 99%/30d（error = 5xx，total =
  全部），服务清单以该文件为准。新增：在对应 `spec.slos[]` 追加（选择器
  `envoy_cluster_name=~".*/<ns>_<svc>_.*"`；oracle 侧用 `_total` 指标名 + `cluster="oracle-k3s"`）→
  `git push`。
- ☠️ 分子分母都要兜底，两个坑相互独立，新增必须照抄现有写法：
  - errorQuery 末尾 `OR on() vector(0)`：envoy 按响应码类惰性建序列，从未出过 5xx（或计数器重置）
    时 errorQuery 为空集，SLI 整体消失，燃尽率告警一起静默失效。
  - totalQuery 末尾 `(... > 0) OR on() vector(1)`：零请求窗口的 `rate()` 是值为 0 的样本，0/0 = NaN
    写进 TSDB；30d 周期规则用 `sum_over_time`，一个 NaN 毒死整条 30d 序列，而 ≤3d 窗口不受影响，
    所以只有预算面板坏、告警照常。→ [records/2026-08-12-slo-nan-poisoning.md](../records/2026-08-12-slo-nan-poisoning.md)
- 告警：`pageAlert` → critical、`ticketAlert` → warning，走上面的 Telegram 路由。
- 哨兵 `SLOSLIProducingNaN`（`alerts/slo-meta-alerts.yaml`）：
  `slo:sli_error:ratio_rate5m unless (slo:sli_error:ratio_rate5m > -1)`（NaN 参与任何比较都为 false）。
  盯 rate5m：它是周期窗口 NaN 的唯一上游，比 30d 面板早约 30 天暴露。⚠️ 别写成
  `count(X) - count(X > -1) > 0`：全 NaN 时右侧是空集，结果整个消失，永不触发。
- 看板：Grafana `SLO` 文件夹 → "SLO / Service Availability"
  （`k8s/helm/manifests/monitoring/dashboards/slo-dashboard.yaml`）。N/A 一律代表 SLI 异常，不是无流量。
- ⚠️ 30d 周期大于 Prometheus retention（`values/kube-prometheus-stack.yaml` 的 `retention` /
  `retentionSize`），「30d 错误预算剩余」实为 retention 内的平均。刻意不改：告警全用 ≤3d 窗口；sloth
  内置窗口目录只有 30d/28d，换周期要自带 catalog 并重标定全部燃尽率系数；抬 retention 到 30d 会
  OOM（评估在 values 注释）。真实窗口的量法见 ADR。
- ⚠️ 零流量服务的 SLO 统计意义弱：兜底后闲置窗口按「0 错误 = 健康」计入，但样本太小时一个 5xx
  就吃掉一大块预算（算术见 ADR）。
