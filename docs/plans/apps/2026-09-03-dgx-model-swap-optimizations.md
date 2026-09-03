# DGX 换模型提速：把「事故式切换」变成「改一个值 + 跑两条命令」

> 日期: 2026-09-03
> 状态: 📐 设计（未实施，等一个愿意投入半天到两天的窗口）
> 结论: 2026-09-02 那次换栈的手工成本是 **16 处 git 字面值 + 8 把虚拟 key 白名单 + 3 条监控阈值
>       + 7 项现场采集**，且全靠人肉记忆串联。做完 P0 三件（CI 字面值门禁 / 契约回归脚本 /
>       key 卫生）后，下一次的成本应降到「改 1 个声明值 + 跑 2 条命令 + 核 5 条验收」，
>       漏改由 CI 红灯与一条新告警分别兜住。
> 关联: [换栈 SOP](../../runbooks/dgx-model-swap-homelab-followup.md)（本文是它 §8「后续优化」的展开）·
> [ROADMAP 开放项](../../ROADMAP.md)· [litellm-gateway.md](../../reference/litellm-gateway.md) 坑 A/B

---

## 1. 先把「这次到底有多贵」量化

数字是 2026-09-03 现拉的，不是回忆。复跑方法见每行最后一列。

| 成本项 | 数量 | 怎么复核 |
|---|---|---|
| git 里的模型名**功能值**（写错就坏） | **16 处 / 5 个文件** | `rg -N -n 'qwen38-flash-next' -g '!docs/**' \| grep -v '#'` |
| └─ 其中 litellm 网关 | 4（两个别名 × `model_name` + `model:`） | `k8s/helm/manifests/litellm/litellm.yaml` |
| └─ 其中 Open Notebook provisioner | **8**（1 个 MODELS + 4 个 DEFAULTS 角色 + 3 个播客 profile） | `k8s/helm/manifests/personal-services/open-notebook-provision.yaml` |
| └─ 其中 calibre 元数据 | 2（内嵌脚本的 env 默认值 + CronJob 的 env） | `cloud/oracle/manifests/calibre-metadata/metadata-llm.yaml` |
| └─ 其中 jobs-sg 富化 | 1（`LLM_MODELS`，直连 DGX） | `k8s/helm/manifests/jobs-sg/cronjob-enrich.yaml` |
| └─ 其中告警 description | 1（`DgxSparkVllmDown` 正文里的名字） | `k8s/helm/manifests/monitoring/alerts/prometheus-rules.yaml` |
| git 里的**注释/文档**提及（不致命但会误导后来人） | 非 docs 14 行 + docs 5 篇 12 处 | 同上去掉 `grep -v '#'` |
| Postgres 里的虚拟 key 白名单 | 2026-09-02 那次 **8/16 把**受影响 | SOP §3 |
| 需要重估的监控阈值 | 3（冷启动 → `for:`、KV 上限 → queued 阈值、ctx → Open Notebook 长上下文角色） | SOP §4 |
| 切换前必须采的现场事实 | 7 项 | SOP §1 |

☠️ **最贵的一条不在表里**：白名单在 Postgres，git 管不到。只做 git 侧 = 「清单正确 +
ArgoCD Synced + 调用全 403」，而且没有任何告警会说（坑 A）。任何"少改几处"的优化都不许
把这一半藏起来。

## 2. 本轮实测的四条事实（它们决定了下面为什么这样设计）

| # | 实测事实 | 怎么验的 | 对方案的影响 |
|---|---|---|---|
| 1 | **vLLM 指标自带 `model_name` 标签**，且 `job_name: 'vllm-dgx-spark'` 已经在抓 `100.97.87.120:8000/metrics`（15s 间隔） | `curl -s :8000/metrics \| rg model_name` + `k8s/helm/values/kube-prometheus-stack.yaml` 的 static_configs | **哨兵只需一条 PromQL，零新组件**，也不用碰 tagged-device 的 nodeSelector 问题（抓取本来就通）。这**取代** SOP §8 原本设想的「json-exporter/blackbox 抓 `/v1/models` 导出指标」 |
| 2 | 这版 vLLM（v1.94.1）**没有 per-model 健康端点**：`/health/<name>`、`/v1/models/<name>` 全 404 | 现网 `curl -o /dev/null -w '%{http_code}'` | 「按模型名探活」这条路不存在，只能走指标标签（事实 1）或真发一次生成（P0-2） |
| 3 | **16 把虚拟 key 只有 1 把有 alias**（`calibre-metadata-llm`），且**其中 4 把的白名单里还挂着已死的 `mac/qwen3.6-35b`** | master key 走 `GET /key/list?page_size=50&page=N` + 逐把 `/key/info?key=<sha256>`（Cloudflare 会对非浏览器 UA 回 1010，必须直连 `http://100.94.186.7:31400`） | key 清扫现在只能靠 sha256 前缀猜"这把是谁"；顺带暴露一个**当下就存在**的缺陷：那 4 把的 fallback 目标是死的 |
| 4 | `scripts/check-version-pairs.py` 的 **V2 只能按「变量名」取值**（`VAR_RE` 只有 justfile / yaml 两种正则） | 读脚本 `find_var()` | 模型名出现在 env value、YAML 内联 list、以及**内嵌 Python 字符串**里，V2 吃不下 → 需要一条**新的字面值断言**，而不是硬塞进 `DECLARED_PAIRS`（硬塞的代价是假违规红灯，正是该脚本刻意不收 `node_exporter_version` 时躲开的那类噪音） |

## 3. P0：一次切换里最容易漏、又最便宜能堵住的三处

### P0-1 给 served name 加字面值门禁（CI）

真相源放 `versions.just`：

```just
dgx_served_model := "qwen38-flash-next"
```

新断言（下称 V5，与 V1–V4 并列，同一条 `uv run --with pyyaml python scripts/...` 跑）：
声明的文件清单里，**每一处非注释位置的 DGX 模型字面值必须等于 `dgx_served_model`**；
`custom_dgx/`、`openai/` 这两个前缀按前缀剥离后比较。

- 豁免沿用现有的行内约定（`version-pair-ok: <理由>`）。☠️ **必须能逐行豁免**：
  非 docs 文件里那 14 行注释是历史（"原来是 deepseek-v4-flash"），不许改写成新名字，
  也不许让门禁长期红 —— 红灯噪音会让整条检查被无视，这是 V2 的设计原则。
- 文档正文（`docs/`）**不纳入断言**，只纳入 runbook 的验收清单：docs 里 12 处提及大部分是历史叙述。
- 文件清单写死在脚本里，并**同时断言清单指向的文件真实存在**（V2 已有 `V0` 这类检查，复用）。
  新加消费方时忘了登记，代价是门禁少看一处，不是误伤。

验收：故意把 `metadata-llm.yaml` 改回旧名 → CI 红；把那行改成带 `version-pair-ok:` 的注释 → CI 绿。

### P0-2 `scripts/dgx-model-probe.py`：契约回归，一条命令

这次是手打的判据，全部保留成脚本。**判据只认 `usage` 字段**，因为
`chat_template_kwargs {"thinking": false}` 在新栈上是**静默空操作**（回 200、不报错、不生效），
任何基于状态码的校验原理上看不见它。

| 断言 | 为什么是它 |
|---|---|
| 用**消费方自己的提示词**打一次，响应 `content` 能 `json.loads` | 提示词从 calibre 的 ConfigMap `PROMPT` 与 jobs-sg 的 `ExtractPrompt` 现取，不另写一份玩具 prompt——玩具 prompt 过不了真实护栏 |
| `finish_reason != length` | 截断产出的 JSON 看起来"像坏了"，实际是预算问题 |
| tokens 在预算内 | 新栈 ctx 从 1M 变 262144，按旧值做的规划会静默超窗 |
| 带 `tools` 的请求回 `finish_reason=tool_calls` | 一切 agentic 消费方的前提 |
| 关思考后 `usage.completion_tokens_details.reasoning_tokens == 0` | 唯一能识破 kwargs 名换了的判据；同时把"该栈认哪个 kwargs 名"打印出来，供 jobs-sg 侧对齐 |

执行窗口：新栈冷启动那 8–11 分钟正好是它的运行时间，于是切换从「盲切」变成「先验后切」。
支持 `--base-url`（默认 DGX 裸端点，也支持指网关别名）+ `--model`。

### P0-3 key 卫生（顺带修一个当下就坏的缺陷）

1. 给 15 把无 alias 的 key 补 alias（`jobs-sg-enrich`、`codex-<machine>` 这类），
   以后 `rg` 不出"这把是谁"这种事不再发生。
2. 清掉 4 把里已死的 `mac/qwen3.6-35b`，换成 `mac/ornith` —— **这 4 把现在的 fallback 是坏的**。
3. 把「期望白名单」落成 git 里的一份文件（alias → models 集合），
   加一条 `just` recipe 拉现网做 diff。这样 §1 表里最贵的那一半至少**可核对**。
4. 顺带验证一个未决问题：**fallback 是否也被 key 白名单 gate**（那 4 把缺 `mac/ornith`
   就是天然实验组）。结论回写 `reference/litellm-gateway.md` 坑 A。

## 4. P1：把重复劳动本身删掉

### P1-1 漂移哨兵 = 一条 PromQL 规则

```yaml
- alert: DgxServedModelDrift
  expr: absent(vllm:num_requests_running{job="vllm-dgx-spark",
                                         model_name="qwen38-flash-next"})
        and on() up{job="vllm-dgx-spark"} == 1
  for: 10m
  labels: {severity: warning, component: inference}
```

- `and on() up == 1` 那半边**不可省**：否则引擎正常重启（`make qwen38fn-restart`，
  加载 8–11 分钟）期间它和 `DgxSparkVllmDown` 一起刷屏。
- 期望值来自 `versions.just` 那个声明值（P0-1 同源），所以改模型时**漏改这里也会被门禁抓到**。
- ☠️ 它的边界要写进 annotation：**只认"名字变了"**。名字没变但权重/量化换了（同 served name
  重刷权重）它原理上看不见——那是 P0-2 的职责。
- ☠️ 也**不许**把它写成"抓得到 = 活着"：僵尸 TP 组下 `/health`、`/v1/models`、指标抓取
  全都正常，这正是 `DgxSparkVllmStuck` 存在的理由。本规则不替代它，只补"名字漂移"这一格。

落地时同步改 `docs/ROADMAP.md` 那条"②给 served name 加哨兵"与本 SOP §8 的形态描述。

### P1-2 字面值收敛：16 → 8

| 位置 | 现在 | 改成 | 之后 |
|---|---|---|---|
| Open Notebook provisioner | 8 处写死在 `MODELS`/`DEFAULTS`/`EPISODE_PROFILE_LLMS` | 脚本顶部 `DGX_MODEL = os.environ.get("DGX_MODEL", "<名字>")`，三处 dict 全部引用它 | 1 处 |
| calibre 元数据 | 2 处（内嵌脚本 env 默认值 + CronJob env） | 内嵌脚本去掉硬默认值、只认 env（缺了就 fail fast） | 1 处 |
| litellm 网关 | 4 处 | **不动** —— YAML 锚点不能拼字符串，为了少改而引入生成层不划算 | 4 处 |
| jobs-sg env / 告警 description | 各 1 | 不动 | 2 处 |

合计 **16 → 8**，且剩下的 8 处全部在 P0-1 门禁覆盖内。

☠️ **这两个内嵌脚本都不在 E1（`check-embedded-scripts.py`）的覆盖里**，实测：
`TARGETS` 只有 cf-analytics-exporter，`STAMP_ONLY` 只有 litellm 路由表与 homepage 六块。
所以改它们**不需要** `just gen-embedded-scripts`，也**不会**踩 E1 那个"ConfigMap 变了 pod
不重启"的坑 —— 原因各自不同，别当成通则：

- Open Notebook provisioner 是 ArgoCD **PostSync hook Job**（`hook-delete-policy:
  BeforeHookCreation,HookSucceeded`）→ 每次 sync 都重建重跑，天然带"生效"；
- calibre 那份是 **CronJob**，每次排程都是新 pod，读的是当时的 ConfigMap。

真正需要 `just gen-embedded-scripts` 的只有 litellm 那份路由表（subPath 挂载 + 进程只在
启动时读），也就是 SOP §2 反复强调的那一步。

### P1-3 `just dgx-swap`：一条命令走完 SOP §1–§5

`--from <old> --to <new> [--dry-run]`，顺序：采集（served name / `max_model_len` /
`kv_cache_max_concurrency` vs `--max-num-seqs` / 冷启动）→ 按新名打 4 处清单 →
`just gen-embedded-scripts` → key 的 **DRY-RUN 新旧对照表**（要落库需再点一次头）→
打印 SOP 那 5 条验收命令。

骨架这次已经全部踩通，脚本化只是搬运。⚠️ 落库那步必须保守：
`/key/update` 是**整表替换**，脚本必须先读原列表、只映射要改的项、其余原样带回；
列 key 用 `GET /key/list`（`POST` 是 405）+ 分页，`models` 只在 `/key/info` 里。

## 5. P2：把"人肉调阈值"变成断言

- 把**冷启动分钟数**与 **KV 并发上限**也当声明量存起来，CI 断言
  `DgxSparkVllmDown.for` ≥ 冷启动 ×1.5、`DgxSparkRequestsQueued` 阈值 ≤ KV 上限。
  这次的 `10m → 15m` 是刻意**不取** 2 倍余量（理由写在告警注释里），这种取舍该由断言记着，
  而不是靠下一个人读懂注释。
- **跨仓库契约**：`nv-dgx-spark` 侧的权重/镜像保留期 = 本仓库的回滚窗口。希望上游换栈前
  先跑一次 P0-2 的 probe，并把保留期写进他们自己的 ADR。这是**请求**，不是本仓库能强制的。
- **待测**：虚拟 key 白名单能不能用通配（现网已有 `nvidia/*`、`openrouter/*` 的先例）。
  若对 `custom_openai` 部署也生效，P0-3 的清扫就彻底消失 —— 见 §6 第二条的取舍。

## 6. 明确不做（以及为什么）

1. **不把网关别名改成"与模型无关的稳定名"**。它确实最省事，但代价是让"清单写 deepseek、
   实际给 Qwen"这种谎话进网关，结论与代价已记在
   [decisions/litellm-llm-gateway.md](../../decisions/litellm-llm-gateway.md) 的 2026-09-03 修订。
   省下的手工量正是靠隐瞒"现在到底是谁在服务"换来的，不划算。
2. **不擅自放宽 key 白名单换省事**（§5 的通配那条）。ACL 从"哪把 key 能调哪个模型"
   降级成"哪把 key 能调 DGX"，动的是「越权不了」这个既有口径，是要人拍板的取舍，
   不是实现细节。所以它停在"待测"，不进 P0。
3. **不追求"抓得到就算活着"的探活**。见 P1-1 的 ☠️ 那条。

## 7. 做完之后的预期成本

| 阶段 | 这次（2026-09-02/03） | P0+P1 落地后 |
|---|---|---|
| 采集 7 项事实 | 手打命令，现场决定改哪些 | 一条命令出表（P1-3） |
| 改 git 引用 | 16 处人肉搜替 | 改 `versions.just` 1 行 + 脚本打 4 处 + 门禁确认 0 残留 |
| 行为验收 | 手打 5 个判据 | `dgx-model-probe.py` 一次，判据固定 |
| key 白名单 | 逐把 `/key/info` 对照，靠 sha256 猜归属 | alias + git 期望表 diff + DRY-RUN 对照（仍可核对、不可漏） |
| 发现上游偷跑换栈 | 等第一个 404 | `DgxServedModelDrift` warning |

不在收益里的：上游权重加载 8–11 分钟、跨境共享机器的排队、以及"名字没变但权重变了"
仍需真发一次生成才能发现。这三条是物理与语义限制，工具只能压缩操作时间，不能让它们消失。

## 8. 与现有文档的关系

- [runbooks/dgx-model-swap-homelab-followup.md](../../runbooks/dgx-model-swap-homelab-followup.md)
  仍是**唯一 SOP**（怎么做、验收、回滚）。本文只回答"下次怎么更省"，实施细节以本文为准。
- 本文 P1-1 取代 SOP §8 第 2 条设想的 json-exporter 形态；SOP 已加指针，两处不再各存一份。
- 实施完成后：稳定结论回 `reference/litellm-gateway.md`（新增的告警/门禁/recipe 是**事实**），
  ROADMAP 关掉对应条目，本文冻结为历史快照，不再维护。
