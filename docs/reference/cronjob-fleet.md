# CronJob 舰队现状：不变量、配额口径、Job 告警覆盖

> Last updated: 2026-08-24
> Status: 生效事实（本文只存**不变量与口径**，逐个 CronJob 的取值在各自清单里）

双集群一共 **22 个 CronJob**（homelab 9 / oracle-k3s 13）。本文回答"现在是什么样"；
**为什么这么定**在 [../decisions/cronjob-and-job-hygiene.md](../decisions/cronjob-and-job-hygiene.md)。

⚠️ **本文刻意不放 22 行的字段总表** —— 那种表的每一格都会漂，而清单本身才是真相源。
存的是复查命令（见文末），一条就能重新生成当前快照。

## 不变量（2026-08-24 核实）

| 不变量 | 状态 |
|---|---|
| `concurrencyPolicy: Forbid` | **22/22** —— 全舰队一致，无例外 |
| 会自动触发且 `Forbid` 的都有 `activeDeadlineSeconds` | 已齐 |
| 会自动触发且 `Forbid` 的都有 `startingDeadlineSeconds` | 已齐 |
| `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` 显式声明 | 22/22（值**刻意不统一**，见下） |

### 剩下 6 个"缺"两个 deadline 的，都有正当理由

两个字段各缺 6 个，但**没有一个是真缺口** —— 会自动触发的已全部补齐：

| 类别 | 数量 | 为什么不补 |
|---|---|---|
| `0 5 31 2 *`（**2 月 31 日 = 永不触发**） | 4（oracle 的 `calibre-metadata-{correct,covers,llm}` + `open-notebook-ingest`） | 本仓库用这个 schedule 表达"**只手工跑**"。永不自动触发 → 累不出 missed；且都是长跑的网络作业、retention 窗口内零样本，无依据定 deadline |
| `hubble-generate-certs`（两集群） | 2 | **Cilium chart 生成**、不在 git 里，4 个月一次。上游管 |

☠️ **`0 5 31 2 *` 这个 idiom 读文档的人容易误判成"配错了"** —— 它是故意的。想手工跑：
`kubectl create job --from=cronjob/<name> <name>-manual`。

### 为什么 history limit 的值刻意不统一

`3/1` **就是上游默认值**。backup 的 `3/3`（多留失败便于排查）、readlist 的 `1/1`
（少留）都是按任务特性选的。把这种差异当"漂移"去统一是把噪音当问题。

### `activeDeadlineSeconds` 的定位

**断卡死的开关，不是性能预算。** 它只需同时满足"比任何合法运行长"和"比排期间隔短"；
日更任务的可行区间宽到 20h，所以现有取值给到实测峰值的 6×–150× 是刻意的。
☠️ 它是 **JobSpec** 字段，必须写在 `spec.jobTemplate.spec` 下 —— 写到 CronJob 的
`spec` 下是未知字段、**会被静默丢弃**，而 YAML 解析与文件级校验都看不出来。
判据只有 `kubectl apply --dry-run=server -o json` 回读。

## 配额口径

**`pods` 是非终态 pod 数，`count/pods` 是对象计数、不排除终态。** 护栏要的是前者。

| ns | 集群 | `hard` |
|---|---|---|
| `jobs-sg` | homelab | `pods: 12` + `count/jobs.batch: 25` |
| `media` | homelab | `pods: 15` |
| `personal-services` | homelab | `pods: 30` + `count/jobs.batch: 15` |
| `personal-services` | oracle | `pods: 30` + `count/jobs.batch: 20` |

分工：`pods` 防"非终态 pod 挤爆节点 110-pod 上限"，`count/jobs.batch` 防
"CronJob 泄漏 Job 对象"（2026-08-13 那次 92 个就是它兜的）。

⚠️ **有 CronJob 但没有配额的 ns**：`backup`、`monitoring`、`kube-system`（两集群）、
`kube-bench`（homelab）。它们的 Job 对象数由 CronJob 自己的 history limit 封顶
（都显式声明了），所以不是敞口；但也意味着**手工在这些 ns 起 Job 没有配额兜底**。

## Job 告警覆盖矩阵

全舰队覆盖（chart 自带，`severity: warning` → 进 Telegram）：

| 规则 | 判据 | 抓什么 |
|---|---|---|
| `KubeJobFailed` | `kube_job_failed > 0`，15m | Job **级**失败（condition-based） |
| `KubeJobNotCompleted` | `active>0` 且已跑 **>12h** | 卡死 —— 这是无 `activeDeadlineSeconds` 时唯一的网 |

自建（`prometheus-rules.yaml` 的 `capacity` 组）：

| 规则 | 判据 | 为什么需要 |
|---|---|---|
| `ResourceQuotaNearlyExhausted` | 配额 ≥90%，30m | chart 的 `KubeQuotaAlmostFull`/`KubeQuotaFullyUsed` 都是 `info`（进不了 Telegram），唯一 warning 的 `KubeQuotaExceeded` 判 `>1` 而准入控制让比值封顶 1.0 → **结构上永不触发**。详见 [observability-alerting-slo.md](observability-alerting-slo.md) |

☠️ **配额满了是这条链上唯一的静默失败**：准入层拒绝建 pod → Job 对象建得出来、
`active=0`、永远没有 pod、只刷 `FailedCreate`，且**不被标记成 failed** → 上面两条
chart 规则**都不响**（后者要求 `active>0`）。所以那条自建规则不是锦上添花。

### 两个指标别混用

| 指标 | 含义 |
|---|---|
| `kube_job_failed` | condition gauge，带 `condition=true\|false\|unknown` → **Job 级**失败 |
| `kube_job_status_failed` | 失败 **pod** 计数，带 `reason` |

用后者写告警的坑：`backoffLimit>0` 时，"首个 pod 失败、重试后成功"的 Job 会让它持续
为正，直到 Job 对象被回收 —— 于是告警响满整个 TTL 而 Job 其实是成功的。曾有一条
`JobsSgCronJobFailed` 犯这个错，已删（被 `KubeJobFailed` 覆盖）。

## 幂等性：上游唯一的硬要求，且强制不了

CronJob 页唯一用 "should" 写的规范性要求是 **Jobs 必须幂等**。CI 和 Kyverno 都查不了，
只能靠 review。本仓库的实际落地判据（写在 `calibre-metadata/backfill-job.yaml` 注释里）：
**只填空、绝不覆盖、幂等** 才允许自动跑 —— 所以 `calibre-metadata-correct`（会覆盖
已有值）刻意保持"永不触发"。

## 复查命令

在**任一**集群 context 下跑，重新生成当前快照（替代本文不放的那张总表）：

```sh
# 逐个 CronJob 的关键字段。⚠️ 列定义必须用变量，不能在 custom-columns= 里换行 ——
# 续行的反斜杠会被当字面量塞进列名，表头直接乱掉（2026-08-24 实测踩到）。
COLS='NS:.metadata.namespace,NAME:.metadata.name,SCHED:.spec.schedule,CONCUR:.spec.concurrencyPolicy,STARTDL:.spec.startingDeadlineSeconds,ACTIVEDL:.spec.jobTemplate.spec.activeDeadlineSeconds,TTL:.spec.jobTemplate.spec.ttlSecondsAfterFinished,SUCC:.spec.successfulJobsHistoryLimit,FAIL:.spec.failedJobsHistoryLimit'
for CTX in k3s-homelab oracle-k3s; do
  echo "--- $CTX ---"
  kubectl --context "$CTX" get cronjob -A -o custom-columns="$COLS"
done

# 配额用量（注意 pods 与 count/pods 语义不同）
for CTX in k3s-homelab oracle-k3s; do
  kubectl --context "$CTX" describe resourcequota -A | grep -E '^(Name:|Namespace:|pods|count/)'
done
```

⚠️ 判 `activeDeadlineSeconds` 是否真的生效**不能只看 git 里的 YAML**（层级写错会被
静默丢弃）—— 用上面这条 `kubectl get` 从**服务端**读，或 `apply --dry-run=server`。

## 相关

- 取舍与被否决的方案（含"为什么不强制 TTL"、"为什么不加 Kyverno 策略"）→
  [../decisions/cronjob-and-job-hygiene.md](../decisions/cronjob-and-job-hygiene.md)
- 告警路由与覆盖盲区 → [observability-alerting-slo.md](observability-alerting-slo.md)
- 资源 requests/limits 与 QoS（**不含**配额）→ [k8s-qos-resource-management.md](k8s-qos-resource-management.md)
