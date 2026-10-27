# K8s 资源管理与 QoS 策略

> Last updated: 2026-10-28
> Status: 生效事实（本文只定原则，不存具体数值）

本文定 CPU/Memory requests & limits 与 Pod Priority 的原则和判据。**具体数值不在本文维护**，
以 `k8s/helm/values/`（homelab）、`cloud/oracle/values/`（oracle）与集群实际为准
（`kubectl --context <ctx> -n <ns> get deploy -o yaml`）。

> 延伸阅读：[K8s CPU 配置：QoS、Throttling 与驱逐策略](https://meirong.dev/posts/k8s-cpu-qos-resource-management/)

## 背景与目标

- **homelab**（控制面 `k8s-node` + worker `k8s-worker-106`，规格与宿主分配链见
  [homelab-host-power-thermal.md](homelab-host-power-thermal.md)）：有状态/数据面服务
- **oracle-k3s**（A1.Flex 2 OCPU / 12GB，单节点）：公网无状态 + 告警面
- 日常用户约 1–2 人，偶发突发至 ~10 人

目标：requests 反映常态负载，不过度预留；limits 给足 burst 空间；补全缺失的 CPU limit，
避免单 pod 独占 CPU。

## QoS 类别

所有工作负载使用 **Burstable**（设了 requests 或 limits 但不完全相等），兼顾稳态预留和空闲时 burst。
跨类驱逐次序：BestEffort（均未设置）最先，Guaranteed（requests == limits）最后。

### ⚠️ QoS 只排到类，类内看 Pod Priority

两集群绝大多数 pod 都是 Burstable，所以节点内存压力下起决定作用的是 kubelet 的类内判据：
先按「用量是否超 request」分桶，桶内再按 Pod Priority，最后看超出幅度。

- ☠️ **声明了 `priorityClassName` 就必须同时声明 resources。**BestEffort 的 request 恒为 0，
  永远落在「超」那一桶，排在守规矩的 `bulk`(-10) 应用前面被驱逐，那行 priority 只是装饰
  （external-dns 曾标着 `high` 却是 BestEffort）。
- 带 `system-node-critical` / `system-cluster-critical`（约 2e9）的 pod 即使 BestEffort 也排在最后。
  oracle 的 cilium-agent/envoy/operator 属此类，刻意不补 requests（补了只把该节点内存 requests
  账面推高约 10 个点，收益接近零）。`priority: 0` 且无 class 的 BestEffort 才是真裸奔。

### PriorityClass 四档

定义在 `k8s/helm/manifests/namespace-guardrails/priorityclasses.yaml`（homelab）与
`cloud/oracle/manifests/base/priorityclasses.yaml`（oracle）。☠️ 两份必须逐字段同步：
values 引用了只在一侧定义的 class，那一侧滚动时旧 pod 已删、新 pod 被 API server 拒绝，
静默下线，ArgoCD 照样显示 Synced（[records/2026-08-06-priorityclass-missing-pods-rejected.md](../records/2026-08-06-priorityclass-missing-pods-rejected.md)）。

| 档 | 值 | 例 |
|---|---|---|
| `critical` | 1000 | Vault、ArgoCD 全家、zitadel-pg |
| `high` | 900 | external-dns、cloudflared、otel-collector（两集群）、Prometheus、Alertmanager |
| （默认） | 0 | 其余，含 ZITADEL 应用本身、Grafana、ESO、kube-state-metrics、node-exporter |
| `bulk` | -10 | 可牺牲的个人应用（calibre-web/bentopdf/browserless/open-notebook/jobs-sg-web 等）、非关键观测/扫描组件（opencost、trivy-operator、tetragon、kyverno） |

当前归属在仓库根跑 `grep -rn 'priorityClassName' k8s/helm cloud/oracle` 为准。分档判据是「掉了会怎样」：

- **high 给告警链路**：Prometheus 是指标源、Alertmanager 是投递，掉了是所有告警一起哑
  （dead-man's switch 也走同一条路）；Grafana 只是 UI，留默认档。Prometheus 内存吃紧时优先砍
  series 而不是抬 limit，见 [decisions/prometheus-series-reduction.md](../decisions/prometheus-series-reduction.md)。
- **bulk 给 fail-open 组件**：opencost 掉线只丢一段成本采样，trivy-operator 掉线只是报告变旧。
  kyverno 唯一管工作负载准入的 `kyverno-resource-validating-webhook-cfg` 是 `failurePolicy: Ignore`
  （其余 `Fail` 的只管 Kyverno 自己的 CR），掉线不挡 pod 创建；tetragon 同理。被驱逐正是
  fail-open，符合「所有安全组件 fail-open + 控 CPU」的硬约束。
- 没标 class 的组件落在 0，反而比 `bulk` 的个人应用高。

⚠️ trivy-operator 有三个层级不同的键，漏一个就留一个 priority 0 的缺口：

| 键 | 作用对象 | 渲染到 |
|---|---|---|
| 顶层 `priorityClassName` | operator 本体（常驻，内存小头） | Deployment |
| `trivyOperator.scanJobPodPriorityClassName` | 扫描 Job pod，真正的瞬时内存消费者 | **ConfigMap**（`scanJob.podPriorityClassName`） |
| `trivy.priorityClassName` | trivy-server（StatefulSet） | StatefulSet |

- 第二个不在任何 Deployment 里，`get deploy -o yaml` 看不到；验证看实际 Job pod 的 `.spec.priority`。
- ☠️ `trivy:` 段在两份 values 里已存在（装着 severity / ignoreUnfixed / accepted-risk 列表），
  必须插进现有段。另起一个 `trivy:` 块 = YAML 重复键，后者静默覆盖前者，那批 CVE 抑制无声消失。

⚠️ **三处设不了，不是漏配**。chart 没有这个键时写进去会被 Helm 静默忽略，看着像配了，比不配更危险；
加之前先用 `helm template` 确认真的渲染出来。

- **ZITADEL 应用**（chart 9.34.1）、**sloth**（chart 0.16.0）：代偿是把可牺牲的应用压到 `bulk`，
  它们留在 0 已在其上。
- **timeslot**：仓库外的手工 Helm release（无 ArgoCD tracking-id），只能靠 ns 的 LimitRange
  给默认 request。

⚠️ 改 class 的两条约束：

- 改名或删除 PriorityClass 要三步走：加新 class → 改全部引用 → 删旧 class。
- 下面几类对象的 `priorityClassName` 改了不会跟着 GitOps 滚：

| 对象 | 原因 | 做法 |
|---|---|---|
| `vault-0`、`vault-agent-injector` | manual-helm，且 STS 是 `OnDelete` | `cd k8s/helm && just deploy-vault`，再 `kubectl --context k3s-homelab -n vault delete pod vault-0`；lifecycle hook 从 `vault-auto-unseal` 自动解封 |
| ArgoCD 全家 | manual-helm（刻意不自管） | `cd k8s/helm && just deploy-argocd` |
| `zitadel-pg-1` | CNPG 不把 `priorityClassName` 变更当作滚动理由 | `kubectl --context oracle-k3s -n zitadel delete pod zitadel-pg-1`，operator 按当前 spec 重建 |

⚠️ 2026-08-06 改名（`meirong-*` → 无前缀）之前的 ReplicaSet 修订仍引用已删除的旧名，
`kubectl rollout undo` 回到那些修订建不出 pod。往前修，别回滚。

### 节点级预留：调度器看不见的那一块

`allocatable` = `capacity` − `kube-reserved` − `system-reserved` − `eviction-hard`。
**不声明 reserved，调度器就认为整机内存都能分给 pod**，而 k3s-server 进程自己就要 ~2GiB。
现值在各集群 playbook 的 `kubelet-arg`：oracle `cloud/oracle/ansible/playbooks/setup-k3s.yaml`，
homelab `k8s/ansible/playbooks/setup-k3s.yaml`（控制面）与 `setup-k3s-worker.yaml`（worker）。

⚠️ OCI Ubuntu 镜像的 microk8s 装机残留 `/etc/sysctl.d/20-microk8s-hugepages.conf` 把 2GiB 锁成
hugetlb 并从 allocatable 扣掉，集群里却没有 pod 申请 hugepages（oracle 的 `setup-k3s.yaml` 会清掉它）。
残留的判据：`kubectl --context oracle-k3s get node oracle-k3s -o jsonpath='{.status.capacity.hugepages-2Mi}'`
非 0，且节点上 `grep HugePages_Free /proc/meminfo` 等于 Total。

## CPU limit 档位

| 类型 | CPU limit | 代表服务 |
|------|-----------|---------|
| 入口流量（cloudflared，单副本）| `200m` | cloudflared |
| 用户 Web 服务 | `500m–1000m` | calibre-web |
| 数据库 | `500m` | postgres |
| 可观测性 | `300m–500m` | Loki, Tempo, Prometheus, Grafana |
| 后台/轻量服务 | `100m–200m` | alertmanager, kube-state-metrics, oauth2-proxy |
| 极轻量 sidecar（常驻低速）| `10–100m` | （当前无） |
| 突发型单线程 sidecar | `1000m` | permission-fixer（见下） |
| Batch/CronJob | `200m–300m` | restic-backup, kube-bench |
| 元数据处理 | `1000m` | calibre-metadata（每日凌晨） |

⚠️ 突发型单线程容器的 limit 别低于 1 core，这不是给多了。每轮只跑零点几 CPU-秒然后长睡的负载，
limit <1 core 时配额小于单线程跑满一个 100ms 周期所需，结构上必被节流；占空比越低
`throttled/periods` 越难看（permission-fixer 在 500m 时仍有 66.7%），节流告警反复复燃。
requests 留在 `1m`，不占调度额度。

## 改 resources 前先判是谁管

GitOps 托管的改 values 后 `git push` 即可；manual-helm（Vault、Cilium、ESO、ArgoCD 本体）
提交 ≠ 部署，要手动 `just deploy-X`。分工见 [argocd-app-patterns.md](argocd-app-patterns.md)。

判据别看 `helm list`（ArgoCD 接管前装过的 release 会一直留在那里），看对象上的 tracking-id，非空即 ArgoCD 管：

```bash
kubectl --context <ctx> -n <ns> get deploy <name> \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'
```

## 验证 QoS

```bash
# 单个 pod 的 QoS（--context 换 oracle-k3s 查另一集群）
kubectl --context k3s-homelab -n <namespace> get pod <pod-name> -o jsonpath='{.status.qosClass}'

# 全部 pod
kubectl --context k3s-homelab get pods -A -o custom-columns=\
'NAMESPACE:.metadata.namespace,NAME:.metadata.name,QOS:.status.qosClass'
```

下文的 PromQL 都在中枢 Prometheus（homelab，含两集群序列）上跑：
`kubectl --context k3s-homelab -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090`，
然后开 `http://localhost:19090`。

## 检测 CPU Throttling

```bash
# CFS 配额统计（节点上）
cat /sys/fs/cgroup/cpu,cpuacct/kubepods/burstable/<cgroup-id>/cpu.stat
# PromQL
rate(container_cpu_cfs_throttled_seconds_total[5m])
  / rate(container_cpu_cfs_periods_total[5m])
```

- ⚠️ 查询返回空结果与「节流为 0」外观一致。先 `count by (cluster) (container_cpu_cfs_periods_total)`
  确认该集群有这个 series：oracle 的 `container_*` 要靠 otel-collector 的 keep 正则放行
  （`cloud/oracle/manifests/monitoring/otel-collector-config.yaml`）。
- ⚠️ cAdvisor 只为设了 CPU quota 的容器吐 cfs 指标。给容器去掉 CPU limit，它就从节流告警的视野里
  整个消失，那是无数据，不是节流为 0。

## 检测 OOMKill（容器顶爆自身 limit）

大节点上更常咬人的不是节点驱逐，而是单个容器撞到自己的 memory limit 被内核杀掉（`exitCode 137`）。
它不影响邻居，所以容易长期没人发现。

- ⚠️ `KubePodCrashLooping` 抓不到：容器 OOM 后干净重启，从不进 `CrashLoopBackOff`。
- ⚠️ worker `k8s-worker-106` 是全场最小节点（allocatable 约 3Gi，eviction 阈值收得很紧，见
  `setup-k3s-worker.yaml`），排在它上面的负载节点驱逐和 OOMKill 两种都要看。

```bash
# 谁最近被 OOM 杀过（--context 换 oracle-k3s 查另一集群）
kubectl --context k3s-homelab get pods -A -o json | jq -r '
  .items[] | .metadata as $m | .status.containerStatuses[]? |
  select(.lastState.terminated.reason=="OOMKilled") |
  "\($m.namespace)/\($m.name) [\(.name)] restarts=\(.restartCount) at \(.lastState.terminated.finishedAt)"'

# 逼近 limit 的容器（>80% 就该抬 limit 或查泄漏），双集群一起出（PromQL）
# ⚠️ 两侧都必须先 max by(...) 聚合掉 id/image/job 等多余标签，否则报
#    "many-to-one matching must be explicit"；分组键要带 cluster，否则两集群同名 ns/pod 会串味
max by (cluster,namespace,pod,container) (max_over_time(container_memory_working_set_bytes{container!=""}[2d]))
  / on (cluster,namespace,pod,container)
max by (cluster,namespace,pod,container) (kube_pod_container_resource_limits{resource="memory"})
```

- `max_over_time` 是关键：尖峰型负载看瞬时值会整个漏掉（ArgoCD controller 被 OOM 杀时瞬时读数
  只有 0.67G，2d 窗口才照出 94%）。
- 这条排查查询**故意**用 `working_set`（含页缓存），线上 `ContainerMemoryNearLimit` 用 `rss`：
  排查时两个数对照，才能判断是不是下面的形状 ④。
- 窗口用 2d 不用 7d：窗口越长，一次瞬态尖峰把告警钉住越久，且 `for` 起不到去抖作用
  （分子已是窗口 max，顶上去就是平台期）。

OOM 相关告警的表达式、阈值与标定过程以 `k8s/helm/manifests/monitoring/alerts/prometheus-rules.yaml`
为准。表达式里看不出来的约束：

- `ContainerMemoryNearLimit` 的分母是工作负载**当前**的 limit（按 `(cluster,namespace,container)` 取 max，
  `group_left`）。CronJob 旧 pod 的 spec 不可变，按 pod join 会让每次抬 limit 都连报 2~3 晚假阳性。
  代价是调小 limit 时短暂漏报，认这个取舍，别改回按 pod join。
- 80% 阈值是回放标定的，落在已知真阳性（multica frontend，约 85%）与全舰队常态最高（约 71%）之间。
  别升回 85%（真阳性变掷硬币），也别降到 75%（常态最高的那个会常亮）。
- `rss` 口径的取舍：它只是 `memory.stat.anon`，不含 kernel/tmpfs/mlocked，且会漏掉形状 ③
  （那一类看 GC 指标，不归这条告警管）。
- ☠️ **改依赖某个指标的规则前，先确认两集群都有该 series。**`container_*` 全来自 kubelet 内嵌
  cAdvisor（没有独立部署）：homelab 经 kube-prometheus-stack 全量入库，oracle 靠 otel-collector
  的 keep 正则放行。没放行的指标查询返回空，规则在那一侧恒不触发，外观与「没超阈值」一致。
  顺序是硬的：先放行、确认 series 到货，再改规则，再照 `ContainerMemoryRssAbsent` 加 `absent()` 守卫。

### 判读：先分清是哪种形状再动手

先看 7d 曲线：

| 形状 | 怎么认 | 结论 |
|---|---|---|
| ① 稳定爬升 | 曲线持续上行 | 泄漏，查代码 |
| ② 基线震荡 + 偶发尖峰 | 在基线上下震荡，偶有尖峰 | 头寸不够，抬 limit |
| ③ 峰值跟着 limit 走 | Go 程序，chart 把 `GOMEMLIMIT` 接成 `limits.memory` | 调 GOGC，抬 limit 无效 |
| ④ 峰值由页缓存撑起 | `rss` 平稳、`cache` 撑起峰值 | 不构成 OOM 风险；抬/降 limit 有没有用无定论 |

控制面组件（ArgoCD 等）的峰值随被管对象规模（App 数、CRD 大小）增长，不随流量，扩容后要回头复查这类 limit。

#### ☠️ ③ `GOMEMLIMIT` 硬接 limit：抬 limit 是无效动作

Go 程序拿到 `GOMEMLIMIT` 时 GC 目标由它决定。chart 把它接成 `limits.memory` 本身，每次抬 limit
都等量抬高 GC 目标，峰值/limit 比值几乎不动，告警几天内回来。grafana 连抬两次（98% → 94% → 91%）
都没解决，现场读数与 GOGC 推导见 `k8s/helm/values/kube-prometheus-stack.yaml` 的 grafana `resources` 注释。

- 先取 `go_gc_gogc_percent` / `go_gc_gomemlimit_bytes` / `go_memstats_next_gc_bytes`。**GC 频率是判据**：`rate(go_gc_cycles_total_gc_cycles_total[5m])` 很低（十几秒一次）且 CPU 有余量，
  说明绑定约束是 GOGC 的「活跃堆翻倍」，调低 GOGC 即可。真被 GOMEMLIMIT 钳住时 GC 连轴转，
  频率高一两个数量级，那才是头寸不够、该抬 limit。
- GOGC 可推导：活跃堆 ≈ `next_gc`/2，非堆 ≈ working_set 峰值 − `heap_alloc` 峰值；
  `GOGC = ((目标峰值 − 非堆)/活跃堆 − 1) × 100`。正常口径是 `GOMEMLIMIT` ≈ limit 的 80%（otel-collector）。
- ⚠️ 别用 `env: GOMEMLIMIT` 覆盖 chart 那份：多数 chart 的 `.Values.env` 渲染在内置 env 之后，
  同名即 env 列表重复键，开了 `ServerSideApply` 的 App 直接 ComparisonError 卡在 `sync=Unknown`
  （见 [records/2026-08-19-opencost-bingen-replay-crashloop.md](../records/2026-08-19-opencost-bingen-replay-crashloop.md)）。
- ⚠️ 验收别看「告警灭了」：规则分子是窗口内的 `max_over_time`，旧 pod 的历史峰值要滚出窗口才消失
  （与 [observability-alerting-slo.md](observability-alerting-slo.md) 里换 pod 后旧 `instance`
  陈旧值仍在回看窗内是同一类陷阱）。看**新 pod** 的 `next_gc` 与 working_set 峰值。
- ⚠️ 两集群的 `cilium-agent` 也把 `GOMEMLIMIT` 接成 limit（chart 默认）。它报了别按抬 limit 处理；
  改它要重跑 `deploy-cilium`（`cd k8s/helm && just deploy-cilium` / `cd cloud/oracle && just deploy-cilium`）
  再 `cd k8s/helm && just connect-clustermesh <homelab-ts>:32379 <oracle-ts>:32379`。

#### ☠️ ④ 页缓存撑起峰值：告警在测一个不构成 OOM 风险的量

`container_memory_working_set_bytes = memory.current − inactive_file`，**它包含页缓存**。
mmap/顺序读文件重的负载（TSDB、对象存储缓存、大 SQLite），working_set 可能大半是 file cache，
而干净的 file page 永远先于 OOM 被回收。usage 顶死 `memory.max` 也只是内核回收缓存了事
（Prometheus 顶死 3Gi 仍 `exitCode 0 / Completed`）。完整现场与对照实验见
[records/2026-08-30-memory-alert-page-cache-false-alarm.md](../records/2026-08-30-memory-alert-page-cache-false-alarm.md)。

- **怎么分辨**：取 `container_memory_rss` 与 `container_memory_cache`，rss 平稳而 cache 撑起峰值即本形状。
- ☠️ **读数主要由节点页缓存冷热决定，不是由容器内存需求决定。**cgroup v2 只对自己从磁盘 fault
  进来的页计费，新容器读已常驻的页是搭便车、不计费。同容器、同数据、同 limit，只是重启时机不同，
  峰值能差 5 倍。拿 `max_over_time` 抓这种读数，抓到的是节点缓存状态。
- ☠️ **working_set 塌下去 ≠ 内存被回收。**刚读进来的文件页先挂 active LRU，约两分钟无人引用就降到
  `inactive_file`，被 working_set 扣掉，而 `usage` 几乎不动。别拿 working_set 回落推断压力解除。
- ⚠️ 别照搬形状 ③ 的处置，本形状没有那种绑定关系。真想压只能降 limit，而页缓存本就计入节点
  `MemAvailable`，收益是假的。
- ☠️ 容器重启后 5 分钟内，`max by (...)` 读到的是上一个容器的值：容器 ID 变了 = 新序列，旧序列仍在
  staleness 回看窗内。规则把 `id` 聚合掉了所以看不出来，排查时务必按 `id` 拆开。
- ⚠️ cache/working_set 比值高的容器很多，同类假阳性随时可能在别处复现，但不等于现在有一堆误报。
- ⚠️ cgroup v2 上别用 `container_memory_failcnt` 取证：那是 v1 的 `memory.failcnt`，v2 无对应文件，
  cAdvisor 恒报 0，与「真的没触到上限」外观一致。v2 判据：容器活着时读 `memory.events` 的
  `max`/`oom`/`oom_kill`；事后用 `container_memory_max_usage_bytes`（两集群都采集）。`memory.events`
  随容器一起消失，`max_usage` 是唯一能回看「有没有顶死 limit」的证据。

## requests/limits 该填多少？

- 依据是 **KRR 每周一推到 Telegram 的推荐**（CPU 取 p95，内存取窗口内 max + 15%），双集群均已部署，
  见 [cost-and-rightsizing.md](cost-and-rightsizing.md#krr)。KRR 只读不改（`krr-enforcer` 刻意未部署，
  会与 ArgoCD selfHeal 死循环），看完报告手工改 git 里的 `resources`。
- 分诊 SOP（含系统性误读与改完怎么实测确认）→ [runbooks/krr-report-triage.md](../runbooks/krr-report-triage.md)。
- 标 `(No data)` / `(Not enough data)` 的是当前没有运行 Pod 的 Job/CronJob，忽略即可。
- 内存推荐取 7 天窗口内的 max（对齐 Prometheus retention），跨周尖峰（如每周备份 CronJob）
  可能落在窗口外，这类工作负载要自行留余量。
- ⚠️ 突发型容器别按空载采样定 limits：按请求分配大块内存的路径（图片/PDF 转码、模板编译）空载时看不见。
  低于上游 chart 默认要有负载下的实测 →
  [records/2026-08-18-multica-frontend-idle-rightsizing-oom.md](../records/2026-08-18-multica-frontend-idle-rightsizing-oom.md)。

### ⚠️ 内存余量别看 `kubectl top node`

- 它报的是 workingSet（含可回收页缓存），会虚高到 90%+ 让人误判要驱逐（实测 top 报 92% 时
  available 仍有三分之一以上）。判余量看节点上 `free -m` 的 available，或 Prometheus 按容器
  `rssBytes` 聚合。
- requests 只反映申报、不反映实占（两者可差数百 Mi）。requests 占 allocatable 的比例只说明排程账面
  （满了新 pod 会 Pending），与真实内存压力无关。

## 相关文档

- [cost-and-rightsizing.md](cost-and-rightsizing.md)：OpenCost 成本归因 + KRR 右尺寸
- [runbooks/oracle-k3s-shape-downsize.md](../runbooks/oracle-k3s-shape-downsize.md)：改 A1 shape 的 SOP（本文原则的一次实战应用）
- [plans/archive/2026-07-06-resource-optimization.md](../plans/archive/2026-07-06-resource-optimization.md)：2026-07-06 那轮调整的推导（历史快照，非当前值）
- [observability-multicluster.md](observability-multicluster.md)：多集群监控架构
- [Kubernetes QoS 官方文档](https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/)
