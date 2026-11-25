# jobs-sg — 新加坡 SWE 岗位趋势周报（架构事实）

> Last updated: 2026-11-25
> Status: 生效事实
> Scope: jobs-sg 在 homelab 集群的部署形态、镜像固定方式、备份口径、首次上线依赖顺序；
> LLM 富化、分类与技术栈重算各拆一篇（[jobs-sg-enrich.md](jobs-sg-enrich.md)、[jobs-sg-classification.md](jobs-sg-classification.md)）。
> 本文是 source of truth。应用代码在 [meirongdev/jobs-sg](https://github.com/meirongdev/jobs-sg)。

## 速览

- **在哪**：homelab 集群独立 ns `jobs-sg`，`jobs.meirong.dev`（无认证，公开统计）。
  一个镜像里 6 个二进制：4 个管线阶段（ingest / enrich / report / web）= 3 个 CronJob
  + 1 Deployment；另外 2 个是运维工具、**没有任何 CronJob 跑**，手动起一次性 Job
  （`reclassify` 重算分类、`retech` 重算规则层技术栈，都默认 dry-run，见 [jobs-sg-classification.md](jobs-sg-classification.md)）。
- **跑什么**：每日抓 SG 岗位 → 规则 + LLM 富化（经 LiteLLM 网关打 DGX，fail-open，见 [jobs-sg-enrich.md](jobs-sg-enrich.md)）→ 周报推 Telegram；
  聚合页随请求渲染。
- **备份两条路径，缺一不可**：`jobs.db` 走白名单；`raw/*.jsonl.gz` 单独纳 restic，
  只加白名单会静默漏备（H4 查不出）。
- **首次上线依赖顺序**：见 § 首次上线，那不是配置错误，别去"修"。
- **已知缺口**：见文末「已知缺口」；历次事故复盘见文末「相关记录」。

## 部署形态

| 项 | 值 |
|---|---|
| 集群 | **homelab**（`https://100.94.186.7:6443`） |
| Namespace | `jobs-sg`（独立 ns，PSA `restricted`） |
| URL | `jobs.meirong.dev`（无认证；公开就业市场统计，无个人数据） |
| 清单 | `k8s/helm/manifests/jobs-sg/`（kustomize 目录） |
| Application | `argocd/applications/jobs-sg.yaml` |
| 镜像 | `ghcr.io/meirongdev/jobs-sg`，按 **manifest-list digest** 固定 |
| PVC | `jobs-sg-data` 10Gi `local-path`，`Prune=false` |
| 密钥 | 仅 bot token：复用 Vault `secret/homelab/telegram` → ESO → `jobs-sg-secrets` |

| 组件 | 触发 | 说明 |
|---|---|---|
| `ingest` | 每日 18:15 UTC（02:15 SGT） | 增量；程序按 SGT 判断周日自动转全量 reconcile |
| `enrich` | 每日 19:10 UTC | 规则 + LLM（经 LiteLLM 打 DGX vLLM）；fail-open |
| `report` | 周一 01:00 UTC（09:00 SGT） | 出 HTML/MD + 推 Telegram |
| `jobs-sg-web` | 常驻 | 只读挂载 PVC，服务页面 + Prometheus 指标 |

⚠️ **`web` 监听两个端口**：`8080` 服务公共站点、`9090` 只服务 `/metrics`（`--metrics-addr`）。
HTTPRoute 只指向 8080，所以 `https://jobs.meirong.dev/metrics` 必须是 404，那是端口拆分生效
的判据。ServiceMonitor 抓 Service 的 `port: metrics`，改名或改回 `http` 都会**静默**不抓。

| 路径 | 内容 |
|---|---|
| `/` | 实时市场快照 |
| `/tech` | 技术栈榜与动量（历史不足 5 周时显示「需 5 周历史」，是一等状态不是空图） |
| `/pay` | 薪资分位与溢价（样本不足的格子显示 `—(n=3)`，刻意抑制而非伪精度） |
| `/companies` | 雇主、在架时长、竞争度 |
| `/reports`、`/w/{YYYY-Www}` | 最新周报 / 指定周的周报（静态文件） |
| `/ops` | 每日抓取统计：按 SGT 日历日一行，日状态取当天最差 run |
| `/ops/{YYYY-MM-DD}` | 当日下钻：逐 run 记录、角色与资历分布、技术栈、当天首见岗位（上限 200） |
| `/daily`、`/daily/{date}` | 301 → `/ops`（兼容旧链接，新地方别再写旧路径） |
| `/healthz` | 只验 DB 能打开，存活探针与 Uptime Kuma 用这个 |
| `/robots.txt` | — |
| `/metrics` | 公网 404；只在集群内 `svc/jobs-sg-web:9090` 可达 |

聚合页随请求渲染（不经 CronJob 落文件）：ingest 约 02:20 SGT 落地，数字必须当场最新。
周报仍是静态文件，它要归档、要推 Telegram。

## 为什么用独立 ns + 独立 Application

不并进 `personal-services`：后者的 `ResourceQuota` 限死 `count/jobs.batch`（为 92-pod 泄漏
事故加的护栏），三个 CronJob 的历史 Job 会挤占它。且本应用需要 kustomize 目录（`images`
digest 转换器）+ `ignoreDifferences`，`directory.include` 模式不支持。

## ⚠️ 首次上线的依赖顺序（不是配置错误，别去"修"）

`web` 用 `mode=ro` 打开 `/data/jobs.db`，文件不存在就 exit 1（sqlite `mode=ro` 不建库）。
空 PVC 上首次部署必然 CrashLoopBackOff，直到第一次 `ingest` 建出库。手动 bootstrap 一次：

```bash
kubectl --context k3s-homelab -n jobs-sg create job ingest-bootstrap --from=cronjob/ingest
kubectl --context k3s-homelab -n jobs-sg logs -f job/ingest-bootstrap
```

DB 空时走 `--full-scan-pages` 的 baseline 全量扫描（实测 884 页 / 88k seen / 29 分钟，
`activeDeadlineSeconds: 3600` 够用）。被 MCF API 429 掐断也不用重跑：watermark 已落库，
次日增量续上。⚠️ 别按「库里岗位数 ÷ 100」估页数：扫的是整块板（`seen`），入库的只是
候选岗位，差近一个数量级。

存活探针和 Uptime Kuma 都打 `/healthz`，别拿聚合页当探针。

## web 与 SQLite 的约束

### 只读挂载要求 rollback journal，不能是 WAL

`web` 的 `/data` 以 `readOnly: true` 挂载。WAL 打开时要在数据目录建 `-shm`，只读挂载上做不到，
`SQLITE_CANTOPEN`，web 启动即崩。所以 journal 是 `DELETE`（上游 `4538ba9`）。写入方由 cron
排期天然串行（ingest/enrich/report 不重叠），失去 WAL 并发无实际代价。

### 只读根文件系统还要一个可写 `/tmp`（否则大查询 500）

`web` 是 `readOnlyRootFilesystem: true`。SQLite 的排序/分组超出 page cache 要把临时 b-tree
溢出到文件，候选目录（`$SQLITE_TMPDIR` → `$TMPDIR` → `/var/tmp` → `/usr/tmp` → `/tmp`）全不可写
就返回 `SQLITE_IOERR_GETTEMPPATH`（扩展码 6410），日志形如 `"err":"disk I/O error (6410)"`，
HTTP 500。修法是挂 emptyDir 到 `/tmp` 并显式 `SQLITE_TMPDIR=/tmp`（见 `web.yaml`）。

- ☠️ 这个坑按**数据量**触发，冒烟测试抓不到：小库上全 200，灌满后最大的聚合查询才 500。
  只读根文件系统 + SQLite 要按最大查询验，不按当时的库。
- emptyDir 用磁盘不用 `medium: Memory`：tmpfs 算进容器 192Mi 内存上限，溢出几十 MB 就 OOMKill。
  `sizeLimit: 256Mi` 兜住节点临时盘。`/data` 仍是 `readOnly`。

### 聚合页的 5s 预算 vs CPU 上限

上游给所有聚合页写死了 `dailyTimeout = 5s`（`internal/web/daily.go:24`）：查询超时就是 500，
不是慢。单线程 SQLite 被 CFS 节流到 0.2 核时 `/tech` 必然超时，所以 web 的 CPU 上限是 1000m
（requests 25m，上限不预留资源）。实测（1000m 上限、约 1.1 万在架岗位）：`/reports` 0.10s、
`/` 0.33s、`/ops` 0.38s、`/companies` 0.49s、`/tech` 1.63s、`/pay` 2.01s。

☠️ **判 CPU 节流别用 `kubectl top`**：metrics-server 采样窗口几十秒，5 秒的突发被平掉
（它报 25m 时实际 61% 的周期被掐）。判据是 cAdvisor 的节流比，在 homelab 的 Prometheus 上查
（`kubectl --context k3s-homelab -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090`）：

```promql
rate(container_cpu_cfs_throttled_periods_total{namespace="jobs-sg",container="web"}[5m])
  / rate(container_cpu_cfs_periods_total{namespace="jobs-sg",container="web"}[5m])
```

⚠️ 不要再往上加：homelab 控制面是热笔记本（[homelab-host-power-thermal.md](homelab-host-power-thermal.md)），
真需要更多就该去修上游查询或那个 5s 预算。

### 手动跑写侧进程会和 web 抢锁

`db.go` 的「写入由 cron 排班串行化」只在没人手动插一轮时成立。DELETE journal 下写者提交要把
RESERVED 升级成 EXCLUSIVE，web 渲染时持 SHARED，SQLite 立即返回 `SQLITE_BUSY`，**不进**
busy handler（在那儿睡可能死锁）。

- 上游 `730c6f3` 起写事务撞锁会重跑整个事务（退避 25/50/100/200/400ms），不再把整轮标成 partial。
- ⚠️ 再看到 `database is locked` 别去调 `busy_timeout`（设的是 10s，这个场景根本不调用它）。
- 这条值得修是因为代价不对称：partial 的 reconcile 会整个跳过关闭逻辑（`ingest.go:280`），
  周日那轮撞一次锁就静默损失一周的岗位寿命数据。
- `/ops/2026-08-08` 01:09 那行 `partial` / `errors=1` 保留不动：它是当时的事实，改库等于篡改记录。

## LLM 富化（细节在 jobs-sg-enrich.md）

`enrich` 经 LiteLLM 网关的 `custom_dgx/` 别名打 DGX（刻意不要兜底），DGX 不可用时 fail-open 退回纯规则。
接线与取舍、耗时与超时、关 reasoning 啃积压、`reasoning_effort` 封顶、归档读取 → [jobs-sg-enrich.md](jobs-sg-enrich.md)。


## 镜像固定

Kyverno `disallow-latest-tag` 在 homelab 是 Enforce，策略 digest-aware（digest 与明确 tag 放行，
只拦 `:latest`）。本应用按 digest 固定，且必须用 **manifest-list（OCI index）digest**，不是
amd64 单架构 digest，否则换架构拉不到。升级只改 `kustomization.yaml` 的 `images[0].digest`，
命令见该文件注释。digest 手动改（仓库没有自动更新镜像的机制，见 [argocd-app-patterns.md](argocd-app-patterns.md)）。

- ☠️ **「只改 digest 一行」不总是够**。上游挪了端口或指标时清单要同批改，否则 ServiceMonitor
  继续抓旧端口，指标全断且不报错，所有告警一起变瞎（`90cd4e8` 把 `/metrics` 挪到 9090 就是这种）。
  升级前在 jobs-sg 仓库看 `git diff <旧sha>..<新sha> -- deploy/ internal/metrics`，那是「清单要
  跟着改什么」的清单；上游 `docs/09-deploy-runbook.md` 是配套的踩坑册。
- ☠️ 别回滚到 `2d7b9ad` 之前（ingest 一律 panic）、`738cb98` 之前（归档每条重扫），也别回到
  `8b3040a` / `73aa949`（retech 的 dry-run 会写库、重放让岗位掉回积压，`fba4fcf` 才修全）。

### schema 迁移：web 只读，索引靠写侧进程建

上游 schema 全是 `CREATE TABLE / CREATE INDEX IF NOT EXISTS`，由 `ingest`/`enrich`/`report`
启动时 `Migrate()` 幂等执行。`web` 从不 Migrate，所以新镜像带来的新表/新索引在下一次写侧进程
跑起来之前不存在：

- 只加索引 → 页面仍正确，但全表扫，聚合页明显变慢。
- 加了新表且 web 要查它 → 500，直到写侧进程建表。
- 补列走 `store.addedColumns` 的 `ALTER TABLE`（`CREATE TABLE IF NOT EXISTS` 对已存在的表是空
  操作）。`/metrics` 用 `HasColumn` 兜住「新 web 撞上还没迁移的库」那段窗口：不兜的话 scrape
  500，jobs-sg 全部告警连同 staleness 一起哑掉。

升级后不想等 18:15 UTC 那轮 ingest，就手动补一次（增量 2–4 分钟；会和 web 抢锁，见上）：

```sh
kubectl --context k3s-homelab -n jobs-sg create job --from=cronjob/ingest ingest-migrate-1
```

## 备份口径（两条路径，缺一不可）

`local-path` 无冗余无快照，备份是强制项。`backup/overlays/homelab/backup-script.yaml` 里
jobs-sg 占两处：

1. **`jobs.db`（+ journal）**：第 2 步 `for pat in ... jobs-sg-data` 白名单，靠 `*.db` /
   `*.db-journal` 文件名模式捞走。
2. **`raw/` 归档**：第 3 步的 `JOBS_ARCHIVE_DIR` 整目录直接纳入 restic，不经 `/work` 中转
   （`/work` 是 emptyDir，每晚拷一遍白吃节点临时盘）。同 oracle overlay 的 `BOOKS_DIR` 做法。

☠️ **只加白名单是不够的**：归档是 `raw/<date>/NNN.jsonl.gz`，匹配不上那组模式。上游 jobs-sg
`docs/04` §4 只写了加白名单一行，照做会让最不可替代的数据静默漏备。CI 的 H4 只查 PVC 有没有
备份归属，查不出「归属了但模式对不上」，只能实测（`restic ls` 确认 `.jsonl.gz` 真在快照里）。

- 归档不可重建：MCF API 只返回当前在架职位，下架的永远拿不回来。
- 归档写的是解析后重新 marshal 的结构体（`archive.Write` 里 `json.Marshal(j)`），不是原始响应
  字节。这是刻意的合规取舍（`createdBy` / `emailRecipient` 等发布者个人字段不建模、不落盘），
  代价是结构体没建模的字段永久丢失。
- 恢复演练：`restic-restore-drill` CronJob 每月从 106 仓库实际 restore `jobs.db` 并跑
  `PRAGMA integrity_check` + 表数判据；`raw/*.jsonl.gz` 只抽一个文件 `gzip -t`（不是全量恢复）。
  → [storage.md 月度恢复演练](storage.md#月度恢复演练2026-08-13-上线)

## 密钥与 Telegram 路由

没有新的 Vault 路径，也没有需要手工写的值。按本仓库既有分工拆开（同 Alertmanager / krr，
见 [decisions/alerting-telegram-migration.md](../decisions/alerting-telegram-migration.md)）：

| 项 | 是密钥？ | 放哪 | 值 |
|---|---|---|---|
| bot token | 是 | Vault `secret/homelab/telegram` property `bot_token` → ESO | 已存在，与告警共用同一个 bot |
| chat id | 不是 | `cronjob-report.yaml` 明文 | `-1003981213530`（与告警同一个群） |
| thread id | 不是 | `cronjob-report.yaml` 明文 | `552` = 群里的 `jobs-sg` 话题 |

- `external-secret.yaml` 里是两个对象：`jobs-sg-secrets` 只声明 `telegram-bot-token`（路径一直在线同步，
  `monitoring/alertmanager-telegram` 同用）；`jobs-sg-llm` 只声明网关 key（2026-11-11）。
- ⚠️ **ESO 的 `data` 是全有全无的**：只声明真正要用的键，不相干的键分到不同对象。网关 key 合进
  `jobs-sg-secrets` 的话，它取不到时连 bot token 都同步不了。
- ⚠️ 别引用还没人填的 Vault 路径：ESO `Ready=False` → `ExternalSecretNotReady` 持续告警、App 常驻
  `Degraded`。先看现有路径够不够用。
- `TELEGRAM_BOT_TOKEN` 标 `optional: true`：ESO 没同步上时 report 打一行 "telegram disabled"
  后照常生成 HTML/MD，而不是 `CreateContainerConfigError` 卡住整个 Job（同
  `backup/overlays/homelab/open-notebook-external-secret.yaml` 的取舍）。

### 话题路由

告警与周报共用同一个群（MatthewDaily，`is_forum: true`），只靠 `message_thread_id` 区分话题：

| 话题 | thread id | 谁在用 |
|---|---|---|
| 🚨 Homelab 告警 | `2` | Alertmanager（含两集群 Tetragon 经 Loki ruler 的运行时告警）/ krr |
| jobs-sg | `552` | jobs-sg 周报 |
| （General） | 留空 | — |

- 刻意不复用 thread 2：上游 `docs/02 §4.3` 明令周报不得进告警话题。
- 换话题：Telegram 里右键目标话题 → 复制链接，`t.me/c/<内部 id>/<thread_id>` 的第二个数字填进
  `cronjob-report.yaml` 的 `TELEGRAM_THREAD_ID`（一行改动，不涉及 Vault）。bot
  `@matthew_daily_bot` 是群管理员且有 `can_manage_topics`，也可以用 `createForumTopic` 自建
  （见 git 历史里的一次性 Job，token 从 Secret 注入、不落日志）。
- ☠️ thread id 必须按 Integer 发（上游 `8259cba` 起是数字，非数字显式报错）。发成字符串会**静默**
  投到 General 且回 200，看着完全像成功。

## 可观测

`web` 的 `/metrics`（容器 9090）暴露 `jobs_sg_*`，状态算自 DB 而非进程内存，web 重启不丢指标。
Prometheus/Alertmanager 在 homelab，监控对象跟着落 homelab。

- ☠️ ServiceMonitor + PrometheusRule 都必须带 `release: kube-prometheus-stack`，漏了被 operator
  **静默**忽略。端口名对不上是同一种失败模式：ServiceMonitor 必须抓 `port: metrics`。
- 无值即不输出、绝不补 0（首次 report 前就没有 `jobs_sg_jobs_new`，补 0 会让「还没有数据」和
  「真的是 0」不可区分）；任何 DB 错误 → 整个 scrape 500，让 Prometheus 把 target 标 down。
- 指标名：`jobs_sg_jobs`、`jobs_sg_jobs_new`（没有 `week` 标签，周次让 Prometheus 的时间轴回答）、
  `jobs_sg_unmapped_tech`（双向变动的 gauge，不带 `_total`）。建面板用这些名。

告警全集见 `monitoring.yaml`。最重要的是 `JobsSgIngestStale`：这类应用静默失效比崩溃更危险。

| 告警 | 表达式要点 | 为什么这样写 |
|---|---|---|
| `JobsSgIngestStale` | `min without(kind)` 取 `kind=~"incremental\|full_reconcile"`，>36h | 周日那轮记成 `full_reconcile`，只看 `incremental` 会每周固定断档 48h 误报 |
| `JobsSgReconcileStale` | `full_reconcile` >10d（含从未成功） | 管生命周期对没对账，与上一条解耦 |
| `JobsSgEnrichBacklogGrowing` | `min_over_time([1d]) - min_over_time([1d] offset 1d) > 500`，`for: 2h` | 稳态积压是锯齿形，每日低谷才是「管线还跟不跟得上」的信号；绝对阈值会被一次性灌入打响 |

## 全量 reconcile（关闭下架岗位）

- 只有周日 SGT 那轮（UTC 周六 18:15）是全量 reconcile，关闭逻辑只在这轮跑。本轮见到的岗位即使
  已过 `expiry_date` 也不关（在架压过过期日）；没见到但未到期的只记 `miss_count`，两周判定；
  回架的岗位会 reopen。
- 闸门看覆盖率 `scanned / max(total)` ≥ 80%（`jobs_sg_reconcile_scan_coverage_ratio`）。total 在
  一轮扫描内会摆 ±10%，偏差只做遥测（`deviation_ratio`），不参与判定。
- 按 `expiry_date` 关闭不受扫描完整度门控（那是 MCF 公布的下架日）。
- 干净的对账轮（errors=0，含 close_skipped）照常刷新 incremental 新鲜戳；`full_reconcile` 的戳
  单独计。`JobsSgIngestStale` 管数据新不新，`JobsSgReconcileStale` 管生命周期对没对账。
- ⚠️ 36h 阈值依赖 reconcile 能成功，别放宽（周日没有 incremental，间隔天然 48h）。
- ☠️ `JobsSgIngestStale` 响了先查是不是 partial，别从「抓取停了」查起。
- 排查抓手：`ingest_run` 的 `jobs_scanned` / `total_reported` / `total_min` / `total_max` /
  `close_skipped`；指标 `jobs_sg_reconcile_scan_deviation_ratio`、
  `jobs_sg_reconcile_close_skipped_total`。⚠️ `jobs_seen` 是本轮归档的条数（reconcile 只归档没存过
  的），`jobs_scanned` 才是走过的条数，两者不等不是故障。

经过与数值见 [records/2026-08-09-jobs-sg-reconcile-never-succeeded.md](../records/2026-08-09-jobs-sg-reconcile-never-succeeded.md)。

## MCF 数据源的形状

解析与口径都依赖这几条，改解析器前先对一遍：

- `newPostingDate` 是纯日期（`"2026-08-03"`），不是 RFC3339。按 RFC3339 解析会静默失败、让增量
  早停变成死代码（`mcf.ParsePostingDate` 纯日期优先）。
- `employmentTypes` / `salary.type` / `address.districts` / `flexibleWorkArrangements` /
  `schemes` / `_links.{self,next}` 是对象不是 string。Page 整页解码，一条坏数据废掉同页 100 条。
  守卫是 `internal/mcf/livedecode_test.go`（真实响应断言）；别从结构体生成 fixture，那样测试与
  bug 会错得一致。
- 运行镜像是 `FROM scratch`，没有 zoneinfo：时区用 `time.FixedZone("SGT", 8*3600)`。
- `total` 平静时段精确，扫描期间会摆 ±10%（见上一节）。
- API 只返回当前在架职位（所以归档不可重建）。

## 已知缺口

- 开放项见 [ROADMAP.md](../ROADMAP.md) 第 9 条（Telegram 端到端实测、Grafana 面板、`closed` 口径、
  并发与重试两个旋钮）。`jobs_sg_*` 已在采，没有面板时用 Explore 查。
- 历史周的 `active_jobs` 无法按出版时点重建（as-of 查询未实现），见 [jobs-sg-classification.md](jobs-sg-classification.md)「重算历史周」。
- 手动 kill enrich/ingest Job 会留下孤儿 `running` 行（只写了 StartRun，`ended_at` 为 NULL）。
  确认集群无活跃 run 后，在 PVC 所在节点上先备份 `jobs.db`，再执行
  `DELETE FROM ingest_run WHERE status='running' AND ended_at IS NULL`。

## 分类与技术栈：口径与重算（细节在 jobs-sg-classification.md）

分类结论与规则层技术栈都是 ingest / enrich 当时算好落库的，改了分类器或别名表修不了历史，要用两个运维工具
（`jobs-sg-reclassify`、`jobs-sg-retech`，都默认 dry-run）重放归档；`weekly_metric` 另要逐周 `report --week`。
用法与红线、别名表规则、`work_mode` 口径 → [jobs-sg-classification.md](jobs-sg-classification.md)。


## 相关记录

- [records/2026-08-03-jobs-sg-launch-defects.md](../records/2026-08-03-jobs-sg-launch-defects.md)：
  上线当天的七个缺陷，含上线实测基线
- [records/2026-08-05-jobs-sg-daily-partial.md](../records/2026-08-05-jobs-sg-daily-partial.md)
- [records/2026-08-09-jobs-sg-reconcile-never-succeeded.md](../records/2026-08-09-jobs-sg-reconcile-never-succeeded.md)
- [records/2026-08-24-jobs-sg-tech-alias-false-positives.md](../records/2026-08-24-jobs-sg-tech-alias-false-positives.md)（含历史重放）
- [records/2026-09-04-jobs-sg-enrich-runaway-reasoning.md](../records/2026-09-04-jobs-sg-enrich-runaway-reasoning.md)
