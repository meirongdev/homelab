# Open Notebook — AI 研读知识库（架构事实）

> Last updated: 2026-08-02
> Status: 生效事实
> Scope: Open Notebook（NotebookLM 自托管替代）在 homelab 集群的部署形态、模型接线、
> 配置真相源地图、备份口径 —— source of truth。
> 批量摄取操作见 [../runbooks/open-notebook-ingest.md](../runbooks/open-notebook-ingest.md)；
> 部署过程与踩坑见 [../plans/apps/2026-08-01-open-notebook-homelab.md](../plans/apps/2026-08-01-open-notebook-homelab.md)（冻结快照）。

## 部署形态

| 项 | 值 |
|---|---|
| 集群 / ns | homelab / `personal-services`（ArgoCD `personal-services` App，目录源自动纳管） |
| 清单 | `k8s/helm/manifests/personal-services/open-notebook*.yaml`（app + ingest + provision 三件） |
| 形态 | 两容器：`lfnovo/open_notebook` + `surrealdb:v2`（rocksdb；`-single` 变体上游已弃用） |
| 对外 | `notebook.meirong.dev` → HTTPRoute 只路由 **8502**（Next.js 前端把 `/api/*` 内部转发到 5055 的 FastAPI，5055 不直接对外） |
| 认证 | 应用自带 `OPEN_NOTEBOOK_PASSWORD`：浏览器走登录页；**API 走 `Authorization: Bearer <该口令>`**——它是公网 `/api/*` 的唯一屏障 |
| 探针 | startup/liveness 打 `:5055/health`（免鉴权、连得上 DB 才 200）；readiness 打 `:8502/` |

**为什么在 homelab 不在 oracle**：两台 DGX Spark 是跨 tailnet 共享节点，按"人"授予——
`meirongdev@` 的设备可达，oracle 的 tagged-device **在 netmap 里根本没有它们**。

> ⚠️ 2026-08-02 更正：原文还有一条理由"且书库 PVC 在本 ns"，**已不成立**——
> calibre 当天迁去了 oracle-k3s（书库 23G 是 homelab 那台 124GB 笔记本 VM 上最大的
> 单一数据集）。模型后端那条理由不受影响，Open Notebook 仍留在 homelab；
> 但**批量摄取 Job 跟着书走了**：它挂载书库 PVC，而 PVC 不能跨集群挂，
> 故现在跑在 oracle、经公网 `notebook.meirong.dev/api` 把文件推回来。
> 见 [../runbooks/open-notebook-ingest.md](../runbooks/open-notebook-ingest.md)。

## 模型接线（provisioner 声明式管理）

**真相源是 `k8s/helm/manifests/personal-services/open-notebook-provision.yaml`**（PostSync hook
幂等 reconcile，改模型 = 改它 + git push；不 prune UI 手工加的实验项）。当前指向：

| 角色 | 后端 | 模型 |
|---|---|---|
| 对话/转换/长上下文/工具（默认） | DGX vLLM `100.97.87.120:8000` | `deepseek-v4-flash`（1M ctx） |
| 对话兜底（非默认，UI 手动切） | Mac OMLX `100.89.15.120:8000` | Qwen3.6-35B（262k ctx） |
| Embedding | Mac OMLX | Qwen3-Embedding-4B（2560 维） |
| STT / TTS | Mac OMLX | Qwen3-ASR / Qwen3-TTS |

已知边界：

- **Rerank 无消费位**：Mac 已加载 Qwen3-Reranker 且 OMLX `/v1/rerank` 可用，但 Open Notebook
  v1.14 的 providers/defaults/search 三处都没有 rerank 概念——刻意未注册。
- **TTS 的 model test 永远 WARN**：上游 test 硬编码 voice=`alloy`；Qwen3-TTS 实际音色
  `serena/vivian/uncle_fu/ryan/aiden/ono_anna/sohee/eric/dylan`，做播客在 speaker profile 里选。
- **DGX 是跨境链路**（k8s-node 在 SG，spark 在 CN，DERP hkg 中继，RTT 66–83ms）：流式对话无感，
  逐条同步调用会被 RTT 吃掉。
- **Mac 是笔记本**，多模型按需换入换出；embedding 批任务与 TTS/35B 并发时延迟会跳。

## 配置真相源地图

| 什么 | 活在哪 | 丢了怎么办 |
|---|---|---|
| Deployment/Service/Route/探针 | git（manifests） | ArgoCD 重建 |
| 模型 credentials/models/defaults | git 声明（provisioner）→ SurrealDB | 任意一次 sync 的 hook 重建 |
| 摄取参数（notebook id / pattern / 上限） | git（`open-notebook-ingest.yaml` 的 params ConfigMap）| 即历史记录，"灌过什么"可追溯 |
| 三个密钥（encryption-key / app-password / surreal-password） | Vault `secret/homelab/open-notebook` → ESO | ⚠️ **encryption-key 丢失 = 库内所存模型凭据永久解不开** |
| notebooks / sources / 笔记 / 向量 | SurrealDB（PVC `open-notebook-surreal-local`） | restic 夜备的 `open-notebook.surql`（逻辑导出）恢复 |
| 对话线程状态 | `checkpoints.sqlite`（PVC `open-notebook-data-local`） | restic 夜备按 `*.sqlite*` 模式收录 |
| 上传原件 / 播客音频 | 同上 PVC，**不备份** | 书库里的可重灌；**UI 直传且不在书库的原件是唯一真丢项**（提取文本/向量仍在 DB） |

备份/恢复细节见 [../runbooks/backup-recovery.md](../runbooks/backup-recovery.md)（SurrealDB 走
HTTP `/export`/`/import`，与 Vault raft snapshot 同属"逻辑 dump"路线）。

## 运维备忘

- 轮换 `app-password`：`vault kv put`（三键一起写，KV v2 整体替换）→ ESO force-sync 注解 →
  **`kubectl rollout restart deploy/open-notebook`**（env 注入，不重启不生效）。
- 后台任务并发 `OPEN_NOTEBOOK_WORKER_MAX_TASKS=2`（5600H 热约束，别与 LGTM/Vault 抢 CPU）。
- HTTPRoute 首次部署若见 `ResolvedRefs=False/BackendNotFound`：Cilium 不会因 Service 后到而重算，
  给路由加个临时注解碰一下（详见 add-service 技能第 3 步）。
