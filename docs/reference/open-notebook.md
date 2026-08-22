# Open Notebook — AI 研读知识库（架构事实）

> Last updated: 2026-08-22
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
| STT | Mac OMLX | `Qwen3-ASR-1.7B-8bit` |
| TTS | Mac OMLX | `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`（9 个具名音色）|

### 语音模型换不动：调用口径把选择锁死了

Mac 上 2026-08-22 已有 6 个语音模型（新增的 4 个是 Mega-ASR / GLM-ASR-Nano /
TTS-VoiceDesign / chatterbox-multilingual-v3），**四个新的全部不采纳**，理由与实测数字见
[decisions/omlx-speech-model-selection.md](../decisions/omlx-speech-model-selection.md)。
挑模型前必须知道这两条口径 —— 它们比模型能力更能决定结果：

| | 调用方 | 实际发出去的 |
|---|---|---|
| TTS | `podcast_creator/nodes.py:273` | **只有 `text` / `voice` / `output_file`**。传不了音色描述，也传不了参考音频 |
| STT | `content_core/processors/media/audio.py:146` | 音频按 **10 分钟**切段 → 转 **mp3** → **不带 language 提示** → 多段并发。**单次请求最长 10 分钟** |

☠️ 由此推出两条反直觉的事：①**空音色表 = 不可用**（`/v1/audio/voices` 返回 `[]` 的 TTS
要 `instruct` 或参考音频，我们没有那个通道，换上去只在合成那一步 500）；
②**短句准确率几乎不影响 STT 选型**，能不能扛住 10 分钟才是 —— 两个新 ASR 在 571s 样本上
一个截断到只剩 8%、一个重复崩塌到 516%，**都返回 HTTP 200**。
换模型前先跑 ADR 末尾那段复现，只看开头一眼看不出来。

### 播客 profiles 是**第二套**接线，不吃上面这张表

☠️ `/models/defaults`（上表）与播客的 episode/speaker profile 是两套独立配置。前端的
`needsModelSetup()` 只看三个字段——episode 的 `outline_llm`/`transcript_llm`、speaker 的
`voice_model`——上游首启 seed 出来时**全是 null**。所以 defaults 七个位置全配好、
对话/embedding/STT 的 test 全绿，
Podcasts 页照样常驻黄条 `Setup required: Some profiles don't have models configured yet`
（2026-08-22 实测：3 个 episode + 3 个 speaker 全部未接线）。

第二层坑：**seed 的 `speaker.voice_id` 是 OpenAI 音色名**（`nova`/`alloy`/`echo`/`shimmer`/`ash`），
Qwen3-TTS 一律 `500 Speaker 'nova' not supported`。只补 `voice_model` 会让黄条消失、
播客却推迟到合成那步才炸——**音色必须一起换**。可用音色向后端现取，不要抄文档：

```bash
curl -s "http://100.89.15.120:8000/v1/audio/voices?model=mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
```

现由同一个 provisioner 的 `EPISODE_PROFILE_LLMS` / `SPEAKER_VOICES` / `PODCAST_LANGUAGE`
纳管（read-modify-write：`PUT` 收的是 *Create* 模型即整体替换，故 seed 的文案/backstory
原样回填，只覆盖这几个字段）。当前音色分配：

| speaker profile | 音色 |
|---|---|
| `tech_experts` | Dr. Alex Chen → `eric` · Jamie Rodriguez → `aiden` |
| `business_panel` | Marcus Thompson → `ryan` · Elena Vasquez → `serena` · Johny Bing → `dylan` |
| `solo_expert` | Professor Sarah Kim → `vivian` |

- 音色按 profile 内不重复分配；**性别是按名字推的，没逐个试听**。
- 播客语言 `PODCAST_LANGUAGE` 目前 `None`（沿用上游默认的英文）；要中文播客填 `"zh"`。
- 声明了后端不认的音色时 provisioner **拒绝写入并只告警**（黄条继续亮 = 告警本身），
  不把已知坏值落库；Mac 睡着取不到白名单则跳过校验。

已知边界：

- **Rerank 无消费位**：Mac 已加载 Qwen3-Reranker 且 OMLX `/v1/rerank` 可用，但 Open Notebook
  v1.14 的 providers/defaults/search 三处都没有 rerank 概念——刻意未注册。
- **TTS 的 model test 永远 WARN**：上游 test 硬编码 voice=`alloy`，Qwen3-TTS 不认。
  这条只是 test 的显示问题（功能本身好的：voice=`serena` 直打出真 WAV）；
  ⚠️ 但**别把它当孤立瑕疵**——同一个原因也让 seed 的 speaker profile 生不出播客，见上一节。
- **mp3 是默认口径且 OMLX 支持**：esperanto 的 TTS 默认 `response_format=mp3`，STT 侧的分段也重编码成 mp3 —— 2026-08-22 实测 OMLX 两头都吃（TTS 出 MPEG ADTS、STT 收 mp3 正常），播客合成不会在这里炸。
- **DGX 是跨境链路**（k8s-node 在 SG，spark 在 CN，DERP hkg 中继，RTT 66–83ms）：流式对话无感，
  逐条同步调用会被 RTT 吃掉。
- **Mac 是笔记本**，多模型按需换入换出；embedding 批任务与 TTS/35B 并发时延迟会跳。

## 配置真相源地图

| 什么 | 活在哪 | 丢了怎么办 |
|---|---|---|
| Deployment/Service/Route/探针 | git（manifests） | ArgoCD 重建 |
| 模型 credentials/models/defaults | git 声明（provisioner）→ SurrealDB | 任意一次 sync 的 hook 重建 |
| 播客 profiles 的模型/音色接线 | 同上 provisioner（**profile 文案/backstory 仍只活在 DB**，是上游 seed 的默认值、非我们的决策，故不纳管） | hook 重建接线；文案随 SurrealDB 恢复 |
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
