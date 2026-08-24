# CronJob/Job 卫生基线：只强制会静默出事的两个字段，不强制 TTL

> 日期: 2026-08-24
> 状态: ✅ 已完成

## 上下文

2026-08-24 修 jobs-sg 技术栈假阳性时一口气起了 5 个手工一次性 Job，`count/pods`
一度到 **15/16**。再多一个就会静默卡住当晚的 ingest —— 而 `limits.yaml` 早已逐条
论证过这种坏法几乎没有告警覆盖。这次没出事只因为我盯着数字，不是因为有防线。

顺着这个近失事件把两个集群的 CronJob 全查了一遍，问的是两个问题：
**能不能统一？** 以及 **我打算统一的那些，真的是 K8s 最佳实践吗？**

第二个问题推翻了我最初提案里的一半。下面把**被否决的**也一并记下来，因为它们看着
都很像"应该做的事"。

## 上游文档实际说了什么

查的是 [K8s Job](https://kubernetes.io/docs/concepts/workloads/controllers/job/) /
[CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) /
[TTL-after-finished](https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/) /
[Job API reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/job-v1/)：

| 事实 | 出处原话要点 |
|---|---|
| `successfulJobsHistoryLimit` **默认 3**、`failedJobsHistoryLimit` **默认 1** | CronJob 页 |
| `ttlSecondsAfterFinished` 未设 = **不自动删除**；TTL 控制器**只支持 Job** | API ref + TTL 页 |
| TTL 页**整篇不提**与 CronJob history limit 的交互 | TTL 页 |
| `Forbid` 下上一个没跑完就到点 → **跳过**这一轮 | CronJob 页 |
| `Forbid` 下"上一轮还在跑"**记作 missed**；missed >100 次 → CronJob **不再启动 Job**，报 `too many missed start times`，**且不自愈** | CronJob 页 |
| 修法是设 `startingDeadlineSeconds`：控制器改为从该窗口往前数 missed，而不是从上次排期 | CronJob 页 |
| 唯一用 "should" 写的规范性要求：**Jobs 必须幂等** | CronJob 页 |
| `activeDeadlineSeconds`：相对 `startTime` 的连续活跃时长上限，到点系统尝试终止 | API ref |

⚠️ 上游**没有**任何"每个 CronJob 都该设 `activeDeadlineSeconds`/`ttlSecondsAfterFinished`"
的说法。下面采纳的两条是**本仓库的工程判断**，不是引用最佳实践 —— 判据是本拓扑下的
具体失败模式，不是权威。

## 决策

### 采纳 1：配额用 `pods` 而不是 `count/pods`

`count/pods` 是**对象计数**配额、**不排除终态**。事发当天 jobs-sg 的 10 个槽里
**9 个是 `Succeeded`**（纯历史、零节点开销），真在跑的只有 web 一个。

临时 ns 实测两种语义（这是决定性证据）：

| pod 状态 | `pods` | `count/pods` |
|---|---|---|
| `Succeeded` | **0** | 1 |
| `Pending`（卡住，即真正的危害） | **1** | 2 |

即 `pods` 精确对应护栏想防的东西，而护栏并未减弱。上游对 `pods` 的定义就是
"非终态 pod 数"。改后 jobs-sg 从 10/16 (62.5%) 变成 **1/12 (8.3%)**。

而 2026-08-13 那次 92 个泄漏由 `count/jobs.batch` 兜 —— `personal-services` 的注释
原文就是这么写的。jobs-sg 此前是**全舰队唯一**用 `count/pods` 的 ns，属于口径漂移
而非有意设计；08-17 把它从 10 抬到 16 是在给**错的维度**加余量。

### 采纳 2：`Forbid` 且会自动跑的 CronJob 要有两个 deadline

组合拳的失败链：卡住的 Job（无 `activeDeadlineSeconds` → 没人杀）→ `Forbid` 使后续
每次排期都记作 missed → 无 `startingDeadlineSeconds` → 累计 >100 次后**永久停摆且
不自愈**。

改前**12 个** CronJob 缺 `activeDeadlineSeconds`、**12 个**缺 `startingDeadlineSeconds`。
但真正暴露的只有 5 个 —— 剔除掉：
- 4 个 schedule 是 `0 5 31 2 *`（**2 月 31 日 = 永不触发**，本仓库用它表达"只手工跑"），
  永远累不出 missed；
- 2 个是 Cilium chart 生成的 `hubble-generate-certs`（4 个月一次，上游管）。

**`activeDeadlineSeconds` 在这里的定位是「断卡死的开关」，不是性能预算。** 它只需同时
满足"比任何合法运行长"和"比排期间隔短"，而日更任务的可行区间宽到 20h —— 所以余量
给到 6×–150× 是刻意的，不是随手。具体值与依据写在各自清单的注释里（R6）。

`startingDeadlineSeconds` **不能全舰队统一取一个数**：readlist 那三个是
`01:05 → 01:20 → 01:40` 的**有序流水线**，级间隔只有 15/20 分钟，照抄 backup 的
3600s 会允许迟到的 run 越过下一级，而乱序会产生真实可见的 artifact。所以它们取
600s，独立的日/周更取 3600s。上游自己的例子也是按语义定的（"备份晚 8 小时还有用，
再晚就不如等下一轮"）。

### 采纳 3：配额告警的问题是**严重级**，不是缺规则

chart 已经有表达式完全正确的规则，但两条有用的都是 `info`，而 Alertmanager 顶层
matcher 只放行 `critical|warning`：

| chart 规则 | 判据 | severity | 结果 |
|---|---|---|---|
| `KubeQuotaAlmostFull` | `>0.9 <1` | **info** | 进不了 Telegram |
| `KubeQuotaFullyUsed` | `==1` | **info** | 进不了 Telegram |
| `KubeQuotaExceeded` | `>1` | warning | 准入控制保证 used 最多**等于** hard → **结构上永不触发** |

☠️ 而这个盲区特别坏：配额满了准入层**静默**拒绝建 pod —— Job 对象建得出来、
`active=0`、永远没有 pod、只刷 `FailedCreate`，且**不会被标记成 failed**。于是
`KubeJobFailed`（判 `kube_job_failed>0`）不响、`KubeJobNotCompleted`（要求
`active>0`）也不响。事发当天唯一响的是 `InfoInhibitor` —— 正是被抑制掉的那条。

所以关掉那两条 info，自建一条 `>= 0.9` 的 warning 版（**不设上界**，避开"恰好满时
AlmostFull 停响、FullyUsed 又是 info"的覆盖空洞）。

### 采纳 4：Prometheus retention 7d → 14d

不是为了留数据本身，而是**定不出 deadline 的值**：7d 窗口下日更任务只有 9 个样本，
`readlist-ingest` 还是 4s 中位 / 279s 峰值的 21× 方差。

☠️ **只改 `retention` 是白改**：time/size 先到者生效，而改之前 **size 就已经是先到
的那个** —— `runtimeinfo` 实测数据跨度 **5.21 天**，不是 7 天。必须连 `retentionSize`
一起抬。

## 明确否决的

### 否决 1：不强制每个 CronJob 声明 `ttlSecondsAfterFinished`

我最初把它列成 CI 强制项（新增 `check-manifests.py` 的 H6）。**这不是最佳实践，是
教条。** CronJob 的 `successfulJobsHistoryLimit`(默认 3) / `failedJobsHistoryLimit`
(默认 1) **已经**负责清理 CronJob 生成的 Job；TTL 页整篇不提 CronJob 交互，因为它
是**独立 Job** 的机制。对 CronJob 管的 Job，TTL 是重复保险。

真正需要 TTL 的是**手工 `kubectl apply` 的一次性 Job** —— 而那类根本不进 git，CI
永远看不见（见否决 2）。

### 否决 2：不加 Kyverno `require-job-ttl`

两个变体都是坏主意，而且它**没对准真实发生的故障**：

- **Enforce 会炸基础设施升级。** 集群里 7 个独立 Job 有 6 个无 TTL，其中 **5 个是
  Helm hook**：Cilium 的 `hubble-generate-certs`（两集群）、Kyverno **自己**的
  `kyverno-migrate-resources`、k3s HelmChart 控制器的 `helm-install-zitadel`、
  ZITADEL 的 `zitadel-{init,setup}`。一 Enforce，升 CNI 和身份提供者会被拒。
- **Audit 等于没有。** 本仓库没有任何 Kyverno 违规告警，Audit 只产出没人读的
  PolicyReport。
- **它拦不住事发那次。** 那 5 个手工 Job **都带了 TTL**，问题是 24h 的 TTL 比
  "到下一轮 ingest"的 16h **长**。"必须有 TTL"一条都拦不住。

真正兜住这个失败模式的是采纳 3（90% 就响、且**不问原因**）。另外 Kyverno 只装在
homelab，而 21 个 CronJob 里 11 个在 oracle —— 半个舰队的强制手段本就不该当主力。

### 否决 3：不统一 history limit / `backoffLimit` 的数值

我一度把 `successfulJobsHistoryLimit` 的 3/2/1 混用列为"漂移"。**错了：3/1 就是上游
默认值。** backup 的 3/3（多留失败便于排查）、readlist 的 1/1（少留）都是按任务特性
刻意选的。周更 vs 日更、幂等 vs 不幂等本来就该不同，强制统一是把噪音当问题。

### 未解决：幂等性无法强制

上游唯一用 "should" 写的规范性要求 —— 而 CI 和 Kyverno 都强制不了，只能靠 review。
本仓库现有的自动作业里，`retech` / `reclassify` / `report --week` 都是幂等的
（后者 `DELETE FROM weekly_metric WHERE week_start=?` 再重算），
`calibre-metadata-correct` 会覆盖已有值所以刻意保持挂起 —— 那个判据（"只填空、
绝不覆盖、幂等"才允许自动跑）写在 `backfill-job.yaml` 的注释里，是本仓库对这条
上游要求的实际落地。

## 后果

- 配额口径全舰队一致（`pods` + `count/jobs.batch`），jobs-sg 不再是异类。
- 配额逼近上限从"静默"变成 30 分钟内进 Telegram，**且与原因无关** —— 不管是手工
  Job、CronJob 泄漏还是别的什么顶上去的。
- 那 5 个 CronJob 的卡死从"静默堵到 100 天后永久停摆"变成"当晚 `KubeJobFailed` 响"。
  ⚠️ **副作用是要的那个**：到点被杀的 Job 会标 Failed 并告警。若某个值定紧了，表现为
  收到告警而非静默失败 —— `readlist-ingest` 那个 21× 方差最可能撞线，1800s 只有
  6.5× 余量。
- retention 14d 后样本量翻倍，届时应回头复核这几个 deadline。
- **删掉了** `JobsSgCronJobFailed`：它判 `kube_job_status_failed`（失败 **pod** 计数，
  带 `reason` 标签），而全舰队的 `KubeJobFailed` 判 `kube_job_failed`（condition-based）。
  jobs-sg 是 `backoffLimit: 2` + TTL 7d，一个"首个 pod 失败、重试后成功"的 Job 会让
  前者持续为正 → 告警响 7 天而 Job 其实成功了。
  ⚠️ 这条是从 kube-state-metrics 字段语义推的，**没能实测复现**（当时全舰队
  `status_failed>0 且已成功` 匹配 0 个）。

## 相关

- 舰队当前状态与复查命令 → [../reference/cronjob-fleet.md](../reference/cronjob-fleet.md)
- 告警路由与覆盖盲区 → [../reference/observability-alerting-slo.md](../reference/observability-alerting-slo.md)
- 各 CronJob 的具体取值与理由 → 各自清单的注释（R6，此处不留副本）
