# Runbook — readlist 首次引导 / 灾后重建数据

> Last updated: 2026-08-05
>
> **触发条件**：readlist 的 PVC 是空的或被恢复成了空库 —— 首次上线、`readlist-data` 丢失后
> 重建、或从 restic 恢复出一份不含 run 的库。
> **成功判定**：`readlist_last_score_unix` 是本次引导的时间戳（非 0），
> `/api/rankings/publisher-picks` 与 `/api/rankings/to-read-next` 都返回非空榜，
> 且 4 个引导 Job 已删除（第 5 步）。
> **不适用**：日常运维。三个 CronJob（01:05 / 01:20 / 01:40）会自己维持数据。
> **回滚**：本篇属恢复类（自身即回滚路径）—— 全部步骤只写 `readlist-data` 这一个卷，
> 对 calibre 两库是只读/`VACUUM INTO`。要重来就删 `readlist-data` 里的 db 重跑第 1 步；
> ⚠️ 唯一不可逆的成本是 ingest 烧掉的 Google Books 配额（缓存有 TTL，重跑不免费）。
> **集群**：oracle-k3s · ns `personal-services` · 清单
> [`cloud/oracle/manifests/personal-services/readlist.yaml`](../../cloud/oracle/manifests/personal-services/readlist.yaml)

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

三个数字决定后面所有步骤是否可信：

| 日志里的数字 | 期望 | 不对时说明什么 |
|---|---|---|
| works / editions 数 | 约 2,054 本量级 | 远小 = `SOURCE_METADATA_DB` 路径或书库卷挂错 |
| reading 行数 | **约 23** | **0 = `CALIBRE_USER_ID` 填错**（app.db 里的用户 id）。这是静默失败，不会报错 |
| pubdate 污染计数 | 约 477 本标着"今年出版" | 这是已知污染（2026-07 元数据补全的 mtime 兜底），由代码强制记 `unknown`，**不是** bug |

⚠️ `reading` 行数为 0 时**先别往下走**：`to-read-next` / `read-and-loved` 两个榜会是空的，
而那是本站最有用的部分。改 ConfigMap 的 `CALIBRE_USER_ID` 后重跑这一步。

### 2. score —— 先只用内部信号验一遍

此时只有 T（可读性等）维有数据，外部证据还没摄入。

```bash
$K create job bootstrap-score --from=cronjob/readlist-score
$K wait --for=condition=complete job/bootstrap-score --timeout=300s
$K logs job/bootstrap-score
```

**核对 `publisher-picks` 这个内部榜** —— 它零外部依赖，能直接反映出版社归一、
work 聚类、孤儿行是否正常。域名还没接，走 port-forward：

```bash
$K port-forward deploy/readlist 18080:8080 >/dev/null 2>&1 &
sleep 2
curl -s localhost:18080/api/rankings/publisher-picks | head -c 800; echo
curl -s localhost:18080/metrics | grep -E 'readlist_(last_score_unix|grade_counts|runs_retained)'
kill %1
```

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
$K get pods -l app=readlist                       # Running 1/1
curl -s https://readlist.meirong.dev/api/rankings/publisher-picks | head -c 200
# metrics：readlist_last_score_unix 应是刚才的时间戳，不是 0
```

`readlist_last_score_unix` 长期不动 = 夜间管道静默失效，这是该服务**唯一**能暴露
"数据过期但站点照常 200"的信号。告警见
[`docs/reference/observability-alerting-slo.md`](../reference/observability-alerting-slo.md)。

## 相关

- 需求 / 评分标准 / 源码：[meirongdev/readlist](https://github.com/meirongdev/readlist)（那边是唯一真相源）
- 上游的上线剩余项归档：该仓库 `docs/homelab-deploy.md`
- 备份归属：`readlist-data` 在 [`backup/overlays/oracle/backup-script.yaml`](../../backup/overlays/oracle/backup-script.yaml)
  的 sqlite 白名单里（卷上的 `evidence` 重建要烧 2–3 天配额，不是派生物）
