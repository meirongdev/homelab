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
| 密钥 | Vault `secret/homelab/jobs-sg` → ESO → `jobs-sg-secrets` |

四个二进制、一个镜像：`ingest`（抓取）、`enrich`（技术栈富化）、`report`（周报 +
Telegram）、`web`（只读服务 + `/metrics`）。三个 CronJob + 一个 Deployment。

| 组件 | 触发 | 说明 |
|---|---|---|
| `ingest` | 每日 18:15 UTC（02:15 SGT） | 增量；程序按 SGT 判断周日自动转全量 reconcile |
| `enrich` | 每日 19:10 UTC | 规则 + LLM（**直连 DGX vLLM**）；fail-open |
| `report` | 周一 01:00 UTC（09:00 SGT） | 出 HTML/MD + 推 Telegram |
| `jobs-sg-web` | 常驻 | 只读挂载 PVC，服务周报 + Prometheus 指标 |

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
**切回 Bifrost**：`LLM_BASE_URL` 改回 `http://bifrost.bifrost.svc.cluster.local:8080`
并删掉 `LLM_MODELS`（默认链即 Bifrost 形式），再往 Vault 写 `bifrost-vk`。

**吞吐**：实测单条抽取约 **15s**（deepseek 的 reasoning 占了大部分 output token）。
baseline 之后积压约 4900 条 → 并发 3 要 ~7h，装不进 1h 的 deadline，故设
`LLM_CONCURRENCY=8` + `activeDeadlineSeconds: 10800`（3h）。稳态每日增量只有几百条
（约 7 分钟）。**并发别再往上加** —— DGX 是共享机器，不是专属算力。
`enrich_cache` 按 `description_sha256` 去重，转岗重发的帖子不重复计费。

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

## 密钥

Vault `secret/homelab/jobs-sg`，四个 property：

**当前这四个键都还没写** —— 所以 `jobs-sg-secrets` 处于 `SecretSyncedError`，
这是**已知且可接受**的状态：`optional: true` 让 Pod 照常跑。现状影响只有一条：
**周报不推 Telegram**（HTML/MD 照常生成，站点照常服务）。
LLM 富化不受影响 —— 它直连 DGX，不用 `bifrost-vk`（见上）。

| property | 用途 | 缺失时 |
|---|---|---|
| `bifrost-vk` | 仅在切回 Bifrost 时需要；直连 DGX 时不用 | 无影响（当前直连 DGX） |
| `telegram-bot-token` | 周报推送 | report 打 "telegram disabled"，仍出 HTML/MD |
| `telegram-chat-id` | 群 ID（`-1003981213530`） | 同上 |
| `telegram-thread-id` | 话题 ID；**空 = 群的 General 话题** | 同上 |

⚠️ **ESO 的 `data` 是全有全无的**：Vault 里缺任何一个 property，整个 `jobs-sg-secrets`
同步失败。四个键必须都存在（`telegram-thread-id` 允许是空串）。消费侧的
`secretKeyRef` 全部标了 `optional: true`，所以 Vault 还没写时 Pod 照常启动并降级，
而不是 `CreateContainerConfigError` 卡住流水线 —— 同
`backup/overlays/homelab/open-notebook-external-secret.yaml` 的取舍。

Bifrost virtual key 只能在 Bifrost UI 建（持久化在其 PVC 的 SQLite，**不在 git**），
再手工写进 Vault。集群内走 `bifrost.bifrost.svc` 同样要带 VK —— governance PreHook
在入口之前生效，绕不过去。

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
| 单条 LLM 抽取 | ~15s（DGX deepseek-v4-flash） |

⚠️ 别按「库里岗位数 ÷ 100」估页数 —— `seen`（88k）远大于 `new`（9.5k），按后者算会把
全量扫描的耗时高估近一个数量级（`activeDeadlineSeconds: 3600` 实际很宽裕，29 分钟就跑完）。

## 已知缺口

- `classify.WorkMode` 只匹配 `remote`/`hybrid`/`onsite`，而 MCF 的真实标签是
  "Creative Scheduling"、"Flexi-place" 之类 → 目前所有职位的 `work_mode` 都是 `Onsite`。
  属分类法缺口，非解码错误。
- Grafana 面板未做（`jobs_sg_*` 指标已在采，用 Explore 可查）。
- 恢复演练未做：实际 restore + `PRAGMA integrity_check` 应作为下一步 DoD。
