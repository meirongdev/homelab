# jobs-sg — 新加坡 SWE 岗位趋势周报（架构事实）

> Last updated: 2026-08-03
> Status: 生效事实
> Scope: jobs-sg 在 homelab 集群的部署形态、镜像固定方式、备份口径、首次上线依赖顺序
> —— source of truth。应用代码在 [meirongdev/jobs-sg](https://github.com/meirongdev/jobs-sg)。

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
| 密钥 | 仅 bot token：复用已有 Vault `secret/homelab/telegram` → ESO → `jobs-sg-secrets`（无新路径、无需手工写值） |

四个二进制、一个镜像：`ingest`（抓取）、`enrich`（技术栈富化）、`report`（周报 +
Telegram）、`web`（只读服务 + `/metrics`）。三个 CronJob + 一个 Deployment。

| 组件 | 触发 | 说明 |
|---|---|---|
| `ingest` | 每日 18:15 UTC（02:15 SGT） | 增量；程序按 SGT 判断周日自动转全量 reconcile |
| `enrich` | 每日 19:10 UTC | 规则 + LLM（**直连 DGX vLLM**）；fail-open |
| `report` | 周一 01:00 UTC（09:00 SGT） | 出 HTML/MD + 推 Telegram |
| `jobs-sg-web` | 常驻 | 只读挂载 PVC，服务周报 + 抓取统计 + Prometheus 指标 |

对外路由（全部 200 实测）：

| 路径 | 内容 |
|---|---|
| `/` | 最新周报（`report/latest.html`）—— **第一份周报出来前是 404** |
| `/w/{YYYY-Www}` | 指定周的周报 |
| `/daily` | 每日抓取统计：按 SGT 日历日一行（run 类型/状态/页数/归档数/新增/SWE/错误/LLM 调用） |
| `/daily/{YYYY-MM-DD}` | 当日下钻：逐 run 记录、角色与资历分布、技术栈、当天首见岗位（上限 200） |
| `/healthz` | 只验 DB 能打开 —— 存活探针与 Uptime Kuma 用这个 |
| `/metrics` | `jobs_sg_*` |
| `/robots.txt` | — |

`/daily` 系列是随请求渲染（不经 CronJob 落文件）：ingest 约 02:20 SGT 落地，数字必须
当场就是最新的。周报仍是静态文件 —— 它要归档、要推 Telegram。

⚠️ 上表的「200 实测」是**空库/小库时**的结果。`/daily` 与当天的 `/daily/{date}` 在数据
量涨上来后需要可写 `/tmp` 才不 500，见下文「只读根文件系统还要一个可写 `/tmp`」。

## LLM 富化：直连 DGX，不经 Bifrost

`enrich` 的 `LLM_BASE_URL` 指向 **DGX Spark vLLM `http://100.97.87.120:8000`**
（Tailscale IP，pod 直连；同一台机器也在给 Open Notebook 供模型）。这样**完全不需要
Bifrost virtual key**，也就少了一条 Vault 依赖。

⚠️ **模型 id 是后端相关的**：Bifrost 路由用带 provider 前缀的名字
（`custom_dgx/deepseek-v4-flash`），裸 vLLM 提供的是 `deepseek-v4-flash`，写前缀名
会 404。上游原先把模型链**硬编码**成 Bifrost 形式，2026-08-03（`d833623`）才改成读
`LLM_MODELS` / `LLM_CONCURRENCY` 环境变量（默认仍是 Bifrost 链，不破兼容）。

实测（2026-08-03，`jobs-sg` ns 内的 pod）：DGX 可达、**无需认证**、`x-bf-vk` 头被
vLLM 忽略；`deepseek-v4-flash`（1M ctx）返回的正是 enrich 要的严格 JSON。

**取舍**：省掉 VK 与 Vault 依赖，但没有 Bifrost 的 `custom_m2` 回退，也没有用量计量；
DGX 是跨 tailnet 共享的境内机器（RTT 66–83ms），不可用时 enrich fail-open 退回纯规则。
**切回 Bifrost**（三处，缺一不可）：① `LLM_BASE_URL` 改回
`http://bifrost.bifrost.svc.cluster.local:8080` ② 删掉 `LLM_MODELS`（默认链即 Bifrost
形式）③ 在 `external-secret.yaml` 补回 `bifrost-vk` 一项、`cronjob-enrich.yaml` 补回
`BIFROST_VK` env，并把 VK 写进 Vault。当前这两处**都已删除**，因为直连 DGX 用不到。

**单次调用实测 66.5s**（2,326 字描述 / 497 prompt tokens / 937 completion tokens，
reasoning 占大头）。短 prompt 只要 15s —— 别拿短 prompt 的数字做容量规划。

⚠️ **超时值曾经卡在真实耗时下面（2026-08-03）**：上游硬编码 60s，而真实调用要 66.5s，
于是几乎每次都差几秒超时 → 每条白烧 2×60s → fail-open 留在积压里，实测排空只有
**2.1 条/分钟**（一次运行 14 条 fail-open 告警，全是
`Client.Timeout exceeded while awaiting headers`）。
只有特别短的帖子能侥幸跑完，所以表现像「慢」而不是「坏」—— 这类**卡在边界上**的超时
最难发现。上游 `a17d39d` 改成可配置（`LLM_TIMEOUT`，默认 `llm.DefaultTimeout=300s`），
清单里显式写 300。

两个容易误读的点：该端点**非流式**，生成完才回 header，所以这个预算覆盖**整个生成过程**，
不是连接阶段（错误信息里的 "awaiting headers" 极具误导性）；客户端放弃**不会**让服务端
停止生成，每次超时还白耗一次共享 GPU 容量。

**吞吐（集群实测，reasoning 开）：并发 8 下 3.0 条/分钟。**
进度逐条落库，中途被 deadline 杀掉不丢；`enrich_cache` 按 `description_sha256` 去重。

⚠️ 别按「单条 66.5s ÷ 并发 8 = 7.5 条/分钟」推算 —— 那是本文档早期写错的数字。
实测只有 **3.0 条/分钟**：单条独占是 66.5s，但 8 并发时每条被拉长到约 **160s**，
即 8× 并发只换来 **3.3×** 吞吐，DGX 已接近饱和。据此：

| | 条数 | reasoning 开（3.0/分钟） |
|---|---|---|
| baseline 积压 | ~4,900 | ~27h ≈ **9 个 3h 夜间窗口** |
| 稳态每日新增 | ~200 | ~**1 小时** |

⚠️ **并发和 CPU 都不是提速的答案**：LLM 阶段实测 CPU 只有 **1m**（在等推理），
所以加 CPU 无用（放宽 limit 只加速一次性的归档扫描）；而并发已在饱和区，
再加只会加深排队并挤占 Open Notebook 的交互延迟。真正的杠杆是下一节的减少 token。

## 真正的提速杠杆：关掉 reasoning（`LLM_THINKING=false`）

reasoning 占了这个模型 **约 95%** 的 output token。上游 `472aaf5` 加了
`LLM_THINKING` 开关（`false` 时发 `chat_template_kwargs: {"thinking": false}`）。
实测 4 条真实岗位（DGX 空闲时）：

| | reasoning 开 | reasoning 关 |
|---|---|---|
| completion tokens | 1322 / 2019 / 175 / 451 | 82 / 55 / 54 / 45 |
| 单条延迟 | 78.8 / 134.9 / 8.0 / 20.5s | 3.2 / 5.6 / 1.9 / 2.1s |
| 平均 | **60.5s** | **3.2s（快 18.8×）** |

**质量代价小且不是单向变差**：taxonomy 映射后的 `job_tech` 有 2/4 完全一致，
两处差异都只差一项且方向相反 —— 一次多找到 reasoning 漏掉的 `mssql`，
一次漏掉 `sql`。裸输出确实更松（出现 "ship"、"hats"，来自 "wear many hats"），
但 `writeResult` 会把每个词过 `tech_taxonomy` **白名单**，没命中的进
`unmapped_tech`，**进不了 `job_tech`** —— 白名单才是真正的质量闸门。

⚠️ `reasoning_effort` 这个参数该模型**静默忽略**，只有 `chat_template_kwargs` 有效。
且默认**不发**该字段（请求体与从前逐字节一致）—— 它是 vLLM/模板专用的，
换成 Bifrost 或没有该模板的模型会被拒。

**用法定位**：只用来啃积压，不用于稳态。稳态每日约 200 条、reasoning 开着约 1 小时
就跑完，精度留着更值。清单里因此**不设** `LLM_THINKING`（= 默认开启），
啃积压走一次性 Job（不进 git，见下节）。

## 一次性积压回填

baseline 之后有约 4,900 条积压。按默认（reasoning 开）3.0 条/分钟要跑约 **9 个**夜间窗口；
用 `LLM_THINKING=false` 的一次性 Job，集群实测 **26～29 条/分钟**（约 2 小时跑完）：

⚠️ 别拿「DGX 空闲时单条 3.2s」推成 150 条/分钟 —— 8 并发照样把 DGX 推到饱和，
实际是 26～29 条/分钟。相比 reasoning 开的 3.0 条/分钟，约 **9 倍**。

```bash
# 先停掉正在跑的 enrich —— 两个进程会争同一个 SQLite 库，且读到同一份积压、
# 把每次 LLM 调用做两遍
kubectl --context k3s-homelab -n jobs-sg delete job -l job-name --ignore-not-found
# 一次性 Job：与 CronJob 同 podspec，只多一个 LLM_THINKING=false，
# 且**不带 ArgoCD 标签**（否则可能被 sync prune 掉）
kubectl --context k3s-homelab -n jobs-sg apply -f <一次性 Job yaml>
```

进度逐条落库（`enrich_cache` + `job_tech`），中途被杀不丢。跑完删掉 Job 即可，
之后每晚的 CronJob 用默认（reasoning 开）处理当天新增。

## ⚠️ 归档读取：每轮一次，不是每条一次（2026-08-03 实测教训）

这是本次上线**最大的性能坑**，也是「并发不是万灵药」的现成案例。

上游原先按每条岗位调 `mcf.ReadArchiveRecord` 读描述，而它每次都重新打开 gzip
**从头扫**。两个富化层各自独立读一遍 → 一轮成本 `2 × 岗位数 × O(归档)`。
baseline 归档是**单个文件**、88,258 条、解压 402MB，平均记录在 72% 处 →
**每条要解压约 290MB**。

集群实测：**14 分钟只处理 75 条**，CPU 死死顶在 500m limit 上；照此一轮要
**约 30 CPU 小时**，而窗口只有 3h。当时我把 `LLM_CONCURRENCY` 从 3 调到 8 想提速，
**反而更慢** —— 争的是同一份 CPU，不是网络。

上游 `738cb98` 加了 `mcf.ReadArchiveDescriptions`：按文件分组待取的记录下标，
每个文件只走一遍，且只解码 `description` 字段（不实例化整个 `Job`）；取齐即停，
停点之后的截断尾部不再算错误。`Enricher.Run` 一次性取两个 backlog（它们按不同
`job_tech.source` 过滤，故顺序无关），两层共用同一份描述表。

**效果**：同一份归档、同样数据，规则层 **75 条/14 分钟 → 4,837 条/30 秒（0 错误）**，
容器 CPU 从满载降到 ~0%，瓶颈回到它本该在的地方（推理时间）。

代价是把描述表放进内存，所以特意压过：4,900 条描述峰值 **82.5MiB**（512Mi limit 下
未 OOM，exit 0）。归档再长几倍也还有余量，但**若日后归档单文件涨到数十万条，
要重新量一次**——这是用 CPU 换内存，不是白拿。

顺带修掉了「看起来像卡死」的伪装：`enrichOne` 原本把归档读失败**静默丢弃**
（`if err != nil { return 0,0,1 }`，没有任何日志），所以归档不可读时表现为
CPU 满载、无日志、无进度 —— 和「慢」完全无法区分。现在两层都会计数并告警式记日志。

另一个误导信号：`jobs_sg_enrich_backlog` 只统计缺 `source='llm'` 的岗位，
所以**整个规则层阶段它一动不动**，看着像完全卡住。判断进度要看
`job_tech` 的 `source='llm'` 行数或 `enrich_cache`，别只看这个指标。

## 为什么用独立 ns + 独立 Application

不并进 `personal-services`：后者的 `ResourceQuota` 限死 `count/jobs.batch`，三个
CronJob 的历史 Job 会挤占那份**为 92-pod 泄漏事故加的护栏**，不该稀释。且本应用需要
kustomize 目录（`images` digest 转换器）+ `ignoreDifferences`，`directory.include`
模式不支持。

## ⚠️ 首次上线的依赖顺序（不是配置错误，别去"修"）

`web` 用 `mode=ro` 打开 `/data/jobs.db`，**文件不存在就 exit 1**（sqlite `mode=ro`
不会建库）。空 PVC 上首次部署必然 CrashLoopBackOff，直到第一次 `ingest` 建出库。
上线时手动 bootstrap 一次：

```bash
kubectl --context k3s-homelab -n jobs-sg create job ingest-bootstrap --from=cronjob/ingest
kubectl --context k3s-homelab -n jobs-sg logs -f job/ingest-bootstrap
```

首次是 baseline 全量扫描（DB 空时走 `--full-scan-pages`），实测约 400 页 / 4 万条后
被 MCF API 429 掐断；watermark 已落库，次日增量续上，**不用重跑**。

`/` 服务的是 `report/latest.html` —— 第一份周报出来前它是 404。存活探针和 Uptime Kuma
都打 `/healthz`（只验 DB 能打开），不要拿 `/` 当探针。

## 只读挂载要求 rollback journal，不能是 WAL

`web` 的 `/data` 以 `readOnly: true` 挂载。WAL 模式打开时要在数据目录建 `-shm`，
只读挂载上做不到 → `SQLITE_CANTOPEN`，web 每次启动即崩。上游 2026-08-03（`4538ba9`）
把 journal 改成 `DELETE` 并去掉只读连接上的 journal pragma，实测只读挂载可正常服务。
写入方由 cron 排期天然串行（ingest/enrich/report 不重叠），失去 WAL 并发无实际代价。

## 只读根文件系统还要一个可写 `/tmp`（否则大查询 500）

`web` 是 `readOnlyRootFilesystem: true`。SQLite 的排序/分组一旦超出 page cache 就要把
临时 b-tree 溢出到文件，unix VFS 依次试 `$SQLITE_TMPDIR` → `$TMPDIR` → `/var/tmp` →
`/usr/tmp` → `/tmp`，**全都不可写就返回 `SQLITE_IOERR_GETTEMPPATH`（扩展码 6410）**，
日志形如 `"msg":"build page","page":"overview:30","err":"disk I/O error (6410)"`，
HTTP 500。修法是挂一个 emptyDir 到 `/tmp` 并显式 `SQLITE_TMPDIR=/tmp`（见 `web.yaml`）。

⚠️ **这个坑按数据量触发，冒烟测试抓不到**：2026-08-03 上线当天逐条扫路由全是 200，
几小时后 bootstrap 全量灌进来，`/daily`（30 天聚合）和 `/daily/2026-08-03`（当天数据最多）
就双双 500，而数据量小的 `/daily/2026-08-02` 始终 200。**"上线时全绿"不等于"一直绿"**——
只读根文件系统 + SQLite 的组合，要按最大查询而不是按当时的库来验。

emptyDir 用**磁盘**不用 `medium: Memory`：tmpfs 算进容器 192Mi 内存上限，溢出几十 MB
就是 OOMKill。`sizeLimit: 256Mi` 兜住节点临时盘（homelab 是笔记本）。`/data` 仍是
`readOnly`，写隔离没有放松。

## 镜像固定

Kyverno `disallow-latest-tag` 在 homelab 是 **Enforce**，策略 digest-aware：digest 与
明确 tag 都放行，只拦 `:latest`。本应用按 digest 固定，且必须用
**manifest-list（OCI index）digest**，不是 amd64 单架构 digest —— 否则换架构拉不到。
升级只改 `kustomization.yaml` 的 `images[0].digest` 一行，命令见该文件注释。

**不启用 ArgoCD Image Updater**：集群当前 0 个 ImageUpdater CR，为一个应用引入需补
CR + git write-back 凭据，收益不抵复杂度。手动更新 digest。

## 备份口径（两条路径，缺一不可）

`local-path` 无冗余无快照，备份是强制项。`backup/overlays/homelab/backup-script.yaml`
里 jobs-sg 占**两处**：

1. **`jobs.db`（+ journal）** —— 加进第 2 步 `for pat in ... jobs-sg-data` 白名单，
   靠 `*.db*` 文件名模式捞走。
2. **`raw/` 归档** —— 第 3 步的 `JOBS_ARCHIVE_DIR` 整目录直接纳入 restic，不经 `/work`
   中转（`/work` 是 emptyDir，每晚拷一遍白吃节点临时盘）。同 oracle overlay 的
   `BOOKS_DIR` 做法。

⚠️ **只加白名单是不够的**：归档是 `raw/<date>/NNN.jsonl.gz`，`.jsonl.gz`
**匹配不上** `*.db` / `*.json` 那组模式。上游 jobs-sg `docs/04` §4 只写了加白名单一行，
照做会让最不可替代的数据静默漏备。CI 的 H4 只检查 PVC 有没有备份归属，**查不出
"归属了但模式对不上"** —— 这类只能靠实测（`restic ls` 确认 .jsonl.gz 真在快照里）。

归档为什么不可重建：MCF API 只返回**当前在架**职位，下架的永远拿不回来。

注意归档写的是**解析后**重新 marshal 的结构体（`archive.Write` 里 `json.Marshal(j)`），
不是原始响应字节 —— 这是刻意的合规取舍（`createdBy` / `emailRecipient` 等发布者个人
字段不建模、不落盘），代价是结构体没建模的字段永久丢失。

## 密钥与 Telegram 路由

**没有新的 Vault 路径，也没有需要手工写的值。** 按本仓库既有分工拆开
（同 Alertmanager / krr / falcosidekick，见
[decisions/alerting-telegram-migration.md](../decisions/alerting-telegram-migration.md)）：

| 项 | 是密钥？ | 放哪 | 值 |
|---|---|---|---|
| bot token | 是 | Vault `secret/homelab/telegram` property `bot_token` → ESO | **已存在**，与告警共用同一个 bot |
| chat id | 不是 | `cronjob-report.yaml` 明文 | `-1003981213530`（与告警**同一个群**） |
| thread id | 不是 | `cronjob-report.yaml` 明文 | **`552`** = 群里的 `jobs-sg` 话题 |

`external-secret.yaml` 只声明 `telegram-bot-token` 一个键。因为它指向的路径**已经在线
同步**（`monitoring/alertmanager-telegram` 长期 `SecretSynced=True`），所以可以直接注册。

⚠️ **历史教训（2026-08-03）**：最初我新造了一个 `secret/homelab/jobs-sg` 路径并把
ExternalSecret 直接发上去，但没人去写值 → ESO 对不存在的路径一直 `Ready=False` →
`eso-alerts.yaml` 的 `ExternalSecretNotReady`（`for: 15m`）**持续告警 40 分钟**、
ArgoCD 应用常驻 `Degraded`。`optional: true` 保住了 Pod，但保不住告警面板。
教训有两条：① 不要引用一个还没人填的 Vault 路径；② **先看现有路径够不够用** ——
这次 `bot_token` 本来就在 Vault 里，chat/thread 本来就不是密钥，压根不需要新路径。

⚠️ **ESO 的 `data` 是全有全无的**，所以只声明真正要用的键。声明了却不用的键不是惰性的，
是硬要求：曾多声明一个 `bifrost-vk`（直连 DGX 根本不用），等于逼着启用 Telegram 时
必须连一个用不到的值一起写进 Vault，否则连 bot token 都同步不了。

### 话题路由

告警与周报共用同一个群（MatthewDaily，`is_forum: true`），只靠 `message_thread_id`
区分话题：

| 话题 | thread id | 谁在用 |
|---|---|---|
| 🚨 Homelab 告警 | `2` | Alertmanager / falcosidekick / krr |
| **jobs-sg** | **`552`** | jobs-sg 周报 |
| （General） | 留空 | — |

`jobs-sg` 话题是 2026-08-03 由 bot 自己经 `createForumTopic` 建的（bot
`@matthew_daily_bot` 是群管理员且有 `can_manage_topics`，故无需人工建）。
**刻意不复用 thread 2** —— 上游 `docs/02 §4.3` 明令周报不得进告警话题。

换话题：Telegram 里右键目标话题 → 复制链接，`t.me/c/<内部 id>/<thread_id>` 的第二个
数字填进 `cronjob-report.yaml` 的 `TELEGRAM_THREAD_ID`（**一行改动，不涉及 Vault**）。
bot 也可以再建：`createForumTopic`（见 git 历史里的一次性 Job，
token 从 Secret 注入、不落日志）。

⚠️ 上游原先把该字段序列化成 JSON **字符串**（`"7"`），而 Bot API 规定 Integer。
若被忽略，就会静默投到 General 且返回 200 —— 看着完全像成功，而告警话题与内容话题
只靠这个字段区分。2026-08-03（`8259cba`）已改发数字，非数字值改为显式报错。

`TELEGRAM_BOT_TOKEN` 仍标 `optional: true`：ESO 万一没同步上，report 打一行
"telegram disabled" 后照常生成 HTML/MD，而不是 `CreateContainerConfigError` 卡住整个
Job —— 同 `backup/overlays/homelab/open-notebook-external-secret.yaml` 的取舍。

## 可观测

`web` 的 `/metrics` 暴露 `jobs_sg_*`，状态算自 DB 而非进程内存，故 web 重启不丢指标。
ServiceMonitor + PrometheusRule 都带 `release: kube-prometheus-stack` —— **漏了会被
operator 静默忽略**，指标不采、告警不生效且无任何报错。Prometheus/Alertmanager 仍在
homelab（2026-08-02 只迁了 ArgoCD/Loki/Tempo 去 oracle），故监控对象跟着落 homelab。

最重要的告警是 `JobsSgIngestStale`（增量停滞 >36h）：这类应用**静默失效比崩溃更危险**
—— 上线前实测发现的两个 bug 都属此类（见下）。

## 上线前实测发现的两个应用 bug（2026-08-03，已修）

已发布镜像跑不起来，两个缺陷都只能实测发现、测试套件看不见：

1. **`ingest` 启动即 panic** —— `cmd/ingest` 用
   `time.LoadLocation("Asia/Singapore")` 且丢弃了 error。运行镜像是 `FROM scratch`，
   没有 `/usr/share/zoneinfo` 也没 import `_ "time/tzdata"` → 返回 nil →
   `time.Now().In(nil)` panic。改用 `time.FixedZone("SGT", 8*3600)`。
2. **每页解码失败 → 一条也入不了库** —— 6 个字段被建模成 string，而 API 返回对象
   （`employmentTypes` / `salary.type` / `address.districts` /
   `flexibleWorkArrangements` / `schemes` / `_links.{self,next}`）。Page 整页解码，
   一条坏数据废掉同页 100 条。

CI 当时是绿的：`testdata/fixture/jobs.jsonl` 由 `scripts/genfixture` 从**同一批错结构体**
生成，fixture 与 bug 相互印证。修复同时加了 `internal/mcf/livedecode_test.go`，用真实
抓取的响应（已剥离个人字段）做断言，结构体再漂移就在 CI 挂而不是在生产。

修复提交 `2d7b9ad`。**别回滚到 `2d7b9ad` 之前的镜像** —— 它们的 ingest 一律 panic。

## 上线实测基线（2026-08-03）

首次 bootstrap 的真实数字，可当容量与告警阈值的参考：

| 指标 | 值 |
|---|---|
| baseline 全量扫描 | **884 页 / 88,258 seen / 29 分钟 / 0 错误** |
| 入库候选岗位 | **9,499**（`seen` 远大于 `new`：只有候选岗位入库） |
| 首份周报 | 2026-W31，1,301 条新岗，生成耗时 6s |
| enrich 积压（baseline 后） | ~4,900（SWE 子集） |
| enrich 规则层（修复后） | **4,837 条 / 30 秒 / 0 错误**（修复前 75 条 / 14 分钟） |
| enrich 归档扫描（集群内，500m limit） | 约 150s，一次性；CPU 顶满，之后降到 ~1m |
| 单条 LLM 抽取 | **66.5s**（真实描述；短 prompt 约 15s，别用它规划容量） |
| 节点容量 | 8 核 / 7600m allocatable，idle 用量约 9%、requests 合计 27% |

⚠️ 别按「库里岗位数 ÷ 100」估页数 —— `seen`（88k）远大于 `new`（9.5k），按后者算会把
全量扫描的耗时高估近一个数量级（`activeDeadlineSeconds: 3600` 实际很宽裕，29 分钟就跑完）。

## 已知缺口

- `classify.WorkMode` 只匹配 `remote`/`hybrid`/`onsite`，而 MCF 的真实标签是
  "Creative Scheduling"、"Flexi-place" 之类 → 目前所有职位的 `work_mode` 都是 `Onsite`。
  属分类法缺口，非解码错误。
- Grafana 面板未做（`jobs_sg_*` 指标已在采，用 Explore 可查）。
- 恢复演练未做：实际 restore + `PRAGMA integrity_check` 应作为下一步 DoD。
