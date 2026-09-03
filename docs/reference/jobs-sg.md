# jobs-sg — 新加坡 SWE 岗位趋势周报（架构事实）

> Last updated: 2026-09-03
> Status: 生效事实
> Scope: jobs-sg 在 homelab 集群的部署形态、镜像固定方式、备份口径、首次上线依赖顺序
> 本文是 source of truth。应用代码在 [meirongdev/jobs-sg](https://github.com/meirongdev/jobs-sg)。

## 速览

- **在哪**：homelab 集群独立 ns `jobs-sg`，`jobs.meirong.dev`（无认证，公开统计）。
  一个镜像里 6 个二进制：4 个管线阶段（ingest / enrich / report / web）= 3 个 CronJob
  + 1 Deployment；另外 2 个是运维工具、**没有任何 CronJob 跑**，手动起一次性 Job
  （`reclassify` 重算分类、`retech` 重算规则层技术栈，都默认 dry-run）。
- **跑什么**：每日抓 SG 岗位 → 规则 + LLM 富化（直连 DGX，fail-open）→ 周报推 Telegram；
  页面全部随请求渲染（`/`、`/tech`、`/pay`、`/companies`、`/ops`）。
- **备份两条路径，缺一不可**：`jobs.db` 走白名单 `*.db*`；`raw/*.jsonl.gz` 单独纳 restic，
  只加白名单会静默漏备（H4 查不出）。
- **首次上线依赖顺序**：见 § 依赖顺序，那不是配置错误，别去"修"。
- **已知缺口**：见文末「已知缺口」。

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

⚠️ **`web` 监听两个端口**（2026-08-08 起）：`8080` 服务公共站点、`9090` 只服务
`/metrics`（`--metrics-addr`）。HTTPRoute 只指向 8080，所以
`https://jobs.meirong.dev/metrics` **必须是 404**，那是端口拆分生效的判据。
ServiceMonitor 抓的是 Service 的 `port: metrics`，**改名或改回 `http` 都会静默不抓**。

| 组件 | 触发 | 说明 |
|---|---|---|
| `ingest` | 每日 18:15 UTC（02:15 SGT） | 增量；程序按 SGT 判断周日自动转全量 reconcile |
| `enrich` | 每日 19:10 UTC | 规则 + LLM（**直连 DGX vLLM**）；fail-open |
| `report` | 周一 01:00 UTC（09:00 SGT） | 出 HTML/MD + 推 Telegram |
| `jobs-sg-web` | 常驻 | 只读挂载 PVC，服务周报 + 抓取统计 + Prometheus 指标 |

对外路由（2026-08-08 升级后重排，`/` 与 `/daily` 都换了含义；全部实测 200，耗时见
下文「聚合页的 5s 预算」）：

| 路径 | 内容 |
|---|---|
| `/` | **实时市场快照**（随请求渲染），不再是周报，也不再有「第一份周报前 404」 |
| `/tech` | 技术栈榜与动量（历史不足 5 周时显示「需 5 周历史」，是一等状态不是空图） |
| `/pay` | 薪资分位与溢价（样本不足的格子显示 `—(n=3)`，刻意抑制而非伪精度） |
| `/companies` | 雇主、在架时长、竞争度 |
| `/reports` | 最新周报（原来的 `/`） |
| `/w/{YYYY-Www}` | 指定周的周报 |
| `/ops` | 每日抓取统计：按 SGT 日历日一行（run 类型/状态/页数/归档数/新增/SWE/错误/LLM 调用） |
| `/ops/{YYYY-MM-DD}` | 当日下钻：逐 run 记录、角色与资历分布、技术栈、当天首见岗位（上限 200） |
| `/daily`、`/daily/{date}` | **301 → `/ops`**（兼容旧链接；新地方别再写旧路径） |
| `/healthz` | 只验 DB 能打开，存活探针与 Uptime Kuma 用这个 |
| `/robots.txt` | — |
| ~~`/metrics`~~ | **公网 404**；只在集群内 `svc/jobs-sg-web:9090` 可达 |

`/`、`/tech`、`/pay`、`/companies`、`/ops` 全是随请求渲染（不经 CronJob 落文件）：
ingest 约 02:20 SGT 落地，数字必须当场就是最新的。周报仍是静态文件，它要归档、
要推 Telegram。

⚠️ 数据量涨上来后，聚合页需要可写 `/tmp` 才不 500，见下文「只读根文件系统还要一个
可写 `/tmp`」。

## LLM 富化：直连 DGX，不经 LLM 网关

`enrich` 的 `LLM_BASE_URL` 指向 **DGX Spark vLLM `http://100.97.87.120:8000`**
（Tailscale IP，pod 直连；同一台机器也在给 Open Notebook 供模型）。这样**完全不需要
LLM 网关的 virtual key**，也就少了一条 Vault 依赖。

⚠️ **模型 id 是后端相关的**：LLM 网关路由用带 provider 前缀的名字
（`custom_dgx/qwen38-flash-next`），裸 vLLM 提供的是 `qwen38-flash-next`，写前缀名
会 404。上游原先把模型链**硬编码**成网关形式，2026-08-03（`d833623`）才改成读
`LLM_MODELS` / `LLM_CONCURRENCY` 环境变量（默认仍是网关链，不破兼容）。

实测（2026-08-03，`jobs-sg` ns 内的 pod）：DGX 可达、**无需认证**、`x-bf-vk` 头被
vLLM 忽略；当时的模型 `deepseek-v4-flash`（1M ctx）返回的正是 enrich 要的严格 JSON。

☠️ **2026-09-02 DGX 换了主力模型**（`deepseek-v4-flash` → `qwen38-flash-next`，
ctx 1M → 262144，旧名已从 `/v1/models` 消失 → 旧配置是 404）。因为本作业**直连** DGX，
git 里那份网关清单帮不上忙，只有 `LLM_MODELS` 跟着改才有效。模型事实见
[litellm-gateway.md](litellm-gateway.md) 的「DGX 主力模型」。
⚠️ 新模型**尚未按 enrich 的提示词复测严格 JSON**（只验过 tool call 与补全可用），
换栈后第一轮跑完要看有多少条目 fail-open 退回规则结果。
✅ 严格 JSON 这条契约已在新模型上复验（2026-09-03，直接打网关、用仓库里那份
`ExtractPrompt`）：三种参数（默认 / `{"thinking":false}` / `{"enable_thinking":false}`）
都回合法 JSON 且六个 key 齐全，reasoning 分别是 142 / 134 / 0。
☠️ 由此暴露一条**上游仓库的坑**：`OpenAIExtractor.DisableThinking` 发的 kwargs 名是
`thinking`（旧栈的形状），**在新栈上是静默空操作** —— `{"thinking":false}` 的 reasoning
是 134，与基线 142 同量级，而 `{"enable_thinking":false}` 才是 0。三种写法都回 200，
所以**只能拿 `usage.completion_tokens_details.reasoning_tokens` 判**，请求成功不是证据。
默认没发这个字段，线上行为未变；清积压时按它跑不提速，只是多烧 token
（本次 n=1 短输入：170 vs 26 completion token，约 6 倍；旧栈那批 4 条真实岗位的历史
实测是 18.8 倍，见上游 `internal/llm/client.go` 注释）。
`internal/llm/thinking_test.go` 断言的也是 `thinking` 这个键 —— 改名要在 jobs-sg 仓库做。

**取舍**：省掉 VK 与 Vault 依赖，但没有 LLM 网关的 `custom_m2` 回退，也没有用量计量；
DGX 是跨 tailnet 共享的境内机器（RTT 66–83ms），不可用时 enrich fail-open 退回纯规则。
（此前“切回网关”的三处改法已随 **LLM 网关 2026-08-08 退役**一并失效，直连 DGX
是当前唯一形态，后续换 LLM 网关时另行规划。）

**单次调用实测 66.5s**（2,326 字描述 / 497 prompt tokens / 937 completion tokens，
reasoning 占大头）。短 prompt 只要 15s，别拿短 prompt 的数字做容量规划。
⚠️ 这组数字（含 300s 超时、6.5 条/分钟、每晚排空 ~1100 条）是**旧模型**测的：新栈
prefill 快约一倍、decode 略慢、并发上限更高，2026-09-02 换栈后第一轮要重测再回校。
本轮复验只用了短输入（fixture 最长一条描述仅 66 字符），**长描述的端到端耗时没在这里测**，
别拿 66 字符那次的秒数当容量依据。

⚠️ **超时值曾经卡在真实耗时下面（2026-08-03）**：上游硬编码 60s，而真实调用要 66.5s，
于是几乎每次都差几秒超时 → 每条白烧 2×60s → fail-open 留在积压里，实测排空只有
**2.1 条/分钟**（一次运行 14 条 fail-open 告警，全是
`Client.Timeout exceeded while awaiting headers`）。
只有特别短的帖子能侥幸跑完，所以表现像「慢」而不是「坏」，这类**卡在边界上**的超时
最难发现。上游 `a17d39d` 改成可配置（`LLM_TIMEOUT`，默认 `llm.DefaultTimeout=300s`），
清单里显式写 300。

两个容易误读的点：该端点**非流式**，生成完才回 header，所以这个预算覆盖**整个生成过程**，
不是连接阶段（错误信息里的 "awaiting headers" 极具误导性）；客户端放弃**不会**让服务端
停止生成，每次超时还白耗一次共享 GPU 容量。

**吞吐（集群实测，reasoning 开）：并发 8 下 3.0 条/分钟。**
进度逐条落库，中途被 deadline 杀掉不丢；`enrich_cache` 按 `description_sha256` 去重。

⚠️ 别按「单条 66.5s ÷ 并发 8 = 7.5 条/分钟」推算，那是本文档早期写错的数字。
实测只有 **3.0 条/分钟**：单条独占是 66.5s，但 8 并发时每条被拉长到约 160s，
即 8× 并发只换来 **3.3×** 吞吐，DGX 已接近饱和。据此：

| | 条数 | reasoning 开（3.0/分钟） |
|---|---|---|
| baseline 积压 | ~4,900 | ~27h ≈ **9 个 3h 夜间窗口** |
| 稳态每日新增 | ~200 | ~1 小时 |

⚠️ **并发和 CPU 都不是提速的答案**：LLM 阶段实测 CPU 只有 1m（在等推理），
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
| 平均 | 60.5s | 3.2s（快 18.8×） |

**质量代价小且不是单向变差**：taxonomy 映射后的 `job_tech` 有 2/4 完全一致，
两处差异都只差一项且方向相反，一次多找到 reasoning 漏掉的 `mssql`，
一次漏掉 `sql`。裸输出确实更松（出现 "ship"、"hats"，来自 "wear many hats"），
但 `writeResult` 会把每个词过 `tech_taxonomy` **白名单**，没命中的进
`unmapped_tech`，**进不了 `job_tech`**，白名单才是真正的质量闸门。

⚠️ `reasoning_effort` 这个参数该模型**静默忽略**，只有 `chat_template_kwargs` 有效。
且默认**不发**该字段（请求体与从前逐字节一致），它是 vLLM/模板专用的，
换成 LLM 网关或没有该模板的模型会被拒。

**用法定位**：只用来啃积压，不用于稳态。稳态每日约 200 条、reasoning 开着约 1 小时
就跑完，精度留着更值。清单里因此**不设** `LLM_THINKING`（= 默认开启），
啃积压走一次性 Job（不进 git，见下节）。

## 一次性积压回填

baseline 之后有约 4,900 条积压。按默认（reasoning 开）3.0 条/分钟要跑约 **9 个**夜间窗口；
用 `LLM_THINKING=false` 的一次性 Job，集群实测 **26～29 条/分钟**（约 2 小时跑完）：

⚠️ 别拿「DGX 空闲时单条 3.2s」推成 150 条/分钟，8 并发照样把 DGX 推到饱和，
实际是 26～29 条/分钟。相比 reasoning 开的 3.0 条/分钟，约 **9 倍**。

```bash
# 先停掉正在跑的 enrich，两个进程会争同一个 SQLite 库，且读到同一份积压、
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
**反而更慢**：争的是同一份 CPU，不是网络。

上游 `738cb98` 加了 `mcf.ReadArchiveDescriptions`：按文件分组待取的记录下标，
每个文件只走一遍，且只解码 `description` 字段（不实例化整个 `Job`）；取齐即停，
停点之后的截断尾部不再算错误。`Enricher.Run` 一次性取两个 backlog（它们按不同
`job_tech.source` 过滤，故顺序无关），两层共用同一份描述表。

**效果**：同一份归档、同样数据，规则层 75 条/14 分钟 → 4,837 条/30 秒（0 错误），
容器 CPU 从满载降到 ~0%，瓶颈回到它本该在的地方（推理时间）。

代价是把描述表放进内存，所以特意压过：4,900 条描述峰值 **82.5MiB**（512Mi limit 下
未 OOM，exit 0）。归档再长几倍也还有余量，但**若日后归档单文件涨到数十万条，
要重新量一次**，这是用 CPU 换内存，不是白拿。

顺带修掉了「看起来像卡死」的伪装：`enrichOne` 原本把归档读失败**静默丢弃**
（`if err != nil { return 0,0,1 }`，没有任何日志），所以归档不可读时表现为
CPU 满载、无日志、无进度，和「慢」完全无法区分。现在两层都会计数并告警式记日志。

另一个误导信号：`jobs_sg_enrich_backlog` 统计的是 LLM 层**尚未处理**的岗位
（缺 `source='llm'` 行**且**缺 `enrich_done` 标记，上游 ff5e24e 起），
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

`/` 服务的是 `report/latest.html`，第一份周报出来前它是 404。存活探针和 Uptime Kuma
都打 `/healthz`（只验 DB 能打开），不要拿 `/` 当探针。

## ⚠️ 聚合页的 5s 预算 vs CPU 上限（2026-08-08 实测）

上游给所有聚合页写死了 `dailyTimeout = 5s`（`internal/web/daily.go:24`）：查询超时就是
**500**，不是慢。而 web 容器的 CPU 上限直接决定这 5 秒够不够：单线程 SQLite 被
CFS 节流到 0.2 核时 `/tech` 必然超时。

升到 `90cd4e8` 当天：`/tech` 稳定 500，其余页面都在预算内。把上限 200m → **1000m**
后 `/tech` 1.63s 通过。各页实测（1000m 上限、11184 在架岗位）：

| 页面 | 耗时 |
|---|---|
| `/reports` | 0.10s（静态文件） |
| `/` | 0.33s |
| `/ops` | 0.38s |
| `/companies` | 0.49s |
| `/tech` | 1.63s（200m 上限时 >5s 超时 500） |
| `/pay` | 2.01s |

☠️ **判 CPU 节流不要用 `kubectl top`**：它报 25m，看着离 200m 上限还很远，于是很容易
误判成「不是 CPU 问题」。metrics-server 的采样窗口是几十秒，**5 秒的突发被平掉了**。
判据是 cAdvisor 的节流计数器：

```sh
# 在 homelab 的 Prometheus 上查（port-forward svc/kube-prometheus-stack-prometheus）
rate(container_cpu_cfs_throttled_periods_total{namespace="jobs-sg",container="web"}[5m])
  / rate(container_cpu_cfs_periods_total{namespace="jobs-sg",container="web"}[5m])
```

修之前 **61%** 的周期被掐，修之后 9%。requests 保持 25m（上限不预留资源），节点
requests 当时仅 27%。⚠️ 不要再往上加：homelab 是笔记本（idle ~60–62°C，见
[homelab-host-power-thermal.md](homelab-host-power-thermal.md)），真需要更多
就该去修上游查询或那个 5s 预算。

## ⚠️ 手动跑 ingest 会和 web 抢锁（rollback journal 的代价）

`db.go` 的注释说「写入由 cron 排班串行化，所以只读 web 可以直接开库」：**这只在没人
手动插一轮的时候成立**。DELETE journal 下写者要 EXCLUSIVE 锁，而读者持 SHARED 锁：
web 正在渲染聚合页时，写者等不到锁，`busy_timeout=10s` 一过就 `SQLITE_BUSY`。

2026-08-08 手动跑 `ingest-migrate-90cd4e8` 建索引时实测：一条 upsert 失败
（`database is locked (5)`），该轮记成 **`partial` / `errors=1`**（上游 `78b88e9` 起
「丢了岗位就不算 success」）。丢的那条会被下一轮增量或周日的全量 reconcile 捞回来。

**已缓解（2026-08-08，上游 `730c6f3`）**：写事务撞锁现在会**重跑整个事务**
（退避 25/50/100/200/400ms），不再把整轮标成 partial。

⚠️ 修的方式**不是**加大 `busy_timeout`，那在这个场景下根本不被调用：rollback journal
下写者提交要把 RESERVED 升级成 EXCLUSIVE，此刻若仍有读者持 SHARED，SQLite **立即**返回
SQLITE_BUSY 而不进 busy handler（在那儿睡可能死锁，因为读者也许正等着这个写者）。
我们设的是 10s，照样输。所以以后再看到 `database is locked`，别去调那个 pragma。

代价不对称是这个修复的理由：任何 error 都把该轮标 partial，而 **partial 的 reconcile
会整个跳过关闭逻辑**（`ingest.go:280`）：周日那轮 20 分钟全 board walk 撞一次锁，就
静默损失一周的岗位寿命数据。

历史上那条 partial 记录（`/ops/2026-08-08` 的 01:09 那行，`errors=1`）**保留不动**：
它是当时的事实，改库等于篡改记录。

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
就双双 500，而数据量小的 `/daily/2026-08-02` 始终 200。**"上线时全绿"不等于"一直绿"**。
只读根文件系统 + SQLite 的组合，要按最大查询而不是按当时的库来验。

emptyDir 用**磁盘**不用 `medium: Memory`：tmpfs 算进容器 192Mi 内存上限，溢出几十 MB
就是 OOMKill。`sizeLimit: 256Mi` 兜住节点临时盘（homelab 是笔记本）。`/data` 仍是
`readOnly`，写隔离没有放松。

## 镜像固定

Kyverno `disallow-latest-tag` 在 homelab 是 **Enforce**，策略 digest-aware：digest 与
明确 tag 都放行，只拦 `:latest`。本应用按 digest 固定，且必须用
**manifest-list（OCI index）digest**，不是 amd64 单架构 digest，否则换架构拉不到。
升级只改 `kustomization.yaml` 的 `images[0].digest` 一行，命令见该文件注释。

**不启用 ArgoCD Image Updater**：集群当前 0 个 ImageUpdater CR，为一个应用引入需补
CR + git write-back 凭据，收益不抵复杂度。手动更新 digest。

⚠️ **「只改 digest 一行」不总是够**。2026-08-08 从 `ff5e24e` 升到 `90cd4e8`（跨 81 个
commit）时，同批必须改 `web.yaml` + `monitoring.yaml`：新镜像把 `/metrics` 挪到 9090，
只换 digest 会让 ServiceMonitor 继续抓 8080 → **指标全断且不报错，所有告警一起变瞎**。
升级前先看上游 `git diff <旧sha>..<新sha> -- deploy/`，那是「清单要跟着改什么」的清单；
上游 `docs/09-deploy-runbook.md` 是配套的踩坑册。

### schema 迁移：web 只读，索引靠写侧进程建

上游 schema 全是 `CREATE TABLE / CREATE INDEX IF NOT EXISTS`，由 `ingest`/`enrich`/
`report` 启动时 `Migrate()` 幂等执行。**`web` 用 `mode=ro` 打开库、从不 Migrate**，所以
新版镜像带来的新表/新索引在下一次写侧进程跑起来之前**不存在**：

- 只加索引（如 `90cd4e8` 的 4 条）→ 页面仍正确，但在 ~86k 行上全表扫、且 web 限
  200m CPU，聚合页会明显变慢。
- 若某版真加了**新表**且 web 要查它 → 那就是 500，直到写侧进程建表。

升级后不想等 18:15 UTC 那轮 ingest，就手动补一次（增量 2–4 分钟）：

```sh
kubectl --context k3s-homelab -n jobs-sg create job --from=cronjob/ingest ingest-migrate-1
```

## 备份口径（两条路径，缺一不可）

`local-path` 无冗余无快照，备份是强制项。`backup/overlays/homelab/backup-script.yaml`
里 jobs-sg 占**两处**：

1. **`jobs.db`（+ journal）**：加进第 2 步 `for pat in ... jobs-sg-data` 白名单，
   靠 `*.db*` 文件名模式捞走。
2. **`raw/` 归档**：第 3 步的 `JOBS_ARCHIVE_DIR` 整目录直接纳入 restic，不经 `/work`
   中转（`/work` 是 emptyDir，每晚拷一遍白吃节点临时盘）。同 oracle overlay 的
   `BOOKS_DIR` 做法。

⚠️ **只加白名单是不够的**：归档是 `raw/<date>/NNN.jsonl.gz`，`.jsonl.gz`
**匹配不上** `*.db` / `*.json` 那组模式。上游 jobs-sg `docs/04` §4 只写了加白名单一行，
照做会让最不可替代的数据静默漏备。CI 的 H4 只检查 PVC 有没有备份归属，**查不出
"归属了但模式对不上"**，这类只能靠实测（`restic ls` 确认 .jsonl.gz 真在快照里）。

归档为什么不可重建：MCF API 只返回**当前在架**职位，下架的永远拿不回来。

注意归档写的是**解析后**重新 marshal 的结构体（`archive.Write` 里 `json.Marshal(j)`），
不是原始响应字节，这是刻意的合规取舍（`createdBy` / `emailRecipient` 等发布者个人
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
教训有两条：① 不要引用一个还没人填的 Vault 路径；② **先看现有路径够不够用**。
这次 `bot_token` 本来就在 Vault 里，chat/thread 本来就不是密钥，压根不需要新路径。

⚠️ **ESO 的 `data` 是全有全无的**，所以只声明真正要用的键。声明了却不用的键不是惰性的，
是硬要求：曾多声明一个用不到的 virtual-key（直连 DGX 根本不用），等于逼着启用 Telegram 时
必须连一个用不到的值一起写进 Vault，否则连 bot token 都同步不了。

### 话题路由

告警与周报共用同一个群（MatthewDaily，`is_forum: true`），只靠 `message_thread_id`
区分话题：

| 话题 | thread id | 谁在用 |
|---|---|---|
| 🚨 Homelab 告警 | `2` | Alertmanager / falcosidekick / krr |
| jobs-sg | `552` | jobs-sg 周报 |
| （General） | 留空 | — |

`jobs-sg` 话题是 2026-08-03 由 bot 自己经 `createForumTopic` 建的（bot
`@matthew_daily_bot` 是群管理员且有 `can_manage_topics`，故无需人工建）。
**刻意不复用 thread 2**：上游 `docs/02 §4.3` 明令周报不得进告警话题。

换话题：Telegram 里右键目标话题 → 复制链接，`t.me/c/<内部 id>/<thread_id>` 的第二个
数字填进 `cronjob-report.yaml` 的 `TELEGRAM_THREAD_ID`（**一行改动，不涉及 Vault**）。
bot 也可以再建：`createForumTopic`（见 git 历史里的一次性 Job，
token 从 Secret 注入、不落日志）。

⚠️ 上游原先把该字段序列化成 JSON **字符串**（`"7"`），而 Bot API 规定 Integer。
若被忽略，就会静默投到 General 且返回 200，看着完全像成功，而告警话题与内容话题
只靠这个字段区分。2026-08-03（`8259cba`）已改发数字，非数字值改为显式报错。

`TELEGRAM_BOT_TOKEN` 仍标 `optional: true`：ESO 万一没同步上，report 打一行
"telegram disabled" 后照常生成 HTML/MD，而不是 `CreateContainerConfigError` 卡住整个
Job，同 `backup/overlays/homelab/open-notebook-external-secret.yaml` 的取舍。

## 可观测

`web` 的 `/metrics`（**容器 9090**，见上「web 监听两个端口」）暴露 `jobs_sg_*`，状态算自
DB 而非进程内存，故 web 重启不丢指标。ServiceMonitor + PrometheusRule 都带
`release: kube-prometheus-stack`，**漏了会被 operator 静默忽略**，指标不采、告警不生效
且无任何报错。**端口名对不上是同一种失败模式**：ServiceMonitor 必须抓 `port: metrics`。
Prometheus/Alertmanager 仍在 homelab（2026-08-02 只迁了 ArgoCD/Loki/Tempo 去 oracle），
故监控对象跟着落 homelab。

最重要的告警是 `JobsSgIngestStale`（任何形式的采集停滞 >36h）：这类应用**静默失效比
崩溃更危险**，上线前实测发现的两个 bug 都属此类（见下）。

2026-08-08 升级同批改的两条告警，各自修掉一种「训练你忽略告警」的误报：

| 告警 | 变化 | 为什么 |
|---|---|---|
| `JobsSgIngestStale` | 从只匹配 `kind="incremental"` 改为 `min without(kind) (…{kind=~"incremental\|full_reconcile"})` | 周日那轮把自己记成 `full_reconcile`，`incremental` 系列每周固定断档 48h > 36h → 每周误报约 12 小时，而这恰是最不该被噪音淹没的一条 |
| `JobsSgEnrichBacklog` → `JobsSgEnrichBacklogGrowing` | 从绝对值 `>2000` 改为**地板抬升** `min_over_time([1d]) - min_over_time([1d] offset 1d) > 500`，`for: 2h` | 首跑基线一次性灌入 ≈11k 候选，LLM 每晚排 ~420、每天进 ~300 → 绝对阈值上线第一晚就响并持续一两个月。稳态积压是锯齿形，**每日低谷**才是「管线还跟不跟得上」的信号 |

指标改名（同批，上游 `docs/04-operations.md` §3.1）：`jobs_sg_jobs_total` → `jobs_sg_jobs`、
`jobs_sg_jobs_new_total{week=}` → `jobs_sg_jobs_new`（**去掉 `week` 标签**，每周新增一条
永不退休的 series 是撑爆 Prometheus 的标准做法，周次让 Prometheus 自己的时间轴回答）、
`jobs_sg_unmapped_tech_total` → `jobs_sg_unmapped_tech`（`_total` 后缀只给 counter，这些是
双向变动的 gauge）。homelab 侧没有任何查询引用这三个（告警只用 `last_success` /
`ingest_errors_total` / `enrich_backlog`，Grafana 面板本来就没做），故改名无影响。
**但以后建面板要用新名**。

另两条约定值得记住：**无值即不输出、绝不补 0**（首次 report 前就没有 `jobs_sg_jobs_new`，
补 0 会让「还没有数据」和「真的是 0」不可区分）；**任何 DB 错误 → 整个抓取 500**，让
Prometheus 把 target 标 down（`up == 0` 本身就是信号），而不是吞掉错误输出假的 0。

## 已修复：全量 reconcile 从来没成功过，2770 条过期岗位一条没关（2026-08-10，上游 4af8944）

`JobsSgIngestStale` 2026-08-09 06:49Z 烧起来。**排查方向别从「抓取停了」开始**：那轮
数据其实完全刷新了（856 页 / scanned 85487 / new 81 / updated 8977），是被判定逻辑
标成 partial 的。

**症状**：`jobs_sg_last_success_timestamp_seconds{kind="full_reconcile"}` 这条 series
**从来不存在**；`ingest_run` 全表只有一次 reconcile（08-08，partial）；**11580 条岗位
`closed_at` 全为 NULL，其中 2770 条早已过 `expiry_date`**。关闭流程一次都没跑过。

三个叠在一起的根因：

1. **偏差拿峰值比累加和**（真正的 bug）。`mcf.Summary.Total` 取全程 `max(page.Total)`，
   而 `Jobs` 是逐页累加；扫描要 25 分钟，`total` 在底下一直动，峰值除以累加和，量纲
   就不对，任何瞬时抬升被永久固化。那轮算出 `dev=4.5%`（85487 vs 早已回落的 89531）
   ≥ 2% 阈值 → 拒绝关闭。**平静时段实测 MCF 的 `total` 精确可信**：
   page 864 满 100 条、page 865 剩 10 条、page 866 空，865×100+10 = 86510 = `total`，
   分毫不差，且 100 秒采样纹丝不动。所以那 4.5% 不是常态。
   修法：`Total` 改取**最后一页**读数，另存 `MinTotal`/`MaxTotal`。
2. **偏差高时把到期关闭也一起停了**。`expiry_date` 是 MCF 自己公布的下架日期，不是从
   「没见到」推断出来的，本就不该受扫描完整度门控。于是一个谨慎的夜晚停掉了整条生命线。
3. **跳闸算进了 `errors++`**，污染 `jobs_sg_ingest_errors_total`（那条告警的语义是
   「MCF 字段形状变了」），让谨慎但健康的一晚和真坏了的一晚长得一模一样。

**告警时间点对得上到秒**，可以当排查模板用：最后一次 incremental 成功
`08-07T18:19:53Z` + 36h = `08-09T06:19:53Z` + `for: 30m` = `08-09T06:49:53Z`，
实际 `startsAt` = `08-09T06:49:57Z`（差 4s = 抓取间隔对齐）。

⚠️ **36h 阈值只有在「reconcile 能成功」的前提下才成立**。UTC 周六 18:15 = SGT 周日
02:15 那轮转成 reconcile，当天**没有 incremental**，所以 incremental 的成功间隔跨
reconcile 之夜天然是 **48h > 36h**。`min without(kind)` 靠 reconcile 的成功戳补这一格，
补不上就每周准点误报。所以修法是让 reconcile 能成功，**不是**放宽阈值
（monitoring.yaml 里那段长注释已经写明不许放宽，理由一致）。

**补救实测（2026-08-09 18:18Z 手工 `--reconcile`，24 分钟）**：`full_reconcile` 史上
第一次 `status=success`，**关闭 2738 条**，`errors=0`、`close_skipped=false`，
`scanned=82987 / total_reported=82987`（偏差正好 0）。库里 11645 条 → closed 2738 /
open 8907；仍开着但已过期的从 2770 降到 **21**（这 21 条本轮见到了，「在架」压过
「过期日」，是设计要的行为）；114 条未见但未到期只记 `miss_count=1`，下轮再没见到才关。
`JobsSgIngestStale` 随即消失，Alertmanager 只剩 Watchdog。

⚠️ **但这一轮并不能证明修复是必需的**：那晚 `total_max=83003`、最终 82987，按旧代码
算偏差只有 0.019%，**照样能过闸**。真正值钱的读数是 `total_min=75255`：
同一次扫描里 total 在 **75255↔83003（约 9.3% 带宽）** 之间摆。旧实现会不会被咬，取决于
峰值落在最终值之上多少：08-08 落在上面（89531 vs 85487）就炸了，这晚差 16 就没炸。
修复消掉的是这枚硬币，不是某一次具体的数值。

✅ **残留风险已收敛（2026-08-10 晚，上游 4b91fe8）**。原先记的「向下凹陷落在最后一页
仍会反向误跳」已修，但**不是**用当时设想的「翻到空页」判：那个判据对这个闸门恒真：
对账从不早停，干净扫描的唯一出口就是空页，熔断和页错误早已进 partial。真正剩下的
威胁只有「API 中途假空页截断板子」，它的探测器是**覆盖率** `scanned / max(total)`，
下限刻意放宽到 **80%**：total 噪声带实测 ±10%（75255↔83003 一轮之内），而真截断是
断崖式的；放过去的零头落进 miss_count 两周判定 + reopen 自愈。偏差降为纯遥测
（`deviation_ratio` 保留），新增 `jobs_sg_reconcile_scan_coverage_ratio` 暴露闸门真实输入。

同批第二处：**干净扫描的对账轮（errors=0，含 close_skipped）照常盖 incremental 新鲜戳**
（`store.LastSuccess` 特例），`full_reconcile` 的戳仍扣住。从此谨慎的周日不再点着
`JobsSgIngestStale`，而 `JobsSgReconcileStale` 依旧看得见连续谨慎数周的闸门，
两条告警一条管「数据新不新」、一条管「生命周期对没对账」，彻底解耦。

**新增的排查抓手**（以前证据只在一行容器日志里，事后只能 SSH 上节点翻 gzip）：
`ingest_run` 加了 `jobs_scanned` / `total_reported` / `total_min` / `total_max` /
`close_skipped`；指标加了 `jobs_sg_reconcile_scan_deviation_ratio` 与
`jobs_sg_reconcile_close_skipped_total`。注意 `jobs_seen` 记的是本轮**归档**了多少
（reconcile 只归档没存过的），`jobs_scanned` 才是走过的条数，两个数不等不是故障。

补列走 `store.addedColumns` 的 `ALTER TABLE`：`schema` 是 `CREATE TABLE IF NOT EXISTS`，
对已存在的表是空操作，只加在建表语句里等于只对全新部署生效。`/metrics` 侧用
`HasColumn` 兜住「新 web 镜像撞上还没被写者迁移过的库」那段窗口，那里的设计是
**DB 出错就整个 scrape 500**，不兜的话 jobs-sg 全部告警会连同那条本该发现故障的
staleness 一起哑掉。

## 已修复：/daily 天天 partial 的两个根因（2026-08-05，上游 ff5e24e）

上线后头三天（08-03~05）`/daily` 日状态全是 `partial`、`llm_cached` 每晚恒 ≈1.4k。
两个独立 bug，都是**静默失效**型（fixture 与实现错得一致，CI 全绿）：

1. **增量早停是死代码**：MCF 的 `newPostingDate` 是纯日期 `"2026-08-03"`，
   而 watermark 与逐条停止条件都按 RFC3339 解析 → 双双静默失败 → 每晚扫满
   300 页熔断（`ErrCircuitOpen`）→ `errors=1` + `partial`。
   修复：`mcf.ParsePostingDate`（纯日期优先、RFC3339 回退）。
   **实测**：修复后增量 130 页 / 6m48s / success（修复前 300 页 / 8m46s / partial）。
2. **零命中岗位永留积压**：LLM 结果全落 `unmapped_tech` 的岗位不写任何
   `job_tech` 行 → 永远在 backlog 里、每晚被 `enrich_cache` 重放
   （`llm_cached ≈ backlog` 是这个 bug 的指纹）。
   修复：新表 `enrich_done`（Migrate 幂等建），`writeTech` 同事务恒写；
   积压口径改为双 NOT EXISTS，存量免回填。
   **实测**：部署后首个 enrich run 53s / cached=1425 / calls=0，
   `jobs_sg_enrich_backlog` 1425 → **0**。

**数据零丢失**：300 页窗口实际回溯约 8 天（MCF 日新帖仅 ~5k，周末 ~1.4k），
新帖按 `sortBy=new_posting_date` 永远在前几十页；加上 08-03 baseline 全量，
头三天每条岗位都归档过（多数重复多次）。

⚠️ 一条不自愈的残留：**历史三天（08-03~05）的 partial 不追溯变绿**：run 状态是
当时事实，日状态取当天最差 run，08-06 起才是第一个可能全绿的行。

08-03 曾另有 4 条回填实验被 kill 留下的孤儿 `running` 行（只写了 StartRun、
`ended_at` 全 NULL）。2026-08-05 已手工清理：确认集群无活跃 run 后，节点上
python3 直删 `DELETE FROM ingest_run WHERE status='running' AND ended_at IS NULL`
（删前备份 `/tmp/jobs.db.bak-20260805`，节点重启即失效，属临时保险非长期备份）。
若日后再手动 kill enrich/ingest Job，会再产生这类行，同法清理。

## 上线前实测发现的两个应用 bug（2026-08-03，已修）

已发布镜像跑不起来，两个缺陷都只能实测发现、测试套件看不见：

1. **`ingest` 启动即 panic**：`cmd/ingest` 用
   `time.LoadLocation("Asia/Singapore")` 且丢弃了 error。运行镜像是 `FROM scratch`，
   没有 `/usr/share/zoneinfo` 也没 import `_ "time/tzdata"` → 返回 nil →
   `time.Now().In(nil)` panic。改用 `time.FixedZone("SGT", 8*3600)`。
2. **每页解码失败 → 一条也入不了库**：6 个字段被建模成 string，而 API 返回对象
   （`employmentTypes` / `salary.type` / `address.districts` /
   `flexibleWorkArrangements` / `schemes` / `_links.{self,next}`）。Page 整页解码，
   一条坏数据废掉同页 100 条。

CI 当时是绿的：`testdata/fixture/jobs.jsonl` 由 `scripts/genfixture` 从**同一批错结构体**
生成，fixture 与 bug 相互印证。修复同时加了 `internal/mcf/livedecode_test.go`，用真实
抓取的响应（已剥离个人字段）做断言，结构体再漂移就在 CI 挂而不是在生产。

修复提交 `2d7b9ad`。**别回滚到 `2d7b9ad` 之前的镜像**，它们的 ingest 一律 panic。

## 上线实测基线（2026-08-03）

首次 bootstrap 的真实数字，可当容量与告警阈值的参考：

| 指标 | 值 |
|---|---|
| baseline 全量扫描 | **884 页 / 88,258 seen / 29 分钟 / 0 错误** |
| 入库候选岗位 | 9,499（`seen` 远大于 `new`：只有候选岗位入库） |
| 首份周报 | 2026-W31，1,301 条新岗，生成耗时 6s |
| enrich 积压（baseline 后） | ~4,900（SWE 子集） |
| enrich 规则层（修复后） | **4,837 条 / 30 秒 / 0 错误**（修复前 75 条 / 14 分钟） |
| enrich 归档扫描（集群内，500m limit） | 约 150s，一次性；CPU 顶满，之后降到 ~1m |
| 单条 LLM 抽取 | 66.5s（真实描述；短 prompt 约 15s，别用它规划容量） |
| 节点容量 | 8 核 / 7600m allocatable，idle 用量约 9%、requests 合计 27% |

⚠️ 别按「库里岗位数 ÷ 100」估页数，`seen`（88k）远大于 `new`（9.5k），按后者算会把
全量扫描的耗时高估近一个数量级（`activeDeadlineSeconds: 3600` 实际很宽裕，29 分钟就跑完）。

## 已知缺口

- ~~`classify.WorkMode` 只匹配 `remote`/`hybrid`/`onsite` → 所有职位都是 `Onsite`~~
  **已修（2026-08-08，上游 `af34eed`）**，详见下节。
- Grafana 面板未做（`jobs_sg_*` 指标已在采，用 Explore 可查）。
- ~~恢复演练未做~~ **已覆盖（2026-08-13）**：`restic-restore-drill` CronJob 每月从 106 仓库
  实际 restore `jobs.db` 并跑 `PRAGMA integrity_check` + 表数判据；`raw/*.jsonl.gz` 归档
  抽一个文件 `gzip -t` 实解（不是全量恢复）。判据敏感度用损坏数据验过。
  → [storage.md 月度恢复演练](storage.md#月度恢复演练2026-08-13-上线)

## 重放归档重算分类（`jobs-sg-reclassify`，2026-08-08 起）

分类结论（`is_swe` / `role_family` / `seniority` / `work_mode` / `company_type`）是
ingest 当时算好**存在行上**的。修了分类器，只有管线**再次看见**的岗位会被修正，
**已经下架的岗位永远保留错误结论**，历史周报也就一直错着。

✅ **已执行（2026-08-24）**：线上跑过 `reclassify --apply`，全表（含已下架/已关闭行）
的派生分类已重写，生产库 `work_mode` 0 条 `Onsite`，全部是 `Unknown` / `Remote`。
同批的 `retech --apply` 与 `report --week` 逐周重算见下一节。

归档存着每一条见过的岗位，而分类规则是该 JSON 的**纯函数**，所以整段历史可以离线重算：

| | 强制 reconcile | `reclassify` |
|---|---|---|
| MCF API | ~867 页 × 1.5s | **零** |
| 耗时 | 20–25 分钟 | 扫一遍归档 |
| 覆盖 | 只有还在架的 | 每一条归档过的，含已下架 |

镜像里的第 5 个二进制（`b6a3aaa` 起），**没有 CronJob 跑它**，手动起一次性 Job：

```sh
# 1) 先 dry-run：只报告 old->new 迁移矩阵，不写库
kubectl --context k3s-homelab -n jobs-sg create job reclassify-dry --dry-run=client -o yaml \
  --image=ghcr.io/meirongdev/jobs-sg@sha256:<当前digest> -- \
  /usr/local/bin/jobs-sg-reclassify --data-dir /data > /tmp/j.yaml
# 补上 PVC 挂载后 apply（PVC: jobs-sg-data，挂 /data，**可写**）
# 2) 看完矩阵再决定是否加 --apply 重跑一次
```

⚠️ 三条必须知道的：

1. **默认 dry-run**，`--apply` 才写。先看迁移矩阵，尤其是 `is_swe` 的增减，
   它移动的是**所有指标的统计口径**，不只是一列，报告里单独高亮。
2. **只写派生列**。`closed_at` / `last_seen_at` / `first_seen_at` / `miss_count`
   在 SQL 里根本不出现，重放归档说明不了岗位是否还在架，碰 `last_seen_at`
   会让岗位显得被重新看见、悄悄撤销一次关闭。上游有单测和真库验证钉住这条。
3. **归档里有、库里没有的 uuid 只计数不插入**（那种行没有诚实的 `first_seen_at`
   可填）。这个计数顺带就是「partial 那几轮到底漏了几条」的答案。

它**不重跑 LLM**，也不动技术栈，`job_tech` 是 enrich 那层，重放它是
`jobs-sg-retech`（下一节）。

## 重放规则层重算技术栈（`jobs-sg-retech`，2026-08-24 起）

同一个病，另一张表。`job_tech` 里 `source='rule'` 的行是 enrich 当时按
`tech_taxonomy` 别名表算好存下的，而 enrich 的积压口径是
`NOT EXISTS job_tech AND NOT EXISTS enrich_done`，**做过的永远不会重算**。
所以修了别名表或匹配逻辑，只有新岗位吃到修复，已富化的那几千条保留旧结论，
`/tech`、`/pay` 和周报的技术栈趋势就一直错着。

`retech` 是 `reclassify` 的技术栈版：扫归档、用当前别名表重算规则层、重写
`job_tech`。零 API 调用，**只碰 `source='rule'`**，`source='llm'` 的行没有模型
重放不出来，读都不读。

```sh
# 1) dry-run：报告哪些 slug 增减了多少条，不写库
kubectl --context k3s-homelab -n jobs-sg create job retech-dry --dry-run=client -o yaml \
  --image=ghcr.io/meirongdev/jobs-sg@sha256:<当前digest> -- \
  /usr/local/bin/jobs-sg-retech --data-dir /data > /tmp/j.yaml
# 补上 PVC 挂载后 apply（PVC: jobs-sg-data，挂 /data，**可写**）
# 2) 看完增减再决定是否加 --apply 重跑一次
```

⚠️ 四条必须知道的：

1. **默认 dry-run**，`--apply` 才写。
2. **报告里的变化不都是规则造成的**。重放用的是**最后一次归档**的文本，所以描述
   被改过的岗位也会进 diff。判据：规则改动一次动几百条，描述编辑是长尾的单条。
   2026-08-24 首次实测 811 条变化里，`expressjs -406`、`go -398`、`typescript -9`
   是规则；其余十几个 slug 各 1 条，抽验 `kibana`/`swift` 两条确认是 JD 原文
   已不提该工具。
3. **dry-run 真的只读**（`73aa949` 起）。它 replay 的是代码里的 `store.TechSeeds()`
   而不是 `tech_taxonomy` 表，Seed 之后两者相等，但读列表不必先写库，老库里残留
   的退役别名也就不会被 replay 用上（那正是要修的 bug）。`--apply` 才会跑 `Seed()`
   把表也收敛掉：每晚 enrich 读的是**表**，历史清干净了而表里还留着退役别名，
   新岗位照样会被它命中。
   ⚠️ 上游 `8b3040a` 那一版的 dry-run **会**写 tech_taxonomy（110→109），别回滚到它。
4. **`enrich_done` 只补不盖**（`fba4fcf` 起）。已有的标记绝不重新盖时间戳，
   那等于宣称每晚那轮 enrich 干了它没干的事（几千行）；但**缺的必须补上**：
   有 4140 条岗位是在 `enrich_done` 表存在之前富化的，对它们来说 `job_tech` 行
   **就是**「这层跑过」的唯一证据，重放把它清空 = 它掉回 `enrichBacklog`。
   实测：不补标记时 `rule_backlog` 0 → **173**，补了之后 0 → 0
   （`llm_backlog` 始终 0，不会重烧 LLM）。
   ⚠️ 判据别看 `jobs_sg_enrich_backlog` 指标，它只数 **LLM** 层，rule 层积压
   涨了它一动不动。要自己查
   `NOT EXISTS job_tech(source='rule') AND NOT EXISTS enrich_done(source='rule')`。

✅ **已执行（2026-08-24 + 08-26）**：`retech --apply` 已在线上跑过：规则层假阳性
收口（`expressjs` rule 71 / `go` 471，`ts`/`pg`/`tf` 清零）。同日 08-24 用**不带
Telegram env 的 Job** 把 2026-W32/33/34 的 `report --week` 重算并重物化了
`weekly_metric`（tech_freq 换成收口版，`go`/`expressjs` 出 top-30、`kafka` 顶上）。
**2026-08-26 补重算了 W31（首周，唯一漏网的一周）**：它原本还挂着编造的
`Onsite: 1301`、已退役的 avg_views/applications 指标和指向不存在周的 prev week。

⚠️ **重算历史周的两个坑（实测）**：

1. `report --week <周>` 会**无条件把 `latest.html` / `index.html` 覆写成那一周**：
   重算完旧周**必须**再把最新周的 HTML 复制回 `latest.html` / `index.html`，
   否则「最新周报」会倒退。08-26 重算 W31 后就是这样恢复成 W34 的。
2. **`active_jobs`（"On the board at publication"）重算出来的是「重算当日」快照**，
   不是该周出版时点的真实在架数：SQL 是 `closed_at IS NULL AND expiry_date >= 周末`，
   而 `closed_at` 只反映重算当天是否还在架。实测 W32/W33 重算后都显示 **4597**（撞车
   不是巧合）、W31 从真实历史值 4902 变成 5266，历史值被覆盖且无快照可复原。
   重建真实历史在架数需要按 `first_seen_at` / `closed_at` / `expiry_date` 做 as-of
   查询（尚未实现）。

## 别名表的三个坑（2026-08-24，上游 8b3040a + 73aa949 + fba4fcf）

规则层是纯文本词边界匹配，**分不清词义**。三个缺陷叠在一起，其中两个会让「修好了」
变成假的：

1. **别名同时是普通英文词** → 大面积假阳性。实测（一天归档 483 条 IT 岗位人工判定）：
   `express` 24 命中只 6 真（25%，剩下是 Meta 简介里的 "express themselves" 和猎头
   签名档 "Recruit Express Pte Ltd"）；`go` 26 命中 17 真（65%，假阳性是
   "go-to-market"/"go-live"/"go-getter"/"go/no-go"）。修法是**词义门**：这类别名只在
   技术枚举上下文里算命中（一侧紧邻 `( , / ; [` 或 `) . ]` 等分隔符）。上门后
   `express` 5 命中 5 真、`go` 17 命中 16 真。
   ⚠️ 门有代价（漏掉 "Node.js Express REST APIs" 这种散文里的真命中），所以**只给
   实测精度差的加**：同批 `spark` 10/10、`node` 27/29、`swift` 9/10 故意不加门。
2. **删别名在已存在的库里是空操作**。`Seed()` 原来是纯 upsert，而 `LoadTaxonomy`
   读的是**表**不是代码，从 `techSeeds` 删一行，线上那条别名照样活着命中，
   提交、CI 绿、部署，行为一个字节都没变。现在 `Seed()` 会删掉表里不在 seed 列表
   的别名。**代价**：手工 `INSERT` 进 `tech_taxonomy` 的别名会被下一次
   ingest/enrich 清掉，加别名只能改代码。
3. **改别名表修不了历史** → 就是上一节的 `retech`。

对指标的实际影响（在生产数据副本上验的）：`expressjs` 在高薪档从 14.4% / lift 2.67×
掉到 0.6% / 0.61×（**它从来不是高薪信号**）；`go` 从 22.8% / 2.62× 变成 18.9% /
**3.94×**（删掉的假阳性扎堆在低薪那半边，所以清完溢价反而更明显）。
`go` 还因此**掉出周报 top-30 技术榜**（2026-W33 从 96 条降到 47 条，榜尾门槛 59），
让位给 `kafka`，之前那个名次是假阳性撑起来的。

### 判一个别名准不准：拿 LLM 层当对照，不用人工判

规则层和 LLM 层是**两套独立方法**看同一批 JD（正则匹配 vs 模型阅读），
所以两层命中集合的 Jaccard 重合度就是一个不需要人工标注的精度代理。
2026-08-24 实测（全量 job_tech）：

| slug | 修前重合 | 修后重合 | 说明 |
|---|---|---|---|
| `expressjs` | 12.6% | 77.2% | 加词义门 |
| `go` | 47.7% | 78.7% | 加词义门 |
| `spark` | 78.7% | 78.7% | 故意不加门 |
| `kubernetes` | 85.7% | 85.7% | 故意不加门 |
| `python` | 91.9% | 91.9% | 故意不加门 |

健康区间是 **~79–92%**。两个坏别名是唯一显著低于这个带的，加门后都被抬进带内；
刻意不加门的三个本来就在带内，这同时印证了「只给实测差的加门」那条判据。
`go` 的两层**共同命中**只从 411 掉到 385（-26），而 rule 单方面的命中掉了约 400，
删掉的几乎全是 LLM 不认可的那部分，recall 基本没伤。

新增或怀疑一个别名时先看这个数：明显低于 79% 就去看命中上下文，别直接信。

## work_mode 的口径：Unknown 是一等状态（2026-08-08 起）

MCF 的 `flexibleWorkArrangements` 回答的是**什么时候上班**，不是**在哪上班**。
2026-08-08 抓 500 条实测（全行业）：

| 次数 | 取值 | 性质 |
|---|---|---|
| 19 | `Flexi-Hours` | 排班 |
| 13 | `Employees Choice of Days Off` | 排班 |
| 4 | `Compressed Work Schedule` | 排班 |
| 3 | `Telecommuting` | **地点** → Remote |
| 2 | `Staggered Time` | 排班 |

**500 条里只有 37 条（7.4%）带这个字段**，唯一的地点信号占 3 条（0.6%）。旧实现匹配的
`remote`/`hybrid`/`onsite` MCF 一个都不吐，于是全部落到兜底 `Onsite`，首页
（`internal/view/market.go`）与周报（`internal/report/render.go`）上那个「办公模式分布」
是编造的，性质等同「值缺失就填 0」，而上游 `docs/04 §3.1` 恰恰明令禁止。

修复后：只有地点类 arrangement 产生地点结论（`Telecommuting`→Remote、
`Flexi-Place`→Hybrid），排班类一律不产生，**没有地点信号就是 `Unknown`**。
所以现在看到「Unknown 占九成」不是故障，是这个数据源本来就只知道这么多。

⚠️ **两条数据连续性的坑**：

1. **换镜像不会立刻改变页面**。`work_mode` 由 ingest 的 upsert 重写，web 只读，
   要等下一轮抓取；**周日那轮 reconcile 走全 board**，会把所有在架岗位一次性刷新。
2. **历史已由 `reclassify --apply` 追溯修正（2026-08-24）**。已关闭/归档的行不再保留
   旧 `Onsite`（生产库全表 0 条 `Onsite`），2026-W31~W34 的 `weekly_metric` 与周报
   文件也已在 08-24 / 08-26 用新口径重算。⚠️ 若再发现旧周数据可疑，先查
   `weekly_metric.week_start` 的 `computed_at` 是否晚于对应修复的部署时间。
