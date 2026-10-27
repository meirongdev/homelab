# Open Notebook — AI 研读知识库（架构事实）

> Last updated: 2026-10-28
> Status: 生效事实
> Scope: Open Notebook（NotebookLM 自托管替代）在 homelab 集群的部署形态、模型接线、
> 配置真相源地图、备份口径，本文是 source of truth。
> 批量摄取操作见 [../runbooks/open-notebook-ingest.md](../runbooks/open-notebook-ingest.md)；
> 部署过程与踩坑见 [../plans/2026-08-01-open-notebook-homelab.md](../plans/2026-08-01-open-notebook-homelab.md)（冻结快照）。

## 部署形态

| 项 | 值 |
|---|---|
| 集群 / ns | homelab / `personal-services`（ArgoCD `personal-services` App，目录源自动纳管） |
| 清单 | `k8s/helm/manifests/personal-services/open-notebook*.yaml`（app + provision）；摄取 Job 在 oracle 的 `cloud/oracle/manifests/personal-services/open-notebook-ingest.yaml` |
| 形态 | 两容器：`lfnovo/open_notebook` + `surrealdb:v2`（rocksdb；`-single` 变体上游已弃用） |
| 对外 | `notebook.meirong.dev` → HTTPRoute 只路由 8502（Next.js 前端把 `/api/*` 内部转发到 5055 的 FastAPI，5055 不直接对外） |
| 认证 | 应用自带 `OPEN_NOTEBOOK_PASSWORD`：浏览器走登录页；**API 走 `Authorization: Bearer <该口令>`**，它是公网 `/api/*` 的唯一屏障 |
| 探针 | startup/liveness 打 `:5055/health`（免鉴权、连得上 DB 才 200）；readiness 打 `:8502/` |

**为什么在 homelab 不在 oracle**：两台 DGX Spark 是跨 tailnet 共享节点，按"人"授予，
`meirongdev@` 的设备可达，oracle 的 tagged-device 在 netmap 里根本没有它们。
批量摄取 Job 则跟着书库在 oracle（它挂书库 PVC，PVC 不能跨集群），经公网
`notebook.meirong.dev/api` 把文件推回来，见 [摄取 runbook](../runbooks/open-notebook-ingest.md)。

## 模型接线（provisioner 声明式管理）

**真相源是 `k8s/helm/manifests/personal-services/open-notebook-provision.yaml`**（PostSync hook
幂等 reconcile，改模型 = 改它 + git push；不 prune UI 手工加的实验项）。当前指向：

| 角色 | 后端（凭据） | 模型 |
|---|---|---|
| 对话/转换/长上下文/工具（默认） | DGX vLLM `100.97.87.120:8000`（`dgx-vllm`） | `qwen3.8-flash-next-tp2`（262k ctx） |
| 对话兜底（非默认，UI 手动切） | Mac OMLX `100.89.15.120:8000`（`mac-omlx`） | `ornith-ai__Ornith-1.5-35B-A3B-MLX-4bit`（262k ctx） |
| Embedding | Mac OMLX | Qwen3-Embedding-4B（2560 维） |
| STT | Mac OMLX | `Qwen3-ASR-1.7B-8bit` |
| TTS | Mac OMLX | `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`（9 个具名音色）|

上游模型的事实（served name / 端点 / ctx / 冷启动 / 回滚）以
[litellm-gateway.md](litellm-gateway.md) 的「DGX 主力栈」为准。Open Notebook 不走网关，
模型名必须与裸引擎的 served name 逐字相同。

⚠️ `mac-omlx` 凭据填的是 `api_key: "dummy"`，能用**只是因为** Mac 上开着
`allow_unauthenticated_inference: true`。它一丢，Mac 那四个角色一起 401，见
[omlx-inference-metrics.md 的「鉴权」](omlx-inference-metrics.md#鉴权omlx-07-起)。

### ☠️ DGX 换主力栈时要核的三件事

1. **长上下文有硬上限 262144**：`large_context_model` 与三个播客 episode profile 塞整本书会
   超窗，兜底的 Mac Ornith 也是 262k。长书截断或报超窗时先按这条判，别先怀疑上游挂了。
2. **端点与模型名一起核**：凭据 `dgx-vllm` 的 `base_url` 也会随栈变。served name 用
   `curl -s http://100.97.87.120:8000/v1/models`（本机任意目录）核。vLLM 下名字写错当场 404；
   SGLang 一类引擎接受任意 model 名并原样回显，写错是静默的。凭据名**刻意不随引擎改名**
   （provisioner 只增不删，改名只会多一条死凭据）。
3. **改名不带走旧条目**：unmanaged models 只打 note，旧条目得在 UI 手删。删前确认没有引用，
   ☠️ **判据是直查 SurrealDB 全部表**（`ws://open-notebook-surrealdb…` 的 HTTP `/sql`，
   `INFO FOR DB` 取表名后逐表 `SELECT *` 再 grep model id），别只扫 API：本版本
   `/podcasts`、`/search-templates` 是 404，扫不到不代表没有。
   - ⚠️ 遗留条目 `qwen3.8-27b-sglang` 截至 2026-10-04 仍在 `/api/models`（默认角色已不指向它），
     选中当场 404，删前照上面扫一遍。
   - ⚠️ **`mlx-community__Qwen3.6-35B-A3B-nvfp4` 看着像遗留但不要删**：OMLX 仍在提供，是可用备选。

### 语音模型换不动：调用口径把选择锁死了

Mac 上另有 4 个新语音模型全部不采纳，理由、实测与复现见
[decisions/omlx-speech-model-selection.md](../decisions/omlx-speech-model-selection.md)。
决定结果的是两条调用口径而不是模型能力：TTS（`podcast_creator/nodes.py:273`）只发
`text` / `voice` / `output_file`，所以 `/v1/audio/voices` 返回 `[]`、要 `instruct` 或参考音频的
TTS 不可用（只在合成那步 500）；STT（`content_core/processors/media/audio.py:146`）按 10 分钟
切段，所以能不能扛住 10 分钟才是判据，☠️ 两个新 ASR 在长音频上一个截断、一个重复崩塌，
**都返回 HTTP 200**。换模型前先跑 ADR 末尾那段复现。

### 播客 profiles 是第二套接线，不吃上面这张表

`/models/defaults`（上表）与播客的 episode/speaker profile 是两套独立配置。前端的
`needsModelSetup()` 只看三个字段（episode 的 `outline_llm`/`transcript_llm`、speaker 的
`voice_model`），上游首启 seed 出来全是 null，所以 defaults 全配好、test 全绿，Podcasts 页
照样常驻黄条 `Setup required: Some profiles don't have models configured yet`。

第二层：**seed 的 `speaker.voice_id` 是 OpenAI 音色名**（`nova`/`alloy`/`echo`/`shimmer`/`ash`），
Qwen3-TTS 一律 `500 Speaker 'nova' not supported`。只补 `voice_model` 会让黄条消失、播客推迟到
合成那步才炸，**音色必须一起换**。可用音色向后端现取，不要抄文档：

```bash
curl -s "http://100.89.15.120:8000/v1/audio/voices?model=mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
```

现由同一个 provisioner 的 `EPISODE_PROFILE_LLMS` / `SPEAKER_VOICES` / `PODCAST_LANGUAGE` 纳管。
它是 read-modify-write：`PUT` 收的是 *Create* 模型即整体替换，故 seed 的文案/backstory 原样回填，
只覆盖这几个字段。

- 音色分配以清单的 `SPEAKER_VOICES` 为准（三个 speaker profile `tech_experts` / `business_panel` /
  `solo_expert`，profile 内不重复；性别按名字推的，没逐个试听）。声明了后端不认的音色时
  provisioner 拒绝写入只告警（黄条继续亮就是告警本身）；Mac 睡着取不到白名单则跳过校验。
- `PODCAST_LANGUAGE` 目前 `None`（上游默认英文），要中文播客填 `"zh"`。

### 已知边界

- **Rerank 无消费位**：Mac 的 OMLX `/v1/rerank` 可用，但 Open Notebook v1.14 的
  providers/defaults/search 都没有 rerank 概念，刻意未注册。
- **TTS 的 model test 永远 WARN**：上游 test 硬编码 voice=`alloy`，Qwen3-TTS 不认。功能本身是好的
  （voice=`serena` 直打出真 WAV），但同一个原因让 seed 的 speaker profile 生不出播客，见上一节。
- mp3 是默认口径（esperanto TTS 默认 `response_format=mp3`，STT 分段也重编码成 mp3），OMLX
  两头都吃，不是故障点。
- **DGX 是跨境链路**（k8s-node 在 SG，spark 在 CN，经 DERP hkg 中继，RTT 数十 ms）：流式对话无感，
  逐条同步调用会被 RTT 吃掉。
- **Mac 是笔记本**，多模型按需换入换出，embedding 批任务与 TTS/35B 并发时延迟会跳。
  ☠️ 被选中卸载的模型进入 `unload pending` 后对所有请求报 `is busy`，直到对面在飞的请求跑完，
  会整集打掉播客。重试耐心已从上游 ~15s 提到 ~135s（`PODCAST_RETRY_*`），仍跨不过一个
  10 分钟音频的 STT 请求，所以在 Mac 上跑批量模型活儿时别同时生成播客。→
  [records/2026-08-22-podcast-tts-unload-pending.md](../records/2026-08-22-podcast-tts-unload-pending.md)

## 配置真相源地图

| 什么 | 活在哪 | 丢了怎么办 |
|---|---|---|
| Deployment/Service/Route/探针 | git（manifests） | ArgoCD 重建 |
| 模型 credentials/models/defaults | git 声明（provisioner）→ SurrealDB | 任意一次 sync 的 hook 重建 |
| 播客 profiles 的模型/音色接线 | 同上 provisioner（profile 文案/backstory 只活在 DB，是上游 seed 的默认值、非我们的决策，不纳管） | hook 重建接线；文案随 SurrealDB 恢复 |
| 摄取参数（notebook id / pattern / 上限） | git（`open-notebook-ingest.yaml` 的 params ConfigMap）| 即历史记录，"灌过什么"可追溯 |
| 三个密钥（encryption-key / app-password / surreal-password） | Vault `secret/homelab/open-notebook` → ESO | ⚠️ **encryption-key 丢失 = 库内所存模型凭据永久解不开** |
| notebooks / sources / 笔记 / 向量 | SurrealDB（PVC `open-notebook-surreal-local`） | restic 夜备的 `open-notebook.surql`（逻辑导出）恢复 |
| 对话线程状态 | `checkpoints.sqlite`（PVC `open-notebook-data-local`） | restic 夜备按 `*.sqlite*` 模式收录 |
| 上传原件 / 播客音频 | 同上 PVC，不备份 | 书库里的可重灌；**UI 直传且不在书库的原件是唯一真丢项**（提取文本/向量仍在 DB） |

备份/恢复细节见 [../runbooks/backup-recovery.md](../runbooks/backup-recovery.md)（SurrealDB 走
HTTP `/export`/`/import`，与 Vault raft snapshot 同属"逻辑 dump"路线）。

## 运维备忘

- 轮换 `app-password`：`vault kv put secret/homelab/open-notebook …`（三键一起写，KV v2 整体替换）
  → ESO 立即同步 → 重启（env 注入，不重启不生效）：

  ```bash
  kubectl --context k3s-homelab -n personal-services annotate externalsecret open-notebook-secret \
    force-sync="$(date +%s)" --overwrite
  kubectl --context k3s-homelab -n personal-services rollout restart deploy/open-notebook
  ```
- 后台任务并发 `OPEN_NOTEBOOK_WORKER_MAX_TASKS=2`（5600H 热约束，别与 LGTM/Vault 抢 CPU）。
- HTTPRoute 首次部署若见 `ResolvedRefs=False/BackendNotFound`：Cilium 不会因 Service 后到而重算，
  给路由加个临时注解碰一下，见 [runbooks/add-service.md](../runbooks/add-service.md) 步骤 3。
