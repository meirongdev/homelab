# CronJob 舰队现状：不变量、配额口径、Job 告警覆盖

> Last updated: 2026-10-28
> Status: 生效事实（本文只存不变量与口径，逐个 CronJob 的取值在各自清单里）

为什么这么定见 [../decisions/cronjob-and-job-hygiene.md](../decisions/cronjob-and-job-hygiene.md)。
⚠️ 刻意不放逐个 CronJob 的字段总表：每一格都会漂，清单才是真相源，当前快照跑文末的复查命令。

## 不变量

| 不变量 | 状态 |
|---|---|
| `concurrencyPolicy: Forbid` | 全舰队，无例外 |
| 会自动触发的都有 `activeDeadlineSeconds` 与 `startingDeadlineSeconds` | 已齐（例外见下表） |
| `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` 显式声明 | 全舰队。值刻意不统一：`3/1` 是上游默认，backup 的 `3/3`（多留失败便于排查）、readlist 的 `1/1` 按任务特性选，别当漂移去统一 |

上次全量核对是 2026-08-24，新增 CronJob 照这三条写。缺两个 deadline 的都有正当理由：

| 类别 | 为什么不补 |
|---|---|
| schedule `0 5 31 2 *`：oracle 的 `calibre-metadata-{correct,covers,llm}` + `open-notebook-ingest` | 2 月 31 日永不触发，本仓库用它表达「只手工跑」，累不出 missed；都是长跑的网络作业，没有样本可定 deadline |
| `hubble-generate-certs`（两集群） | Cilium chart 生成、不在 git 里，4 个月一次，上游管 |

☠️ `0 5 31 2 *` 是故意的，别当配错了去「修」。手工跑：
`kubectl --context <ctx> -n <ns> create job --from=cronjob/<name> <name>-manual`。

### `activeDeadlineSeconds` 的定位

断卡死的开关，不是性能预算：只需「比任何合法运行长」且「比排期间隔短」，所以取值远大于实测峰值是刻意的
（推导见决策的采纳 2）。

☠️ 它是 JobSpec 字段，必须写在 `spec.jobTemplate.spec` 下；写到 CronJob 的 `spec` 下是未知字段，
**会被静默丢弃**。本仓库还没有这条 CI 规则，判据二选一：

- 从服务端读回（最强，覆盖手工 apply 的对象）：文末的 `kubectl get cronjob`，或 `kubectl apply --dry-run=server -o json`
- 提交前静态查：`grep -A2 '^  jobTemplate:' <清单>`，看该字段是否在 `jobTemplate.spec` 缩进下

## 配额口径

**`pods` 是非终态 pod 数，`count/pods` 是对象计数、不排除终态。** 护栏要的是前者。
`pods` 防非终态 pod 挤爆节点的 110-pod 上限，`count/jobs.batch` 防 CronJob 泄漏 Job 对象。

| ns | 集群 | 配额键（数值见该 ns 的 limits 清单） |
|---|---|---|
| `jobs-sg` | homelab | `pods` + `count/jobs.batch` |
| `media` | homelab | `pods` |
| `personal-services` | homelab、oracle | `pods` + `count/jobs.batch` |

⚠️ 有 CronJob 但没有配额的 ns：`backup`、`monitoring`、`kube-system`（两集群）、`kube-bench`（homelab）。
Job 对象数由 CronJob 的 history limit 封顶，不是敞口；但手工在这些 ns 起 Job 没有配额兜底。

## Job 告警覆盖矩阵

| 规则 | 来源 | 判据 | 抓什么 |
|---|---|---|---|
| `KubeJobFailed` | chart，warning | `kube_job_failed > 0`，15m | Job 级失败（condition-based） |
| `KubeJobNotCompleted` | chart，warning | `active>0` 且已跑 >12h | 卡死；无 `activeDeadlineSeconds` 时唯一的网 |
| `ResourceQuotaNearlyExhausted` | 自建，`prometheus-rules.yaml` 的 `capacity` 组 | 配额 ≥90%，30m | chart 的 `KubeQuotaAlmostFull`/`KubeQuotaFullyUsed` 是 `info`（进不了 Telegram），`KubeQuotaExceeded` 结构上永不触发（[详见](observability-alerting-slo.md)） |

☠️ 配额满了是这条链上唯一的静默失败：准入层拒绝建 pod，Job 对象建得出来、`active=0`、只刷 `FailedCreate`，
且不被标记成 failed，两条 chart 规则都不响。所以那条自建规则不能删。

⚠️ 写 Job 失败告警用 `kube_job_failed`（condition gauge，`condition=true|false|unknown`），别用
`kube_job_status_failed`（失败 pod 计数，带 `reason`）：`backoffLimit>0` 时「首个 pod 失败、重试后成功」的
Job 会让后者一直为正，告警响满整个 TTL 而 Job 其实成功了。

## 幂等性：上游唯一的硬要求，强制不了

上游 CronJob 文档唯一用 "should" 写的要求是 Jobs 必须幂等，CI 和 Kyverno 都查不了，只能靠 review。
本仓库的判据写在 `calibre-metadata/backfill-job.yaml` 注释里：只填空、绝不覆盖、幂等才允许自动跑，
所以 `calibre-metadata-correct`（会覆盖已有值）刻意保持永不触发。

## 复查命令

在任意目录跑，两个集群 context 各出一份当前快照：

```sh
# 逐个 CronJob 的关键字段。⚠️ 列定义必须放变量，不能在 custom-columns= 里换行：
# 续行的反斜杠会被当字面量塞进列名，表头直接乱掉。
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

## 相关

- 取舍与被否决的方案（为什么不强制 TTL、为什么不加 Kyverno 策略）→ [../decisions/cronjob-and-job-hygiene.md](../decisions/cronjob-and-job-hygiene.md)
- 告警路由与覆盖盲区 → [observability-alerting-slo.md](observability-alerting-slo.md)
- 资源 requests/limits 与 QoS（不含配额）→ [k8s-qos-resource-management.md](k8s-qos-resource-management.md)
