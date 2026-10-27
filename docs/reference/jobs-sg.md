# jobs-sg — 新加坡 SWE 岗位趋势周报（架构事实）

> Last updated: 2026-10-28
> Status: 生效事实
> Scope: jobs-sg 在 homelab 集群的部署形态、镜像固定方式、备份口径、首次上线依赖顺序
> 本文是 source of truth。应用代码在 [meirongdev/jobs-sg](https://github.com/meirongdev/jobs-sg)。

## 速览

- **在哪**：homelab 集群独立 ns `jobs-sg`，`jobs.meirong.dev`（无认证，公开统计）。
  一个镜像里 6 个二进制：4 个管线阶段（ingest / enrich / report / web）= 3 个 CronJob
  + 1 Deployment；另外 2 个是运维工具、**没有任何 CronJob 跑**，手动起一次性 Job
  （`reclassify` 重算分类、`retech` 重算规则层技术栈，都默认 dry-run）。
- **跑什么**：每日抓 SG 岗位 → 规则 + LLM 富化（直连 DGX，fail-open）→ 周报推 Telegram；
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
| `enrich` | 每日 19:10 UTC | 规则 + LLM（**直连 DGX vLLM**）；fail-open |
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

诊断见 [plans/2026-08-08-jobs-sg-three-defect-diagnosis.md](../plans/2026-08-08-jobs-sg-three-defect-diagnosis.md)。

## LLM 富化：直连 DGX，不经 LLM 网关

`enrich` 的 `LLM_BASE_URL` 指向 DGX 推理引擎 `http://100.97.87.120:8000`（Tailscale IP，pod
直连，无需认证；同一台机器也给 Open Notebook 供模型），所以不需要网关的 virtual key，少一条
Vault 依赖。DGX 栈本身（模型、端口、引擎、档位）的唯一真相源是
[litellm-gateway.md](litellm-gateway.md) 的「DGX 主力栈」；换栈照
[runbooks/dgx-model-swap-homelab-followup.md](../runbooks/dgx-model-swap-homelab-followup.md) 走。

- ☠️ 因为是**直连**，git 里那份网关清单帮不上忙：换栈只有 `LLM_BASE_URL` + `LLM_MODELS` 跟着改
  才有效。只改模型名不改端口，等于把作业指向空端口。
- ⚠️ 模型 id 是后端相关的：网关路由用带前缀的 `custom_dgx/qwen3.8-flash-next-tp2`，裸引擎是
  `qwen3.8-flash-next-tp2`，写前缀名会 404（vLLM 对错名回 404）。
- ☠️ 直连时思维链在 `message.reasoning`，`reasoning_content` **恒为空**（经网关时 LiteLLM 才改写
  成 `reasoning_content`）。拿 `reasoning_content` 长度判「思考关没关」会恒读到 0，与真关掉同形。
  判据是 `usage.completion_tokens_details.reasoning_tokens`（关思考时为 0）。

enrich 要模型回严格 JSON（上游 `ExtractPrompt`，六个 key），换模型要连这条一起验。

模型相关参数全部是 `LLM_*` 环境变量（上游 `internal/llm/config.go` 一处解析）：
`LLM_BASE_URL / LLM_MODELS / LLM_TIMEOUT / LLM_CONCURRENCY / LLM_RETRIES / LLM_THINKING /
LLM_THINKING_KWARG / LLM_MAX_TOKENS / LLM_MAX_DESC_CHARS / LLM_PROMPT / LLM_PROMPT_VERSION /
LLM_API_KEY / LLM_AUTH_HEADER / LLM_EXTRA_BODY`。换模型不改代码、不发版；参数写错只丢那一个
旋钮并打告警，启动日志 `llm enabled` 打的是生效值。全表与调参口径在上游
`docs/09-deploy-runbook.md` §3.2/§5，本文只留 homelab 的取值与理由。

换模型的验收（在 jobs-sg 仓库根目录跑，默认跳过、不进 CI）：真调一次并断言推理确实被关掉，
挂了就换 `LLM_LIVE_KWARG` 试。当前栈 2026-10-04 PASS，即 `LLM_THINKING_KWARG` 保持默认值。

```sh
LLM_LIVE_URL=http://100.97.87.120:8000 LLM_LIVE_MODEL=qwen3.8-flash-next-tp2 go test ./internal/llm -run Live -v
```

**取舍**：不经网关就没有网关的回退，也没有用量计量；DGX 是跨 tailnet 共享的境内机器
（RTT 66–83ms），不可用时 enrich fail-open 退回纯规则。改走网关要改 `LLM_BASE_URL`、删
`LLM_MODELS`、声明对应的 key（见 `cronjob-enrich.yaml` 注释）。

### 耗时、超时与并发

- 单次调用（上游 2026-09-03 用 16 条真实岗位、并发 8 实测，当时是 qwen38-flash-next）：开推理
  均值 18.7s、最坏 58.7s、15 条/分钟；`LLM_THINKING=false` 是 2.8s / 6.1s / 154 条/分钟。
  本仓库整轮实测 6.9 条/分钟（242 次调用 / 35 分钟）。两个数口径不同（抽样 vs 整轮、共享 GPU
  上还有别的租户），别互相替换。
- ⚠️ 小样本测不出尾巴：封顶前生产约 1.3% 的调用超过 300s。判断要不要干预看这个比例，不看抽样
  最坏值；短 prompt（约 15s）更不能拿来规划容量。
- `LLM_TIMEOUT=300`。该端点非流式，生成完才回 header，所以预算覆盖整个生成过程（报错里的
  "awaiting headers" 极具误导性）；客户端放弃不会让服务端停止生成，每次超时还白耗一次共享 GPU。
  ☠️ 超时值别卡在真实耗时下面：只有短帖侥幸跑完，表现像「慢」不像「坏」。
- 进度逐条落库，中途被 deadline 杀掉不丢；`enrich_cache` 按 `description_sha256` 去重。
  baseline 积压 2026-09-03 前已排空。
- ⚠️ 并发和 CPU 都不是提速的答案：LLM 阶段 CPU 只有 1m（在等推理），加 CPU 只加速一次性的归档
  扫描；旧模型实测 8× 并发只换来 3.3× 吞吐，DGX 已接近饱和，再加只会加深排队并挤占 Open Notebook。
  清单的 `LLM_CONCURRENCY=8` 高于引擎 KV 池实测的 `kv_cache_max_concurrency=5.34`，降到 5 是否
  更好未实测不改（待办在 [ROADMAP.md](../ROADMAP.md)）。真正的杠杆是减少 token（下两节）。

## 真正的提速杠杆：关掉 reasoning（`LLM_THINKING=false`）

reasoning 占这类模型约 95% 的 output token。`LLM_THINKING=false` 时发 `chat_template_kwargs`，
键名是 `LLM_THINKING_KWARG`，默认 `enable_thinking`（当前栈实测生效）。

- ☠️ 旧键名 `{"thinking": false}` 回 200 但**静默**不生效。设了 `LLM_THINKING=false` 而模型仍在
  推理时，客户端每进程打一条 `reasoning was not disabled` 的 WARN，并点名要改的键。
- 旧栈上 4 条真实岗位实测：平均 60.5s → 3.2s（18.8×），completion token 降一个数量级。键名别照抄
  旧栈，倍率可参考。
- 质量代价小且不是单向变差：裸输出更松（"wear many hats" 会抽出 "hats"），但每个词都过
  `tech_taxonomy` 白名单，没命中的进 `unmapped_tech`、进不了 `job_tech`。白名单才是质量闸门。
- **用法定位**：只用来啃积压，不用于稳态。清单不设它（= 开推理），啃积压走下一节的一次性 Job；
  稳态用封顶。

## 一次性积压回填

当前无积压，需要时照这个做。实测 26–29 条/分钟：8 并发照样把 DGX 推满，别拿「DGX 空闲时单条
3.2s」推成 150 条/分钟。

```bash
# 先停掉正在跑的 enrich：两个进程会争同一个 SQLite 库，且读到同一份积压、把每次 LLM 调用做两遍
kubectl --context k3s-homelab -n jobs-sg delete job -l job-name --ignore-not-found
# 一次性 Job：与 CronJob 同 podspec，只多一个 LLM_THINKING=false，
# 且不带 ArgoCD 标签（否则可能被 sync prune 掉）
kubectl --context k3s-homelab -n jobs-sg apply -f <一次性 Job yaml>
```

进度逐条落库，中途被杀不丢。跑完删掉 Job，之后每晚的 CronJob 用默认（开推理）处理当天新增。

## 稳态旋钮：给推理封顶（`LLM_EXTRA_BODY` + `reasoning_effort`）

清单写 `LLM_EXTRA_BODY={"reasoning_effort":"medium"}`。推理模型会在个别长岗位上把推理写飞
（生成长度双峰：正常 1000–2000 token、跑飞 >7000，是触发了循环），这是 enrich 记 partial 的
常态成因。

- ☠️ partial 了起手别查「DGX 是不是慢了」：先比每输出 token 耗时、排队、抢占这些引擎读数与前夜
  有没有变，没变就是跑飞。
- 生效的是顶层 `reasoning_effort`：它关不掉推理，但能封顶。`chat_template_kwargs` 里的推理预算键
  （`thinking_budget` / `reasoning_max_tokens` / `max_thinking_tokens`）**静默**无效。
- 当前栈档位 `low` / `medium` / `xhigh`（默认），`minimal`、`high` 回 400。默认档是 `xhigh`，
  封顶键不能省。⚠️ 失效形态是整轮 400 全挂，不是悄悄不生效；档位集合每次换栈都变过，换栈后先核。
- 经 LiteLLM 网关也能传，但裸别名上传错档位会被兜底吞掉、换模型回 200（见
  [litellm-gateway.md](litellm-gateway.md)）。本作业直连，不受影响。
- 封顶只能封推理。调大 `LLM_TIMEOUT` 没用（生成长度没有上界，`max_model_len` 262144）；
  `LLM_MAX_TOKENS` 更糟，模型先把推理写满、`content` 返回 null，慢成功变硬失败，清单刻意不设。
- 封顶效果是在 qwen38-flash-next 上测的（前夜超时的 5 条全部 8–22s 完成，8 条正常岗位合计
  244s → 82s、抽词几乎不变）；当前栈只在短题上看过推理变短，真实提示词没重测。
- `LLM_RETRIES=0`，理由是封顶后本来就不该有超时。⚠️ 别写成「重试几乎没用」：同一岗位每次都是
  重新抽签（`temperature: 0` 挡不住连续批处理的抖动），超时的岗位隔天重跑 76% 一次过。若封顶后
  仍有残留超时，改成 1 是便宜的保险（待办在 [ROADMAP.md](../ROADMAP.md)）。

经过与数值见 [records/2026-09-04-jobs-sg-enrich-runaway-reasoning.md](../records/2026-09-04-jobs-sg-enrich-runaway-reasoning.md)。

## 归档读取：每轮一次，不是每条一次

上游 `738cb98` 起 `mcf.ReadArchiveDescriptions` 按文件分组待取的记录，每个文件只走一遍、只解码
`description`，取齐即停；两个富化层共用同一份描述表。

- ☠️ 别回滚到 `738cb98` 之前的镜像：按每条岗位从头扫 gzip，一轮约 30 CPU 小时，窗口只有 3h。
- 代价是描述表进内存：4,900 条描述峰值 82.5MiB（enrich 512Mi limit）。归档单文件涨到数十万条时
  要重新量，这是用 CPU 换内存。
- 归档读失败会计数并记日志。若再出现「CPU 满载、无日志、无进度」，先怀疑归档读取。
- ⚠️ 看进度别只看 `jobs_sg_enrich_backlog`：它只数 LLM 层未处理的岗位（缺 `source='llm'` 行
  **且**缺 `enrich_done` 标记），整个规则层阶段它一动不动。看 `job_tech` 的 `source='llm'` 行数
  或 `enrich_cache`。

`enrich_done` 记「这层跑过」：LLM 结果全落 `unmapped_tech` 的岗位也写标记，否则会永留积压
（`llm_cached ≈ backlog` 是这个病的指纹）。

## 镜像固定

Kyverno `disallow-latest-tag` 在 homelab 是 Enforce，策略 digest-aware（digest 与明确 tag 放行，
只拦 `:latest`）。本应用按 digest 固定，且必须用 **manifest-list（OCI index）digest**，不是
amd64 单架构 digest，否则换架构拉不到。升级只改 `kustomization.yaml` 的 `images[0].digest`，
命令见该文件注释。没有镜像自动升级（ArgoCD Image Updater 已退役，见
[argocd-app-patterns.md](argocd-app-patterns.md)），digest 手动改。

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

没有新的 Vault 路径，也没有需要手工写的值。按本仓库既有分工拆开（同 Alertmanager / krr /
falcosidekick，见 [decisions/alerting-telegram-migration.md](../decisions/alerting-telegram-migration.md)）：

| 项 | 是密钥？ | 放哪 | 值 |
|---|---|---|---|
| bot token | 是 | Vault `secret/homelab/telegram` property `bot_token` → ESO | 已存在，与告警共用同一个 bot |
| chat id | 不是 | `cronjob-report.yaml` 明文 | `-1003981213530`（与告警同一个群） |
| thread id | 不是 | `cronjob-report.yaml` 明文 | `552` = 群里的 `jobs-sg` 话题 |

- `external-secret.yaml` 只声明 `telegram-bot-token` 一个键，指向的路径一直在线同步
  （`monitoring/alertmanager-telegram` 同用）。
- ⚠️ **ESO 的 `data` 是全有全无的**：只声明真正要用的键。多声明一个没人写值的键（比如直连 DGX
  根本用不到的 virtual key），连 bot token 都同步不了。
- ⚠️ 别引用还没人填的 Vault 路径：ESO `Ready=False` → `ExternalSecretNotReady` 持续告警、App 常驻
  `Degraded`。先看现有路径够不够用。
- `TELEGRAM_BOT_TOKEN` 标 `optional: true`：ESO 没同步上时 report 打一行 "telegram disabled"
  后照常生成 HTML/MD，而不是 `CreateContainerConfigError` 卡住整个 Job（同
  `backup/overlays/homelab/open-notebook-external-secret.yaml` 的取舍）。

### 话题路由

告警与周报共用同一个群（MatthewDaily，`is_forum: true`），只靠 `message_thread_id` 区分话题：

| 话题 | thread id | 谁在用 |
|---|---|---|
| 🚨 Homelab 告警 | `2` | Alertmanager / falcosidekick / krr |
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
- 历史周的 `active_jobs` 无法按出版时点重建（as-of 查询未实现），见「重算历史周」。
- 手动 kill enrich/ingest Job 会留下孤儿 `running` 行（只写了 StartRun，`ended_at` 为 NULL）。
  确认集群无活跃 run 后，在 PVC 所在节点上先备份 `jobs.db`，再执行
  `DELETE FROM ingest_run WHERE status='running' AND ended_at IS NULL`。

## 重放归档重算分类（`jobs-sg-reclassify`）

分类结论（`is_swe` / `role_family` / `seniority` / `work_mode` / `company_type`）是 ingest 当时
算好存在行上的。修了分类器，只有管线再次看见的岗位会被修正，已下架的岗位永远保留错误结论。
分类规则是归档 JSON 的纯函数，所以整段历史可以离线重算：零 API 调用，覆盖每一条归档过的岗位
（含已下架）。强制 reconcile 要约 867 页 × 1.5s、20–25 分钟，且只覆盖还在架的。

```sh
# 1) 先 dry-run：只报告 old->new 迁移矩阵，不写库
kubectl --context k3s-homelab -n jobs-sg create job reclassify-dry --dry-run=client -o yaml \
  --image=ghcr.io/meirongdev/jobs-sg@sha256:<当前digest> -- \
  /usr/local/bin/jobs-sg-reclassify --data-dir /data > /tmp/j.yaml
# 补上 PVC 挂载后 apply（PVC: jobs-sg-data，挂 /data，可写）
# 2) 看完矩阵再决定是否加 --apply 重跑一次
```

1. 默认 dry-run，`--apply` 才写。`is_swe` 的增减移动的是所有指标的统计口径，先看矩阵。
2. ☠️ 只写派生列。`closed_at` / `last_seen_at` / `first_seen_at` / `miss_count` 在 SQL 里不出现：
   重放归档说明不了岗位是否还在架，碰 `last_seen_at` 会悄悄撤销一次关闭。
3. 归档里有、库里没有的 uuid 只计数不插入（没有诚实的 `first_seen_at` 可填）。这个计数就是
   「partial 那几轮漏了几条」的答案。
4. 不重跑 LLM，也不动技术栈；`job_tech` 用 `retech`。

## 重放规则层重算技术栈（`jobs-sg-retech`）

enrich 的积压口径是 `NOT EXISTS job_tech AND NOT EXISTS enrich_done`，做过的永远不重算。所以改了
`tech_taxonomy` 别名表或匹配逻辑，已富化的岗位保留旧结论，`/tech`、`/pay` 和周报的技术栈趋势
一直错着。`retech` 扫归档、用当前别名表重算规则层、重写 `job_tech`：零 API 调用，只碰
`source='rule'`（`source='llm'` 没有模型重放不出来，读都不读）。

```sh
# 1) dry-run：报告哪些 slug 增减了多少条，不写库
kubectl --context k3s-homelab -n jobs-sg create job retech-dry --dry-run=client -o yaml \
  --image=ghcr.io/meirongdev/jobs-sg@sha256:<当前digest> -- \
  /usr/local/bin/jobs-sg-retech --data-dir /data > /tmp/j.yaml
# 补上 PVC 挂载后 apply（PVC: jobs-sg-data，挂 /data，可写）
# 2) 看完增减再决定是否加 --apply 重跑一次
```

1. 默认 dry-run，`--apply` 才写。dry-run 真的只读（replay 的是代码里的 `store.TechSeeds()`）；
   `--apply` 才跑 `Seed()` 把表也收敛掉（每晚 enrich 读的是表，表里留着退役别名，新岗位照样命中）。
2. 报告里的变化不都是规则造成的：重放用最后一次归档的文本，描述改过的岗位也会进 diff。判据：
   规则改动一次动几百条，描述编辑是长尾的单条。
3. `enrich_done` 只补不盖：已有标记绝不重新盖时间戳；缺的必须补上（早于 `enrich_done` 表富化的
   岗位，`job_tech` 行就是「这层跑过」的唯一证据，清空它就掉回积压）。
4. ⚠️ 判 rule 层积压别看 `jobs_sg_enrich_backlog`（只数 LLM 层），自己查
   `NOT EXISTS job_tech(source='rule') AND NOT EXISTS enrich_done(source='rule')`。

### 重算历史周（`report --week`）

`weekly_metric` 是物化的，retech/reclassify 都不碰，历史周要逐周 `report --week`。

- ⚠️ 用**不带 Telegram env 的 Job**：推送是 env-driven、unset 即跳过，而
  `--from=cronjob/report` 会把 env 一起抄过来，等于把历史周报重推一遍进 Telegram。
- ☠️ `report --week` 无条件把 `latest.html` / `index.html` 覆写成那一周。重算完旧周必须把最新周的
  HTML 复制回去，否则「最新周报」倒退。
- ☠️ `active_jobs`（"On the board at publication"）重算出来是「重算当日」快照：SQL 是
  `closed_at IS NULL AND expiry_date >= 周末`，而 `closed_at` 只反映今天。重算会覆盖历史真值且
  无快照可复原，别随手重算历史周。
- 判旧周是否已按新口径：查对应 `week_start` 的 `weekly_metric.computed_at` 是否晚于修复的部署时间。

2026-08-24/26 已对全表跑过 `reclassify --apply`、`retech --apply`，W31–W34 已逐周重算，过程见
[records/2026-08-24-jobs-sg-tech-alias-false-positives.md](../records/2026-08-24-jobs-sg-tech-alias-false-positives.md)。

## 别名表（`tech_taxonomy`）的规则

规则层是纯文本词边界匹配，分不清词义。

- 别名同时是普通英文词（`express`、`go`）时加**词义门**：只在技术枚举上下文里算命中（一侧紧邻
  `( , / ; [` 或 `) . ]` 等分隔符）。门有代价（漏掉 "Node.js Express REST APIs" 这种散文里的真
  命中），只给实测精度差的加；`spark`、`node`、`swift` 刻意不加。
- ☠️ `Seed()` 会删掉表里不在 seed 列表的别名：手工 `INSERT` 进 `tech_taxonomy` 的别名会被下一次
  ingest/enrich 清掉，加别名只能改代码。
- 改别名表修不了历史，要跑 `retech`。

### 判一个别名准不准：拿 LLM 层当对照，不用人工判

规则层和 LLM 层是两套独立方法看同一批 JD，两层命中集合的 Jaccard 重合度就是免标注的精度代理。
健康区间约 79–92%（2026-08-24 全量实测：`python` 91.9%、`kubernetes` 85.7%、`spark` 78.7%；
加门后的 `go` 78.7%、`expressjs` 77.2%）。新增或怀疑一个别名时先看这个数，明显低于 79% 就去看
命中上下文。

## work_mode 的口径：Unknown 是一等状态

MCF 的 `flexibleWorkArrangements` 回答的是什么时候上班，不是在哪上班：500 条全行业样本里只有
7.4% 带这个字段，唯一的地点信号 `Telecommuting` 占 0.6%，其余是 `Flexi-Hours` 之类的排班值。

- 只有地点类 arrangement 产生结论（`Telecommuting`→Remote、`Flexi-Place`→Hybrid），排班类一律不
  产生，没有地点信号就是 `Unknown`。看到「Unknown 占九成」不是故障，是数据源只知道这么多。
- ⚠️ 换镜像不会立刻改变页面：`work_mode` 由 ingest 的 upsert 重写，web 只读，要等下一轮抓取；
  周日 reconcile 走全 board，一次刷新所有在架岗位；已下架的要 `reclassify`。
- 生产库全表 0 条 `Onsite`（2026-08-24 `reclassify --apply` 后），W31–W34 已按新口径重算。

诊断见 [plans/2026-08-08-jobs-sg-three-defect-diagnosis.md](../plans/2026-08-08-jobs-sg-three-defect-diagnosis.md) §3。

## 相关记录

- [records/2026-08-03-jobs-sg-launch-defects.md](../records/2026-08-03-jobs-sg-launch-defects.md)：
  上线当天的七个缺陷，含上线实测基线
- [records/2026-08-05-jobs-sg-daily-partial.md](../records/2026-08-05-jobs-sg-daily-partial.md)
- [records/2026-08-09-jobs-sg-reconcile-never-succeeded.md](../records/2026-08-09-jobs-sg-reconcile-never-succeeded.md)
- [records/2026-08-24-jobs-sg-tech-alias-false-positives.md](../records/2026-08-24-jobs-sg-tech-alias-false-positives.md)（含历史重放）
- [records/2026-09-04-jobs-sg-enrich-runaway-reasoning.md](../records/2026-09-04-jobs-sg-enrich-runaway-reasoning.md)
- [plans/2026-08-08-jobs-sg-three-defect-diagnosis.md](../plans/2026-08-08-jobs-sg-three-defect-diagnosis.md)：
  `closed` 恒为 0、`JobsSgReconcileStale` 盲点、work_mode
