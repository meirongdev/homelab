# jobs-sg 上线当天：已发布镜像跑不起来，富化一轮要 30 CPU 小时

> 日期: 2026-08-03（上线日；部分问题在当天数据灌满后才暴露）
> 影响: 已发布镜像的 `ingest` 启动即 panic，修掉后每页解码失败、一条也入不了库；`enrich` 规则层
>       14 分钟只处理 75 条（一轮约 30 CPU 小时，窗口只有 3h），LLM 层几乎每条超时 fail-open；
>       ExternalSecret 引用了没人写值的 Vault 路径，`ExternalSecretNotReady` 持续告警 40 分钟、
>       App 常驻 `Degraded`；数据灌满后 `/daily` 两页 500
> 根因: 全是测试套件和冒烟测试看不见的一类：① `FROM scratch` 镜像没有 zoneinfo，`LoadLocation`
>       的 error 被丢弃；② 6 个字段建模成 string 而 API 回对象，fixture 由同一批错结构体生成；
>       ③ 每条岗位从头扫一遍 gzip 归档；④ 超时硬编码 60s，低于真实耗时 66.5s；⑤ 新造的 Vault
>       路径没人写值；⑥ 只读挂载上开不了 WAL；⑦ 只读根文件系统下 SQLite 临时文件无处可写
> 处置: 上游 `2d7b9ad`（时区 + 解码 + `livedecode_test`）、`738cb98`（归档每轮只读一次）、
>       `a17d39d`（`LLM_TIMEOUT` 可配，清单写 300）、`4538ba9`（journal 改 `DELETE`）；
>       ExternalSecret 改用已有的 `secret/homelab/telegram`；web 挂 emptyDir 到 `/tmp` 并设
>       `SQLITE_TMPDIR`。现状事实见 [reference/jobs-sg.md](../reference/jobs-sg.md)

## 经过

### ingest 启动即 panic，修掉后一条也入不了库

1. `cmd/ingest` 用 `time.LoadLocation("Asia/Singapore")` 且丢弃了 error。运行镜像是
   `FROM scratch`，没有 `/usr/share/zoneinfo`，也没 import `_ "time/tzdata"`，于是返回 nil，
   `time.Now().In(nil)` panic。改用 `time.FixedZone("SGT", 8*3600)`。
2. 6 个字段被建模成 string，而 API 返回对象（`employmentTypes` / `salary.type` /
   `address.districts` / `flexibleWorkArrangements` / `schemes` / `_links.{self,next}`）。
   Page 整页解码，一条坏数据废掉同页 100 条。

CI 当时是绿的：`testdata/fixture/jobs.jsonl` 由 `scripts/genfixture` 从同一批错结构体生成，
fixture 与 bug 相互印证。修复同时加了 `internal/mcf/livedecode_test.go`，用真实抓取的响应
（已剥离个人字段）做断言，结构体再漂移就在 CI 挂而不是在生产。修复提交 `2d7b9ad`。

### 归档每条重扫：一轮要 30 CPU 小时

上游原先按每条岗位调 `mcf.ReadArchiveRecord` 读描述，它每次都重新打开 gzip 从头扫。两个
富化层各读一遍，一轮成本是 `2 × 岗位数 × O(归档)`。baseline 归档是单个文件、88,258 条、
解压 402MB，平均记录在 72% 处，每条要解压约 290MB。

集群实测 14 分钟只处理 75 条，CPU 顶在 500m limit 上，照此一轮约 30 CPU 小时。当时把
`LLM_CONCURRENCY` 从 3 调到 8 想提速，反而更慢：争的是同一份 CPU，不是网络。

上游 `738cb98` 加了 `mcf.ReadArchiveDescriptions`：按文件分组待取的记录下标，每个文件只走
一遍，只解码 `description`，取齐即停。同一份归档、同样数据，规则层 75 条/14 分钟变成
4,837 条/30 秒（0 错误），容器 CPU 从满载降到约 0%。描述表峰值 82.5MiB（512Mi limit 下
未 OOM）。

另一层伪装：`enrichOne` 原本把归档读失败静默丢弃（`if err != nil { return 0,0,1 }`，没有
日志），归档不可读时表现为 CPU 满载、无日志、无进度，和「慢」无法区分。同批改成计数并记日志。

### 超时卡在真实耗时下面

上游硬编码 60s，而当时的模型（`deepseek-v4-flash`）真实调用要 66.5s。几乎每次都差几秒
超时，每条白烧 2×60s 后 fail-open 留在积压里，实测排空只有 2.1 条/分钟（一次运行 14 条
fail-open 告警，全是 `Client.Timeout exceeded while awaiting headers`）。只有特别短的帖子
能侥幸跑完，所以表现像「慢」而不是「坏」。上游 `a17d39d` 改成可配置（`LLM_TIMEOUT`，
默认 300s），清单显式写 300。

### ExternalSecret 引用空路径，告警 40 分钟

最初新造了 `secret/homelab/jobs-sg` 路径并把 ExternalSecret 直接发上去，但没人写值。ESO
对不存在的路径一直 `Ready=False`，`eso-alerts.yaml` 的 `ExternalSecretNotReady`
（`for: 15m`）持续告警 40 分钟，App 常驻 `Degraded`。`optional: true` 保住了 Pod，保不住
告警面板。其实 `bot_token` 本来就在 `secret/homelab/telegram`，chat/thread id 也不是密钥，
压根不需要新路径。

### 只读挂载开不了 WAL

`web` 的 `/data` 以 `readOnly: true` 挂载。WAL 模式打开时要在数据目录建 `-shm`，只读挂载上
做不到，`SQLITE_CANTOPEN`，web 每次启动即崩。上游 `4538ba9` 把 journal 改成 `DELETE`，并去掉
只读连接上的 journal pragma。

### 数据灌满后聚合页 500

上线当天逐条扫路由全是 200。几小时后 bootstrap 全量灌进来，`/daily`（30 天聚合）和
`/daily/2026-08-03`（当天数据最多）双双 500，而数据量小的 `/daily/2026-08-02` 始终 200。
日志是 `disk I/O error (6410)`，即 `SQLITE_IOERR_GETTEMPPATH`：排序/分组溢出到临时文件，
而只读根文件系统上所有候选目录都不可写。

## 上线实测基线

| 指标 | 值 |
|---|---|
| baseline 全量扫描 | 884 页 / 88,258 seen / 29 分钟 / 0 错误 |
| 入库候选岗位 | 9,499（只有候选岗位入库，`seen` 远大于 `new`） |
| 首份周报 | 2026-W31，1,301 条新岗，生成 6s |
| enrich 积压（baseline 后） | 约 4,900（SWE 子集） |
| enrich 归档扫描（500m limit） | 约 150s，一次性；之后 CPU 降到约 1m |
| 单条 LLM 抽取（`deepseek-v4-flash`） | 66.5s（真实描述；短 prompt 约 15s） |
| 节点容量（当时单节点） | 8 核 / 7600m allocatable，idle 用量约 9%、requests 合计 27% |

旧模型下 8 并发实测只有 3.0 条/分钟：单条独占 66.5s，8 并发时每条被拉长到约 160s，8× 并发
只换来 3.3× 吞吐。照此 baseline 积压要约 9 个 3h 夜间窗口；改用 `LLM_THINKING=false` 的
一次性 Job 实测 26–29 条/分钟，约 2 小时排空。

## 教训

- fixture 从实现生成时，测试与 bug 错得一致。外部数据形状要拿真实响应断言。
- 超时卡在真实耗时边界上最难发现：短输入侥幸通过，整体只像「慢」。
- 只读根文件系统 + SQLite 要按最大查询验，「上线时全绿」不等于「一直绿」。
- 引用 Vault 路径前先确认有值，先看现有路径够不够用。
