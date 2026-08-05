# Runbook — readlist 首次引导 / 灾后重建数据

> Last updated: 2026-08-05
>
> **触发条件**：readlist 的 PVC 是空的或被恢复成了空库 —— 首次上线、`readlist-data` 丢失后
> 重建、或从 restic 恢复出一份不含 run 的库。
> **成功判定**：`readlist_last_score_unix` 是本次引导的时间戳（非 0），
> `/api/v1/lists/to-read-next` 返回非空榜，score 日志里 `publisher-picks` 条目数非 0，
> 且 4 个引导 Job 已删除（第 5 步）。
> **不适用**：日常运维。三个 CronJob（01:05 / 01:20 / 01:40）会自己维持数据。
> **回滚**：本篇属恢复类（自身即回滚路径）—— 全部步骤只写 `readlist-data` 这一个卷，
> 对 calibre 两库是只读/`VACUUM INTO`。要重来就删 `readlist-data` 里的 db 重跑第 1 步；
> ⚠️ 唯一不可逆的成本是 ingest 烧掉的 Google Books 配额（缓存有 TTL，重跑不免费）。
> **集群**：oracle-k3s · ns `personal-services` · 清单
> [`cloud/oracle/manifests/personal-services/readlist.yaml`](../../cloud/oracle/manifests/personal-services/readlist.yaml)

## ☠️ 先看这条：不要用 `readlist init` 去"初始化"

`init` 在幂等检查**之前**无条件调 `corpus.Seed(db)`，而 seed 是**演示语料** ——
写死的假 Google/OpenLibrary 评分、假 HN 提及次数、假 depth/level 标注、假个人星级。
Seed 自带「editions 非空则跳过」，所以它**只在空库上开火** —— 也就是本 runbook
适用的每一种场景（首次部署、PVC 重建、从残缺备份恢复）。

2026-08-05 实测踩过：当时给 Deployment 加了 `init` initContainer，结果 ingest 明确报
「HN 提及 0 条」，站上却显示 Fluent Python「HN 提及 5 次(2018–2025)」、
Python Crash Course「HN 提及 3 次」—— 全是 `seedBooks` 里写死的数。被污染的
`timeless`/`deep-dive`/`to-read-next` 榜看上去完全正常（7/3/9 条），
清库重打之后才现出真相：**这三个榜本该是 0 条**。

判据（清库后应当如此）：`证据徽章 A=0 B=0 C=0 D=<全部>`，且除 `publisher-picks`
与 `library-hygiene` 外所有榜都是 0 条 —— 外部证据要等 ingest。看到 A/B/C 非 0
而 ingest 还没跑过，就是被 seed 污染了，只能清库重来（下面第 0 步）。

### 第 0 步（仅在库已被污染时）：清库

```bash
K="kubectl --context oracle-k3s -n personal-services"
$K scale deploy/readlist --replicas=0
$K wait --for=delete pod -l app=readlist --timeout=120s
# 用一次性 busybox Job 挂 readlist-data 删掉 db 与 snapshot 目录
#   （readlist 镜像是 distroless，没有 shell，进不去）
#   rm -f /data/readlist.db /data/readlist.db-wal /data/readlist.db-shm
#   rm -rf /data/snapshot
# 跑完删掉该 Job，然后让 ArgoCD 把 replicas 恢复成 1（或手动 scale 回 1），
# ⚠️ 确认 Deployment 里**没有** initContainer 之后再起 pod，否则又会 seed 一遍：
$K get deploy readlist -o jsonpath='{.spec.template.spec.initContainers[*].name}'   # 期望为空
```

清库会连 ingest 的**缓存一起丢**（外部证据要重新烧配额）。这是代价，但污染的库不能留。

## 为什么需要手动引导

清单一同步，`serve`（和它的 `init` initContainer）会在空库上**自愈发布一个 0 本书的 run**。
不崩、全部 200、探针通过 —— 但站点是空的，而且要等到次日 01:40 才有内容。
所以首次部署后必须立刻按顺序把三个 Job 手动跑一遍。

⚠️ **顺序不能换**：`ingest` 只对 `snapshot` 已经建出的 works 发请求；先跑 ingest 等于白烧配额。

## 前置检查

```bash
K="kubectl --context oracle-k3s -n personal-services"

# 1) Google Books key 必须已经到位 —— 缺了它 A 维(读者评分)与 F 维(时效)基本拿不到数据，
#    而 ingest 拿到的 publishedDate 是修 pubdate 污染的唯一来源。
$K get secret readlist-secrets -o jsonpath='{.data.google-books-key}' | base64 -d | head -c 8; echo
#    空的话：写 Vault secret/oracle-k3s/readlist 的 GOOGLE_BOOKS_KEY，再等 ESO 刷新(≤1h)或
#    kubectl -n personal-services delete externalsecret readlist-secrets 让 ArgoCD 重建。

# 2) Job 配额余量 —— 引导要占 4 个 Job 对象，ns 上限是 count/jobs.batch: 20
$K get resourcequota personal-services-object-caps -o jsonpath='{.status.used.count/jobs\.batch}{"/"}{.status.hard.count/jobs\.batch}{"\n"}'
```

## 步骤

### 1. snapshot —— 秒级，这一步的**输出必须看**

```bash
$K create job bootstrap-snapshot --from=cronjob/readlist-snapshot
$K wait --for=condition=complete job/bootstrap-snapshot --timeout=300s
$K logs job/bootstrap-snapshot
```

日志形如（**下面的数字是 2026-08-05 首次引导的实测基线**，用来对比）：

```
snapshot: run=snap-… works=2046 editions=2054
  出版社归一: 209 个原始名
  阅读状态镜像: 63 行
  已从库中消失、本次删除: 7 个版次
  ⚠️ 孤儿行(book id 漂移): 3
  ⚠️ pubdate 判为 mtime 兜底: 37;缺失/占位: 5 —— 这些书的时效维度记 unknown
```

| 日志字段 | 实测基线 (2026-08-05) | 偏离说明什么 |
|---|---|---|
| `works` / `editions` | 2046 / 2054 | 远小 = `SOURCE_METADATA_DB` 路径或书库卷挂错 |
| `阅读状态镜像` | **63 行** | **0 = `CALIBRE_USER_ID` 填错**（app.db 里的用户 id）。静默失败，不报错 |
| `孤儿行(book id 漂移)` | 3 | 突增到几十 = calibre 重导元数据改写了 book id |
| `pubdate 判为 mtime 兜底` | 37（+5 缺失） | 已知污染，代码强制记 `unknown`，**不是** bug |

⚠️ 两处**上游文档已过期**，别拿它当期望值：
`meirongdev/readlist` 的 `docs/data-baseline.md` 说阅读状态只覆盖 23 本、pubdate 污染 477 本。
实测是 **63 行**和 **37 本** —— 前者是这期间又补录了，后者是 `calibre-metadata` 那几次
enrich 已经把大部分 pubdate 修好了。以本表为准。

⚠️ `阅读状态镜像` 为 0 时**先别往下走**：`to-read-next` / `read-and-loved` 两个榜会是空的，
而那是本站最有用的部分。改 ConfigMap 的 `CALIBRE_USER_ID` 后重跑这一步。

### 2. score —— 先只用内部信号验一遍

此时只有 T（可读性等）维有数据，外部证据还没摄入。

```bash
$K create job bootstrap-score --from=cronjob/readlist-score
$K wait --for=condition=complete job/bootstrap-score --timeout=300s
$K logs job/bootstrap-score
```

**核对 `publisher-picks` 这个内部榜** —— 它零外部依赖，能直接反映出版社归一、
work 聚类、孤儿行是否正常。

⚠️ **它只出现在 score 的日志里，不要去 curl** —— `publisher-picks` 与 `library-hygiene`
是**内部榜**，公开 API 不提供（v0.1.0 上 `/api/v1/lists/publisher-picks` 返回
`{"error":"unknown preset"}`，这是设计如此，不是故障）。判据就是上面日志里那一行
`list publisher-picks  N items` 的 N 不为 0。

2026-08-05 首次引导的实测基线（外部证据还没摄入，所以 A/B/C 全 0 是正常的）：

```
证据徽章: A=0 B=0 C=0 D=2046
list timeless          7 items      list to-read-next      9 items
list ship-this-week    0 items      list read-and-loved    0 items
list deep-dive         3 items      list publisher-picks  24 items
list fresh-releases    0 items      list library-hygiene  30 items
list ai-llm            0 items
```

`ship-this-week` / `fresh-releases` / `ai-llm` / `read-and-loved` 此时为 0 是**预期**——
它们依赖外部证据或个人星级。要看的是 `publisher-picks` 非 0（聚类正常）
与 `to-read-next` 非 0（阅读状态接上了）。

再顺手核对公开 API 与指标（域名还没接，走 port-forward）：

```bash
$K port-forward deploy/readlist 18080:8080 >/dev/null 2>&1 &
sleep 3
curl -s -o /dev/null -w 'healthz=%{http_code}\n' localhost:18080/healthz
curl -s localhost:18080/api/v1/lists | head -c 300; echo          # 榜单定义（含权重档案）
curl -s localhost:18080/api/v1/lists/to-read-next | head -c 400; echo
curl -s localhost:18080/metrics | grep '^readlist_'
kill %1
```

⚠️ API 前缀是 **`/api/v1/`**，不是 `/api/`：可用的是 `meta` · `lists` · `lists/{id}` ·
`works/{id}` · `matrix/{run}` · `catalog`（全部只读，非 GET 一律 405）。

v0.2.0 的 `/metrics` 有 **14 个指标族**（v0.1.0 只有 5 个）：三个作业各自的新鲜度
（`last_score_unix` / `last_snapshot_unix` / `last_ingest_unix`）· `works_total` ·
`lists_total` · `runs_retained` · `grade_counts{grade}` · `orphan_rows` ·
`pubdate_source{source}` · `dim_measured{dim}` · 四个 `ingest_*`。
哪些接了告警、哪些**刻意没接**，见
[`alerts/readlist-alerts.yaml`](../../k8s/helm/manifests/monitoring/alerts/readlist-alerts.yaml)。

⚠️ 写告警前先 `curl` 实际跑着的 pod 确认指标存在，**别照上游源码写** —— 工作区
经常跑在已发布 tag 前面。2026-08-05 就是这么吃过亏：源码里有的指标 v0.1.0 镜像
里没有，规则挂上去永不触发，而那和「一切正常」在界面上一模一样。

另：v0.2.0 起存活探针是 `/livez`（**不碰数据库**），`/healthz` 只做就绪探针。
排障时想区分「进程死了」和「库慢/没打分」，分别打这两个端点。

榜里出得来书、出版社名字不是一堆重复变体 → 可以放 ingest。出不来就别烧配额，先查聚类。

### 3. ingest —— 唯一出网的一步，约 800 次请求 / 10–15 分钟

```bash
$K create job bootstrap-ingest --from=cronjob/readlist-ingest
$K wait --for=condition=complete job/bootstrap-ingest --timeout=1800s
$K logs job/bootstrap-ingest | tail -30
```

`INGEST_BUDGET=800` 是**每次运行**的上限；全库约需 1,000–1,500 次请求，
所以首轮要 **2 晚**跑完（次日 01:20 的 CronJob 会自动跳过已缓存的，只补没查过的）。
日志里看 `缓存命中` 与 `本次预算已用完` 判断进度。

看到大量 429 → Google Books key 没生效，回前置检查第 1 条。

### 4. 再打一次分，公开榜才有内容

```bash
$K create job bootstrap-score2 --from=cronjob/readlist-score
$K wait --for=condition=complete job/bootstrap-score2 --timeout=300s
```

### 5. ⚠️ 收尾：删掉引导 Job

```bash
$K delete job bootstrap-snapshot bootstrap-score bootstrap-ingest bootstrap-score2
```

已完成的 Job pod **仍算 PVC 的使用者** —— 留着会让日后删 `readlist-data` 卡在
`Terminating`，而且白占 `count/jobs.batch` 配额。

## 完成判据

```bash
$K get pods -l app=readlist                                          # Running 1/1
curl -s https://readlist.meirong.dev/api/v1/lists/to-read-next | head -c 200
curl -s https://readlist.meirong.dev/metrics | grep last_score_unix   # 非 0，且是刚才的时间戳
```

`readlist_last_score_unix` 长期不动 = 夜间管道静默失效，这是该服务**唯一**能暴露
"数据过期但站点照常 200"的信号。告警见
[`docs/reference/observability-alerting-slo.md`](../reference/observability-alerting-slo.md)。

## 相关

- 需求 / 评分标准 / 源码：[meirongdev/readlist](https://github.com/meirongdev/readlist)（那边是唯一真相源）
- 上游的上线剩余项归档：该仓库 `docs/homelab-deploy.md`
- 备份归属：`readlist-data` 在 [`backup/overlays/oracle/backup-script.yaml`](../../backup/overlays/oracle/backup-script.yaml)
  的 sqlite 白名单里（卷上的 `evidence` 重建要烧 2–3 天配额，不是派生物）
