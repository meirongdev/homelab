# Observability — 告警、看板组织与 SLO

> Last updated: 2026-08-24
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
  Uptime Kuma 的 push monitor，即**死人开关**；静态路由树的 `null` receiver
  只接真正没人认领的告警。
  → 目的、6 跳链路、**覆盖矩阵与三处失明盲区**、演练程序全在
  [dead-mans-switch.md](dead-mans-switch.md)（唯一真相源，此处不留副本）。
  ⚠️ 别按"告警链路死了就会在状态页变红"这一句去理解它——**接收方和发送方一起挂时
  它静默失明**，2026-08-14 实测 580s 缺口零翻转。
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
  **刻意不抓 cilium-agent 的同类指标**：那要开 `prometheus.enabled` 对 Cilium 做 helm
  upgrade，而 agent 只连本集群缓存，真正断掉的那一跳恰恰是 kvstoremesh
  （早期还担心升级会抹掉 oracle 未固化的 peer 配置——2026-08-05 已固化进
  `cilium-values.yaml`，见 [tailscale-network.md](tailscale-network.md)）。
  三种**互不蕴含**的故障各一条规则：`readiness_status == 0`（配了连不上）·
  `remote_clusters == 0`（**peer 配置整个消失**——此时前者无序列可判，故必须单列）·
  `absent(...)`（看不见了，即 2026-08-05 那个盲区本身）。

- **readlist 数据新鲜度告警**（`manifests/monitoring/alerts/readlist-alerts.yaml`，2026-08-05 新增，
  2026-08-06 随 v0.2.0 补到 7 条，2026-08-09 再补 2 条判别力规则，共 9 条）:
  readlist 是**夜间管道**服务（snapshot 01:05 → ingest 01:20 → score 01:40，UTC）。三个 CronJob
  全挂之后 web pod 仍用最后一次发布的 run 一直返回 200 —— 探针绿、Uptime Kuma 绿、首页绿，
  榜单在悄悄变旧。**这类失效原理上只有指标能看见**，HTTP 探测看不到。
  指标经 oracle otel `prometheus/readlist` 抓 `readlist.personal-services.svc:8080`
  （300s；该 Service 是普通 ClusterIP，不踩 trivy 那个 headless 80→8080 的坑）→ remote-write。
  三条新鲜度各自独立（**互不蕴含**，这是重点）：`last_score_unix` >36h ·
  `last_snapshot_unix` >36h（语料陈旧但打分照常成功——score 会给一个月前的快照继续打分并
  让 score 那条常绿，**前者证明覆盖不到后者**）· `last_ingest_unix` >3d（证据停止刷新；
  窗口宽是因为证据本身 ~180 天刷新周期）。另四条：`works_total == 0`（空库自愈发布 0 本书的
  run）· 全部 works 为 D 级持续 3d（ingest 跑通了却什么也没产出）· `orphan_rows > 10`
  （book id 漂移，基线 3）· `absent(...)`（盲区本身）。
  2026-08-09 补两条**判别力**规则（起因：C 维上线四天恒为 0、F 维被 snapshot 覆写
  回归清零，两个旗舰榜结构性为空却全站绿灯）：`dim_measured{dim="C"} == 0` 达 3d ·
  `dim_measured{dim="F"} == 0` 达 24h（都用 `and ignoring(dim) works_total > 0` 兜掉
  空库场景；D/P/A 三维仍刻意不告警——前两者没有生产数据源，A 的阈值只能拍脑袋）。
  ⚠️ 两条**踩过的坑**，改这个文件前先读：① 跨指标比较必须 `ignoring(grade)` —— 
  `grade_counts` 带 `grade` 标签而 `works_total` 不带，默认 vector matching 匹配不上、
  **永远返回空**，和"一切正常"长得一模一样；② **只对实际部署镜像 `curl` 过的指标写规则**，
  别照上游源码写——工作区常跑在已发布 tag 前面（v0.1.0 源码有 14 个指标族，镜像只emit 5 个）。

- **Falco 自身健康告警**（`manifests/monitoring/alerts/falco-alerts.yaml`，2026-08-10 新增，5 条）:
  在此之前 Falco **既没被抓指标也没有任何规则** —— 引擎死、驱动没起来、规则解析失败、
  falcosidekick 推不动 Telegram，症状都只是「Telegram 安静」。而这原本被一个巧合掩盖着：
  Falco 每天在刷约 500 条 systemd 误报，「今天有 Falco 消息」实际充当了心跳。
  同日修掉那条误报（见 `values/falco.yaml`）等于拆掉假心跳，所以这 5 条必须同批落地。
  指标经 oracle otel 两个 job 抓：`falco`（falco-metrics:8765，需 **同时**开
  `metrics.enabled` 与 `falco.webserver.prometheus_metrics_enabled`，只开前者端点没数据）
  与 `falcosidekick`（:2801，默认就有）→ remote-write，`cluster=oracle-k3s`。
  两条存活（`FalcoDown` critical / `FalcosidekickDown` warning，**分开报**是因为处置不同：
  后者不影响检测与 Loki 取证，只是没人会被叫醒）+ 一条投递失败（Telegram `status="error"`）
  + 两条静默失真：`scap_n_drops_total`（内核缓冲丢事件 = 那些 syscall 永不被评估）与
  `falco_outputs_queue_num_drops_total`（看见了但没送出去）。
  ⚠️ 三条**踩过/绕过的坑**：① 存活规则一律写成 `up == 0 or absent(up{...})` —— 采集端
  （OTel Collector）挂掉时序列**整体消失**，`up == 0` 匹配的是空向量、永不触发；
  ② 两个前缀不可混用：引擎是 `falcosecurity_falco_*`/`falcosecurity_scap_*`，转发器是
  `falcosecurity_falcosidekick_*`；③ `status="error"` 序列**首次失败后才存在**，
  「查不到数据」= 正常，存活性不靠这个计数器兜底。
  上线前逐条在 live Prometheus 上**双向**验过（`absent()` 对存在的序列返回空、对不存在的
  返回 1；标签选择器确实选得中 —— 选不中的规则和"一切正常"长得一模一样），
  并用 `promtool check rules` 过了语法（Prometheus 容器是 distroless，无 `sh`，
  得用 `kubectl exec -i … promtool check rules /dev/stdin` 喂进去）。

- **cf-analytics 告警**（`manifests/monitoring/alerts/cf-analytics-alerts.yaml`，2026-08-15 新增，4 条）:
  cf-analytics-exporter 每 6h 调一次 Cloudflare Analytics API，把「按域名的访问 IP 数/请求数」
  桥成指标，并按来源分类（真人 / 爬虫 / 自建监控）→ [public-traffic-analysis.md](public-traffic-analysis.md)。
  它的失效**全是静默的**：pod Running、探针绿、面板照常出图，只是数字停在几天前。
  `CFAnalyticsScrapeFailing`（抓取报错）· `CFAnalyticsDataStale`（>24h 没有成功过一轮）·
  `CFAnalyticsMetricsAbsent`（序列整体消失，即会屏蔽掉前两条的那个盲区）·
  `CFAnalyticsRowsTruncated`（撞到 API 10000 行上限 → 独立 IP 数被低估）。
  ⚠️ 两处**特意为之**：① 探针**只探进程不探数据新鲜度** —— 拿抓取结果当 readiness 会把
  pod 踢出 Endpoints，Prometheus 连 `scrape_success=0` 都抓不到，抓取故障退化成"没数据"，
  告警自己把自己关掉；② `CFAnalyticsDataStale` 必须带 `> 0` 前置条件 ——
  首刷未成功时时间戳是 0，`time() - 0` 是天文数字，每次重启后都会假阳性。

- **Prometheus 基数看门狗**（`manifests/monitoring/alerts/prometheus-rules.yaml` 的
  `prometheus-self` 组，2026-08-20 新增，1 条）:
  `PrometheusHeadSeriesHigh` —— active series 持续 2h >180k 即报。守的不是 Prometheus
  死活（那有 chart 自带的 mixin：`PrometheusNotIngestingSamples` / `TSDBReloadsFailing` 等），
  而是 [prometheus-series-reduction.md](../decisions/prometheus-series-reduction.md) 砍掉的
  10.4 万条 series **被静默改回来**：升 chart 时默认 `metricRelabelings` 变了没跟，或改
  values 时漏抄 chart 默认值（YAML 的 list 是整体覆盖）—— 两者都不报错、不影响任何服务，
  只是内存悄悄涨回去，直到撞 3Gi limit 才以 OOM 的形式暴露。
  阈值取自 48h 实测的两侧留白：砍后稳态 109k–114k（pod 换代时新旧序列并存于 head，
  瞬时峰 120.7k），砍前稳态 218k–222k、峰 243k。
  ⚠️ 三处**特意为之**：① 表达式**不按 cluster 拆** —— 它量的是本机 head 的总内存压力，
  oracle 经 remote-write 进来的 21k 本就该算在内；序列上的 `cluster=homelab` 只表示
  "谁报的这个指标"，不是成员关系。② 必须 `max by (cluster)` 折叠 `instance` —— Prometheus
  换 pod IP 后 `instance` 变而 `pod` 名不变，新旧副本会共存于回看窗（实测 3 天内 3 个
  instance），对裸指标做 min/avg 会读到已消失副本的陈旧值。③ 排查时**不要**用
  `topk(20, count by (__name__)({__name__=~".+"}))` —— 那是全 head 扫描；用零成本的
  `/api/v1/status/tsdb` 内置统计，命令写在告警 annotation 里。
  📌 **覆盖范围有限**：它只抓**量**的回退。ADR 复核触发条件里另外两条 —— 重新启用
  `kubeApiserverBurnrate`/`Slos`/`Availability`、新增消费原始 bucket 的看板 —— 表现为
  规则哑掉或面板空白而非 series 变多，这条告警看不见，仍得靠人核。

- **homelab 调度容量饱和**（`prometheus-rules.yaml` 的 `capacity` 组，2026-08-13 新增，2 条）:
  `HomelabCpuRequestsSaturated` / `HomelabMemoryRequestsSaturated` —— requests 占**总**
  allocatable >90% 持续 30m。它们替代 chart 的 `KubeCPUOvercommit` / `KubeMemoryOvercommit`
  （已在 values 的 `defaultRules.disabled` 关掉）。
  **关掉的理由是语义在本拓扑下恒真**：上游那两条量的是「挂掉最大节点后剩余容量能否装下
  全部 requests」（N-1 冗余），而 homelab 是 **1 大 + 1 小的不对称双节点** —— 控制面的
  requests 永远塞不进 2c/3G 的 worker，且控制面挂 = 控制面没了，N-1 在此拓扑下没有意义，
  该告警也不可能靠加资源"修好"。永久黄灯只会训练人忽略告警页（2026-08-13 worker 入编
  当天开始 firing）。替代版改测真实饱和：新 pod 会不会开始排不进去。
  ⚠️ **分母必须限定 `job="kube-state-metrics"`** —— opencost 也吐同名
  `kube_node_status_allocatable`，不过滤会让分母翻倍、比值减半。2026-08-24 复核这个坑
  **仍然活着**：`count by (job)(kube_node_status_allocatable{resource="cpu",cluster="homelab"})`
  返回 `job=kube-state-metrics` 2 条 + `job=opencost` 2 条。
  ☠️ **只覆盖 homelab，而 oracle 是更紧的那个** —— 两条都写死 `cluster="homelab"`。
  清单注释里说理由是"oracle 的序列不进中枢 Prometheus"，**2026-08-24 复核发现那已不成立**：
  `count by (cluster)` 显示 `kube_node_status_allocatable` 与
  `namespace_{cpu,memory}:kube_pod_container_resource_requests:sum` 两边都有序列。
  按 cluster 分组实测：**CPU homelab 26.6% / oracle 60.1%**、
  **内存 homelab 61.5% / oracle 73.6%** —— 逼近 90% 阈值的是 oracle，而它没有告警。
  且 oracle 是**单向缩容过**（4 OCPU/24GB → 2/12，A1 无容量涨不回去）的那个集群。
  → 已记为开放项，见 [../ROADMAP.md](../ROADMAP.md)。
  （同组的 `ResourceQuotaNearlyExhausted` 不受影响：它本来就覆盖两集群。）
  📌 **它只说明"排程账面"快满了，不代表真实内存压力** —— 判真实压力永远看节点
  `free -m` 的 available / `rssBytes`（requests 只反映申报，两者可差数百 Mi）。
  口径见 [k8s-qos-resource-management.md](k8s-qos-resource-management.md)（唯一真相源）。
  实测趋势：CPU 20%→**26.6%**、内存 52%→**61.5%**（2026-08-13 写入 → 08-24 复核）。
  内存这条离 90% 阈值还有余量但在稳步上涨，值得留意。

- **ResourceQuota 逼近上限**（`prometheus-rules.yaml` 的 `capacity` 组，2026-08-24 新增，1 条）:
  `ResourceQuotaNearlyExhausted` —— 任一集群任一 ns 的配额用量 ≥90% 持续 30m 即报。
  它替代 chart 的 `KubeQuotaAlmostFull` + `KubeQuotaFullyUsed`（已在 values 的
  `defaultRules.disabled` 关掉）。**关掉的理由是严重级，不是表达式** —— chart 把配额
  分三档，而 Alertmanager 只放行 `critical|warning`：

  | chart 规则 | 判据 | severity | 结果 |
  |---|---|---|---|
  | `KubeQuotaAlmostFull` | `>0.9 <1` | **info** | 进不了 Telegram |
  | `KubeQuotaFullyUsed` | `==1` | **info** | 进不了 Telegram |
  | `KubeQuotaExceeded` | `>1` | warning | 准入控制保证 used 最多**等于** hard → **结构上永不触发** |

  ☠️ 为什么这个盲区特别坏：配额满了之后准入层**静默**拒绝建 pod —— Job 对象建得出来、
  `active=0`、永远没有 pod、只无限刷 `FailedCreate`，而它**不会被标记成 failed**。于是
  `KubeJobFailed`（判 `kube_job_failed>0`）不响，`KubeJobNotCompleted`（要求
  `active>0`）也不响。2026-08-24 jobs-sg 手工起 5 个一次性 Job 顶到 15/16 时，
  唯一响的是 `InfoInhibitor` —— 正是被抑制掉的那条。
  自建版取 **`>= 0.9` 不设上界**：chart 分成 `>0.9<1` 与 `==1` 两条，恰好满的那一刻
  前者停响、后者是 info，会出现「最糟时反而没告警」的空洞。
  ⚠️ 两个实现细节：① 表达式照抄 chart 的 `topk by(cluster,…)` +
  `max without(instance,job,type)` 去重形状 —— 改成朴素的
  `on(namespace,resourcequota,resource)` 会直接报 `found duplicate series for the
  match group`（两集群都上报 `kube_resourcequota`，且 `personal-services` 两边都有）。
  ② 与 `capacity` 组其它规则不同，这条**不限定 `cluster="homelab"`**：oracle 的
  `kube_resourcequota` 确实进了中枢 Prometheus（实测 7 个 series 覆盖两集群），
  不像 CPU/内存那些被 otel 白名单挡在外。
  写入时实测：命中 0（最高是 jobs-sg 的 `count/pods` 62.5%），7 天历史峰值 75%。

  📌 配套的口径修正：`count/pods` 是**对象计数**配额、**不排除终态**，`pods` 才排除。
  jobs-sg 曾是全舰队唯一用 `count/pods` 的 ns，10 个槽里 9 个是 `Succeeded`；
  2026-08-24 已改为 `pods: 12`，与 media / personal-services 对齐。实测语义对照与
  手工一次性 Job 的纪律写在 `k8s/helm/manifests/jobs-sg/limits.yaml` 的注释里
  （唯一真相源，此处不留副本）。

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

服务可用性 SLO 基于 Cilium Gateway 的 Envoy L7 指标（入口一手请求）；
用 **Sloth** 生成多窗口燃尽率规则。2026-06-16 上线，2026-07-12 扩展至 oracle 网关。

> **目标值/服务清单的判据、错误预算算术** → [decisions/slo-availability-targets.md](../decisions/slo-availability-targets.md)。
> 本节只讲**机制**（怎么跑），**为什么这么定**在那份 ADR。
> ⚠️ 该 ADR 的实测推翻了本节原先那句"基于真实入口请求、**非合成探测**"：
> Uptime Kuma 的 60s 外部探针穿过 gateway、计入 SLI 分母，**vault/argocd 的真实流量
> 实测 ≈0**（vault 5 天只有 1 个 `2xx`）——5 条 SLO 里 3 条量到的几乎只有探针本身。

- **一手指标 (homelab)**: `cilium-envoy` DaemonSet `:9964`（`cilium-config`
  `enable-metrics=true`/`external-envoy-proxy=true`），
  `manifests/monitoring/cilium-envoy-servicemonitor.yaml` 抓取（metricRelabelings 只留 RED）。
  关键指标 `envoy_cluster_upstream_rq_xx{envoy_cluster_name="<gw>/<ns>_<svc>_<port>",
  envoy_response_code_class="2|3|4|5"}`。无需改 Cilium 数据面。
- **一手指标 (oracle)**: 无 Prometheus Operator——otel-collector 的 `prometheus/cilium-envoy`
  receiver 直抓同款 `:9964`（`cloud/oracle/manifests/monitoring/otel-collector-config.yaml`，
  keep 正则与 homelab 一致），remote-write 到 homelab Prometheus。
  ✅ 改完 push 即可，**不需要手动 rollout restart**：该配置走 `configMapGenerator`，
  名字带内容哈希，DaemonSet 自动滚动（2026-08-02 根治，细节与要守住的不变量见
  [observability-multicluster.md](observability-multicluster.md#otel-collector-配置改了不生效--已根治2026-08-02别再手动重启)）。
- **⚠️ 跨集群指标名差异（2026-07-12 踩坑）**: otel prometheus receiver→remote-write 链路按
  OpenMetrics 给 counter 补 `_total`——同一指标 homelab 叫 `envoy_cluster_upstream_rq_xx`，
  oracle 侧叫 `…_xx_total`。查 oracle 指标的 PromQL 都要注意。**勿改 exporter 的
  `add_metric_suffixes`**（会把 oracle 全部既有指标改名，破坏现有面板/告警）。
- **Sloth**: ArgoCD `sloth` App（chart + `values/sloth.yaml`，评估留在 homelab）。
  `sloth.extraLabels.release=kube-prometheus-stack` 让生成的 PrometheusRule 被 operator 选中；
  `defaultSloPeriod=30d`；关 commonPlugins 的 git-sync sidecar。
- **SLO 定义**: `manifests/monitoring/slos.yaml` —— 两个 `PrometheusServiceLevel`：
  `homelab-gateway-availability`（grafana/vault）+ `oracle-gateway-availability`
  （zitadel/calibre-web/argocd——后两个 2026-08-02/03 随迁移移入），共 5 服务 99%/30d
  （error=5xx, total=全部）。**新增/改**: 在对应 `spec.slos[]` 追加
  （`errorQuery`/`totalQuery` 用 `envoy_cluster_name=~".*/<ns>_<svc>_.*"`；oracle 侧记得
  `_total` 指标名 + `cluster="oracle-k3s"`）→ `git push`。
- **☠️ 分子分母都要兜底，两个坑独立且症状完全不同**（现有 5 条已统一加固，新增必须沿用；
  推导见 slos.yaml 头部注释）：
  - **errorQuery 末尾 `OR on() vector(0)`（2026-07-12 踩坑）**: envoy 按响应码类
    **惰性创建**序列——服务从未返回过 5xx（或 envoy 重启计数器重置）时 errorQuery 为
    **空集**，SLI 除法整体消失 → SLO 序列与燃尽率告警一起静默失效。
  - **totalQuery 末尾 `(... > 0) OR on() vector(1)`（2026-08-12 踩坑）**: 零请求窗口里
    `rate()` 不是空集，是**值为 0 的真实样本**；配上上一条的 `vector(0)` 就成了
    0/0 = **NaN**，并被当正常样本写进 TSDB。Sloth 的周期窗口(30d)规则是
    `sum_over_time(ratio_rate5m[30d]) / count_over_time(...)`，**sum_over_time 遇 NaN
    全程传染 → 一个 NaN 样本毒死整条 30d 序列**，连锁 `period_burn_rate` 与
    `period_error_budget_remaining` 全 NaN。短窗口(5m~3d)是直接 `rate()` 不受影响，
    所以**症状只在预算面板、告警照常工作**——5 个服务全 N/A 潜伏至少一整个可见窗口
    才被肉眼发现。→ [../records/2026-08-12-slo-nan-poisoning.md](../records/2026-08-12-slo-nan-poisoning.md)
- **告警**: 每个 SLO 生成多窗口燃尽率告警，`pageAlert→critical` / `ticketAlert→warning`，
  经现有 Alertmanager 路由到 Telegram。
- **SLO 自身的哨兵** `SLOSLIProducingNaN`（`alerts/slo-meta-alerts.yaml`，2026-08-12 新增）:
  `slo:sli_error:ratio_rate5m unless (slo:sli_error:ratio_rate5m > -1)` —— 取出所有
  **不是实数**的 SLI 样本（NaN 参与任何比较都返回 false，故 `> -1` 会把它滤掉）。
  盯 **rate5m 而非 30d 面板**：周期窗口的 NaN 只可能来自 rate5m，它是严格上游、覆盖
  100% 成因且早约 30 天暴露。⚠️ 不能写成 `count(X) - count(X > -1) > 0`——全 NaN 时
  右侧是空集、减法结果整个消失，告警永不触发。
- **看板**: Grafana `SLO` 文件夹 → "SLO / Service Availability"
  （`manifests/monitoring/dashboards/slo-dashboard.yaml`）。
  **N/A 一律代表 SLI 异常**（2026-08-12 起：空闲窗口稳定产出 0，不再是 NaN）；
  此前面板把 N/A 标注成"无流量、非故障"，正是那次故障潜伏的一半原因。
- **⚠️ 周期 30d 跑在 retention 7d 上**: `sum_over_time([30d])` 实际只读得到 ~7 天
  （`count_over_time` 返回约 2 万个样本 @30s ≈ 7.15d），"30d 错误预算剩余"实为 ~7 天平均。
  **刻意不改**：告警用的全是 ≤3d 窗口、在 7d 内完全有效，而 sloth 内置窗口目录只有
  30d/28d，换 7d 要自带 catalog 并重标定全部燃尽率系数；抬 retention 到 30d 则会 OOM
  （评估见 `values/kube-prometheus-stack.yaml`）。面板标题已注明真实窗口。
- **⚠️ 零流量服务的 SLO 统计意义很弱**: 兜底后闲置窗口按"0 错误 = 健康"计入，序列不再断，
  但样本量太小时目标本身失真——zitadel 曾 7 天仅 138 个请求（~0.8 req/h），99% 目标下
  一个 5xx 就是 0.7% 预算。**SLI 的样本量实际由 Uptime Kuma 的公网探测供给**：
  `provisioner.yaml` 那组 `https://*.meirong.dev/` 探针（`interval=60`，只收 3xx、
  不跟随跳转）就是各服务大部分 3xx 计数的来源。2026-08-12 排查 zitadel 无流量时发现
  **它根本不在监控清单里**（身份提供方竟是唯一没有存活探测的对外服务），已补上。
  ⚠️ 反过来要清醒：这些 SLO 的分母以合成探测为主，测的是"入口通不通"，
  不等价于真实用户体验。**逐服务的探针占比 / 真实流量实测值、以及由此得出的服务选择
  判据**见 [decisions/slo-availability-targets.md](../decisions/slo-availability-targets.md)
  （数字只在那里维护，这里不留副本）。
