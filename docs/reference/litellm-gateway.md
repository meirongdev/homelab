# LiteLLM 网关（运维事实与坑）

> Last updated: 2026-11-15
> Status: 生效事实
> Scope: `llm.meirong.dev` 这个 LLM 网关的配置生效路径、鉴权分层、上游可用性边界，
> 本文是 source of truth。为什么选 LiteLLM、上游怎么选、兜底为何几经更换（Qwen3.6 → Ornith → Studio），见
> [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md)（决策与实测数据）。

## 速览

| | |
|---|---|
| 集群 / ns | homelab / `litellm`（**钉控制面**，只有它的 netmap 里有 DGX 与 Mac）|
| 公网入口 | `llm.meirong.dev`（Cloudflare Tunnel → Cilium Gateway → HTTPRoute）|
| tailnet 入口 | `100.94.186.7:31400`（NodePort Service `litellm-external`）。oracle 的作业和管理接口都走这里：经 Cloudflare 调管理接口会被 WAF 以 `error code: 1010`(403) 挡（非浏览器 UA）|
| 推理鉴权 | master key + 虚拟 key（`Authorization: Bearer sk-…`）|
| 管理面 | `/ui`，LiteLLM 自带登录（`UI_USERNAME`/`UI_PASSWORD`，Vault→ESO）|
| 路由表 | `k8s/helm/manifests/litellm/litellm.yaml` 的 ConfigMap（在 git 里）|
| key / spend | 同集群共享 Postgres `databases/apps-pg` 的 `litellm` 库（**不在 git 里**，见坑 A）|

**配置真相源分成两半，这是本文档存在的理由**：

| 东西 | 存在哪 | 改法 |
|---|---|---|
| 模型列表 / `api_base` / `fallbacks` | git 的 ConfigMap | 改清单 → push → ArgoCD |
| **虚拟 key 能访问哪些模型** | Postgres | 只能调 API（坑 A）|
| 花费账本 / key 有效期 | Postgres | `/ui` 或 API |

### 别名

| 别名 | 上游 | 兜底 |
|---|---|---|
| `DeepSeek-V4.1-Flash-1017` | DGX（下节）。☠️ **临时（2026-11-15 起）改由 Studio 的 Qwen3.8-27B 作答**：DGX `:8000` 拒绝连接；客户端照旧用这个名字、key 白名单不动，DGX 恢复后 revert 切回（[ROADMAP #22](../ROADMAP.md)）| → `studio/qwen3.8-27b`（`router_settings.fallbacks`，坑 A2；2026-11-15 前是 `mac/ornith`）。临时期间清空：主上游就是 Studio |
| `custom_dgx/DeepSeek-V4.1-Flash-1017` | DGX | 刻意不配：给「就要打 DGX」的消费方，静默换成别的模型反而有害（DGX 不通时如实报连接错误）|
| `mac/ornith` / `mac/ornith-fast` | M2 的 OMLX，Ornith-1.5-35B-A3B；`-fast` 走 OMLX 的 `fast` profile（关思考），两者共用同一份驻留权重 | —（2026-11-15 前 `mac/ornith` 是 DGX 的兜底）|
| `studio/qwen3.8-27b` | Mac Studio 的 OMLX（见「Mac Studio 上游」）| 自己没有兜底；它是 DGX 裸别名的兜底目标（2026-11-15 起）|
| OMLX 模型 ID 原文 ×4：`ornith-ai__Ornith-1.5-35B-A3B-MLX-4bit`、`mlx-community__Qwen3-Embedding-4B-4bit-DWQ`（embedding）、`mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`（TTS）、`mlx-community__Qwen3-ASR-1.7B-8bit`（ASR）| M2 的 OMLX | 给 open-notebook：它的模型按名字绑在凭据上、改名要删了重建，所以网关按原名建别名（2026-11-11）|
| `openrouter/*` | OpenRouter 全量透传 | 免费档不能当兜底（见「哪些模型能免费用」）|

## DGX 主力栈：DeepSeek-V4.1-Flash-1017 双机 TP=2（TensorFold，2026-11-15 起）

上游 `~/projects/meirongdev/nv-dgx-spark` 单方面换栈，本仓库只跟着改引用；本节是本仓库关于该上游的唯一真相源
（换栈理由与压测在上游仓库）。☠️ 再换模型或回滚，照
[runbooks/dgx-model-swap-homelab-followup.md](../runbooks/dgx-model-swap-homelab-followup.md) 走（改哪几处、为什么必须动 key、
哪些阈值要重估、怎么验收，改本节也是其中一步）。减负方案
[plans/2026-09-03-dgx-model-swap-optimizations.md](../plans/2026-09-03-dgx-model-swap-optimizations.md) 📐 未实施，门禁还不存在。

下表除注明外均为 2026-11-15 直连 `:8000` 实测。

| | |
|---|---|
| 上游栈 id | `dsv41`（DeepSeek-V4.1-Flash-1017 EXL3 2.9bpw，MiaAI-Lab recipe），定义在上游 `stacks/dsv41/stack.env`（上游标 `candidate`，截至 11-15 未提交、`stacks/PRIMARY` 仍是旧栈 `hibrid48tp2v52`）|
| served name | `DeepSeek-V4.1-Flash-1017` |
| 端点 | `100.97.87.120:8000/v1`（head 在 S1，与上一栈同端口）|
| 引擎 | TensorFold（Zig）。☠️ **模型名写错照常 200**（与 SGLang 同类，vLLM 才 404），响应体的 `model` 是真名；判据只能是 `/v1/models` 或响应里的 `model` |
| `max_model_len` | 524288（上一栈 262144）。⚠️ 兜底的 Studio Qwen3.8-27B 只有 262k，超过的请求 DGX 出错时兜底接不住 |
| 拓扑 / 冷启动 | 双机 TP=2（rank0 + API 在 S1，rank1 在 S2）。11-15 实测 `loaded in 31.0s`（权重在页缓存里；冷缓存每台要读约 98 GiB，会久得多）。☠️ 两个 rank 必须成对起停，只用上游 `make restart` |
| 自愈 | 容器 `restart=no`、无 healthcheck。引擎日志说 rank 对断开时以 status 75 退出「供两个 rank 一起重启」，外层是否真会重启未核实 |
| 并发 | ☠️ `/health` 报 `max_batch_size: 4`（上一栈 vLLM 是 64），第 5 路起排队。jobs-sg 的 `LLM_CONCURRENCY` 已随之 8→4 |
| 关思考 | `chat_template_kwargs {"enable_thinking": false}` 生效；旧键 `{"thinking": false}` 在这个栈上**也**生效（Qwen 栈上是静默空操作）|
| `reasoning_effort` | `none` / `minimal` / `low` / `medium` / `high` / `xhigh` / `max` 七档全收；不认识的值回 400 `reasoning_effort must be none, minimal, low, medium, high, xhigh or max`。6000 字真实提示词上 `medium` 确实压住推理（538→255 token）|
| 中间的 system 消息 | chat 与 `/v1/responses` 都接受，所以坑 E 的两条声明这个栈都不需要 |
| CoT 字段 | 直连就是 `reasoning_content`（与经网关一致）|
| `reasoning_tokens` | 有值，关思考时为 0 |
| 其他 | 工具调用（`finish_reason=tool_calls`）、严格 JSON、流式、`/v1/responses` 均正常。指标前缀 `tensorfold:*`（另有一批 vLLM 同名的镜像指标），`/health` 带 `pair.stalled` / `pair.broken`。没有 `/version` |
| 回滚 | 上游 `make switch TO=<stack-id>`（`make stack-check` 列出可选）。集群内消费方（jobs-sg、open-notebook、oracle calibre）都经网关：别名名字不变时只改网关的上游；别名改名时消费方与**坑 A 的 key 白名单**一起改 |

- ✅ 经网关能传 `reasoning_effort`（2026-10-04 实测，镜像 v1.103.1）。想看 DGX 对档位的 400 原文（换栈后核档位集合就靠它），
  对 `custom_dgx/` 前缀别名传一个**不认识的值**，比如 `"bogus"`：声明了档位集合的栈上，`high` 这类已知档位会先被
  `upstream_compat` 改写（坑 E）。
- ☠️ **裸别名上，参数错误会被兜底悄悄吞掉**：DGX 回 400 → 兜底 `studio/qwen3.8-27b` 接受这个参数 → 200，只有响应里的
  `model` 看得出换了模型。Studio 的 OMLX 不校验 `reasoning_effort`（`bogus` 也 200），所以**任何**档位错误都会被吞。
  调参数用带前缀的别名。机制见坑 A2，Qwen 栈时期的实例见坑 E。
- ⚠️ 质量未验证：只做了上面这些功能性实测。

## ☠️ 坑 A：虚拟 key 的模型白名单在 Postgres 里，git 完全管不到

每个虚拟 key 带一份 `models` 白名单，值是别名字面量。在 git 里改别名（重命名、删除、新增），key 不会跟着变，
于是「清单正确 + ArgoCD Synced + 调用全挂」。症状：

```
key not allowed to access model. This key can only access models=[...]. Tried to access <新别名>
```

☠️ 这条错误和「配置写错了」长得一样，但 ConfigMap 是新的、ArgoCD `Synced`/`Healthy`、pod `Running`、探针全绿。
**症状在 key，不在配置**；用虚拟 key 查 `/v1/models` 还会把它误判成配置没生效（坑 B）。

- ⚠️ **改别名必须同步改 key**，顺序无所谓，两件都要做。白名单散在多把 key 里，只改「自己那把」必然漏
  （两次换栈都是 16 把里 8 把引用了 DGX 别名）。
- ⚠️ `/key/update` 是**整表替换**，不是增量：先读原列表，只映射要改的项，其余原样带回。
- `/key/list` 只认 GET + 分页（POST 回 405），返回的是 token 的 sha256 而不是原文，白名单要逐把 `key/info` 看。
  本机的 `LITELLM_VK` 是哪把：`printf %s "$LITELLM_VK" | sha256sum` 去匹配列表。
- ✅ 白名单只约束「你能指名什么」，**不约束路由内部的兜底跳转**：只含 DGX 别名的窄 key 照样拿到兜底，
  直接指名兜底别名仍 403（09-19 拿 `mac/ornith` 实测）。窄 key（如 `calibre-metadata-llm`）不需要为兜底放宽。
  实测见 [records/2026-09-19-litellm-fallbacks-never-active.md](../records/2026-09-19-litellm-fallbacks-never-active.md)。

本机任意目录（`VK` = 要查或要改的那把虚拟 key）：

```bash
GW=http://100.94.186.7:31400        # tailnet NodePort，不经 Cloudflare WAF
MK=$(kubectl --context k3s-homelab -n litellm get secret litellm-secret \
      -o jsonpath='{.data.master-key}' | base64 -d)

# 列全量（翻 page=2、3… 直到为空）
curl -s -H "Authorization: Bearer $MK" "$GW/key/list?page_size=50&page=1"

# 看一把 key 的白名单（key= 填原文或列表里的 sha256 都行）
curl -s -H "Authorization: Bearer $MK" "$GW/key/info?key=$VK" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("info") or d).get("models"))'

# 覆盖白名单（整个列表替换）
curl -s -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"key":"'"$VK"'","models":["custom_dgx/DeepSeek-V4.1-Flash-1017","DeepSeek-V4.1-Flash-1017",
       "mac/ornith","mac/ornith-fast","openrouter/*"]}' \
  "$GW/key/update"
```

## ☠️ 坑 A2：`fallbacks` 只认顶层 `router_settings`，写进 `litellm_params` 是静默空操作

```yaml
router_settings:
  fallbacks: [{"DeepSeek-V4.1-Flash-1017": ["studio/qwen3.8-27b"]}]   # ✅ 唯一生效的位置
# 写在模型条目的 litellm_params.fallbacks 里 = 透传给 SDK 的 kwarg，不解析 model_list ❌
```

- 写错位置的症状：主上游一失败就 500 `LLM Provider NOT provided ... You passed model=<兜底别名>`（当年是 `mac/ornith`）。
  读起来像兜底配错了，真正错在主上游那条的声明位置；且只在主上游失败时才暴露，平时零症状。
  网关从落地到 2026-09-19 一直是这样：[records/2026-09-19-litellm-fallbacks-never-active.md](../records/2026-09-19-litellm-fallbacks-never-active.md)。
- ☠️ **LiteLLM 不按错误类型决定兜不兜底**：主上游回 4xx 也照样进 `run_async_fallback` 去试兜底。兜底模型接受该参数，
  请求就真的打到兜底并回 200；不接受，那一跳在参数映射层就抛错，调用方拿回原 400，兜底收不到请求。
  现在的兜底 Studio 什么档位都收，所以实际总是前一种。判据是日志里的 `run_async_fallback` / `Error doing the fallback`，不是返回码。
- ⚠️ `router_settings` 的键是别名字面量，换模型时漏改 = 兜底静默失效。与坑 A 是同一类问题的两个位置。

## ☠️ 坑 B：`/v1/models` 返回的是「这个 key 能访问什么」，不是 live config

拿虚拟 key 查 `/v1/models`，看到的是白名单过滤后的结果；改完配置用它自查会看到旧别名，从而误判「配置没生效」，
真实原因是坑 A。**验证配置有没有生效，只能用 master key**（本机任意目录，`MK` 取法见坑 A）：

```bash
curl -s -H "Authorization: Bearer $MK" https://llm.meirong.dev/v1/models \
  | python3 -c 'import sys,json; print([m["id"] for m in json.load(sys.stdin)["data"]])'
```

master key 看到新别名 = 配置已生效，问题在 key；master key 也看不到 = 配置还没进容器，往坑 C 查。

## ☠️ 坑 C：改了 ConfigMap 而 pod 不重启（已自动化，但要知道机制）

两个原因叠加：config 是 `subPath` 挂载（`/app/config.yaml`），subPath **不接收 ConfigMap 更新**；LiteLLM 只在启动时
读一次 config。不重启的后果是 ArgoCD `Synced`/`Healthy`，网关按旧路由表继续服务。两个 hook 的 `.py` 同理。

现由 pod 模板注解 `checksum/config`（hook 各有一个 `checksum/*-py`）自动化：内容一变哈希就变，ArgoCD 自然滚动重启。
CI 强制（`scripts/check-embedded-scripts.py` 的 `STAMP_ONLY`），机制见 [manifest-safety-checks.md](manifest-safety-checks.md) 的 E1。

⚠️ **别手改注解**：改完 config 在 `k8s/helm/` 跑 `just gen-embedded-scripts`。注解一旦被摘掉，静默失效原样回来。

## ☠️ 坑 D：codex 一派 subagent 就 400，上游不认 `agent_message`

- 症状：codex 经网关或直连自托管上游跑会派 subagent 的 skill，第一批 dispatch 就
  `Agent errored: ... validation errors ... Input should be 'shell_call'`。☠️ 与 shell 工具无关：codex v2 多 agent 协议发的
  私有 item `agent_message` 不在上游（vLLM / OMLX）校验用的 union 里，pydantic 把每个分支的失败都列了出来。
- 已修：`k8s/helm/manifests/litellm/codex_compat.py` 的 `async_pre_call_hook` 在转发前降级上游不认的 4 种 item type，
  其余原样透传。改写规则、作用域与失败模式在它的文件头。
- 验证（本机任意目录）：`kubectl --context k3s-homelab -n litellm logs deploy/litellm | grep codex_compat`。每个 pod 只有首次改写
  打一条 WARNING（`本层已生效（首次改写…）`），之后降到 INFO。☠️ 本部署没设 `LITELLM_LOG`，`verbose_proxy_logger` 生效级别是
  WARNING，全用 INFO 的话「没在干活」和「今天没流量」分不出；要看每请求一条就给 Deployment 加 `LITELLM_LOG=INFO`。
- ☠️ **修掉 400 不等于 v2 能用**：v2 派任务时 NEW_TASK 的 payload 是空的，与网关无关。所以**别给自托管模型写 codex catalog 条目**：
  没有条目时协作走客户端侧投递（任务作为普通 `role=user` message），是唯一能干活的组合；`multi_agent_version: "v2"` 派出去的
  任务为空，`"v1"` 或不写这个键则没有 collab 工具。代价：启动警告 `Model metadata … not found`，且 `model_context_window`
  不驱动自动压缩阈值（只有 catalog 的 `context_window` 才行），长会话可能中途被服务端拒收。
- hook 仍保留：codex 改默认或有人手开 v2 不会再撞 400，另三种 type 也不限于多 agent 场景。

证据与排查经过：[records/2026-09-08-codex-subagent-agent-message-400.md](../records/2026-09-08-codex-subagent-agent-message-400.md)。

## ☠️ 坑 E：DGX 回 400 的请求被兜底静默接走（已由 `upstream_compat` 改写）

- 症状：调用方没有任何报错，只是慢（Ornith 30–47s，DGX 几秒），响应里的 `model` 变成 `ornith-ai__…`。
  2026-11-13 查外发 key 时发现，claude-cli 的主循环请求和 magpie 的大请求全部落在 M2 上，DGX 空着。
- 两种 400（拿 `custom_dgx/` 前缀别名打才看得到原文，裸别名上已被兜底吞掉）：

  | 原文 | 谁会触发 |
  |---|---|
  | `System message must be at the beginning.`（Qwen chat template） | Claude Code 2.1.31x 起把 `# Environment` 块作为 `messages[1]` 的 `role: "system"` 发出来。标题生成之类的旁路请求不带它，所以同一个 session 里有的请求能打到 DGX |
  | `Unexpected reasoning effort high. Supported types are …` | 透传客户端档位的代理（magpie 0.1.2138），或直接传 `high` / `minimal` 的客户端 |

- ⚠️ `/v1/messages` 打 `openai/` 上游时，LiteLLM 1.103.1 走的是 Responses API（DGX 收到的是 `instructions` + `input`），
  不是 chat；Claude Code 第一次请求带的 `thinking` 会在 LiteLLM 参数层被拒（`UnsupportedParamsError … reasoning.effort`），
  客户端去掉 thinking 重试，重试那次才撞到上面第一种 400。
- 修法：`k8s/helm/manifests/litellm/upstream_compat.py` 在转发前按两个 DGX 别名 `model_info` 里的声明改写：
  `upstream_system_first` 把中间的 system 并进开头，`upstream_reasoning_efforts` 把集合外的档位换成不低于它的最小档。
  规则、作用域与失败模式在它的文件头。☠️ **换栈时这两条声明要跟着重核**（档位集合每个栈都变过），runbook 已列为必改项。
  2026-11-15 换上的 DeepSeek-V4.1 / TensorFold 两种都接受（七档全收、中间的 system 也收），声明已撤，本层对它是空操作。
- 验证 hook 已加载：`kubectl --context k3s-homelab -n litellm logs deploy/litellm | grep upstream_compat`（每个 pod 首次改写打一条 WARNING）。
- 这类问题不会自己报出来。查最近谁被静默兜底了（本机任意目录；修复后应只剩 DGX 真宕机时段的行）：

```bash
kubectl --context k3s-homelab -n databases exec deploy/apps-pg -- psql -U postgres -d litellm -c "
select coalesce(nullif(metadata->>'user_api_key_alias', ''), left(api_key, 12)) as key,
       split_part(metadata->>'user_agent', ' ', 1) as ua,
       metadata->>'original_model_group' as asked, model_group as served, count(*) as n
from \"LiteLLM_SpendLogs\"
where \"startTime\" > now() - interval '7 days' and status = 'success'
  and metadata->>'original_model_group' <> model_group
group by 1, 2, 3, 4 order by n desc;"
```

## 怎么查「哪些模型能免费用」

挑模型从这里查，别凭印象。⚠️ NVIDIA build.nvidia.com 的 `nvidia/*` 路由 2026-10-04 已删：写成 `openai/nvidia/*`
会给上游模型名多带一层前缀，全部 404。当时的排查与模型筛选（仓库根目录）：
`git show 8214ee8:docs/reference/litellm-gateway.md`。

### OpenRouter：按模型分免费/付费，公开 API 免鉴权可查

| 入口 | 用途 |
|---|---|
| `https://openrouter.ai/models` | UI，可按价格筛选 |
| `GET https://openrouter.ai/api/v1/models` | 免鉴权，全量模型元数据（含 pricing / context_length / knowledge_cutoff）|
| [openrouter.ai/docs/api_reference/limits](https://openrouter.ai/docs/api_reference/limits) | 官方限额（路径是下划线 `api_reference`，连字符版本 404）|

判据是 pricing 两个字段都为 0（本机任意目录）：

```bash
curl -s https://openrouter.ai/api/v1/models | python3 -c '
import sys,json
d = json.load(sys.stdin)["data"]
def is_free(m):
    p = m.get("pricing") or {}
    return float(p.get("prompt") or 1) == 0 and float(p.get("completion") or 1) == 0
free = sorted(filter(is_free, d), key=lambda m: -(m.get("context_length") or 0))
print("免费模型:", len(free), "/", len(d))
for m in free:
    print(" ", m["id"].ljust(56), "ctx=", m.get("context_length"))'
```

- ⚠️ 别用 `:free` 后缀当判据：有零价模型不带后缀（如 `openrouter/free`、`google/lyria-3-{clip,pro}-preview`）。pricing 字段才权威。
- 免费档限额（官方原文）：20 请求/分；终身购买信用 < $10 → 50 请求/天，≥ $10 → 1000 请求/天（买过一次永久提档）。
  负余额会让免费模型也报 402。
- ⚠️ 免费档不能当兜底：503 / 超时 / 429 都撞到过，只配当「碰运气的额外一档」，别进 `fallbacks` 链。
- ☠️ **思维链能否分离取决于 provider 的托管实现，不是模型本身**：同一个 `nemotron-3.5-lightning`、同一提示词，
  NVIDIA 直连 `reasoning_content` 干净分离；经 OpenRouter（`:free`）`finish=length`，思维链原文落在 `content`。
  「这个模型能用吗」必须按 `(provider, model)` 组合发一次真实请求，看 `message` 的 key 与 `content` 首行。

## 上游是思维链模型：小 `max_tokens` 会把思维链漏进 `content`

`reasoning_content` 的切分依赖 `</think>` 闭合标签；token 用完标签不出现，parser 就把整段思考原样放进 `content`
（不报错、不告警）。受影响的是全部自托管上游（DGX、Mac Ornith、Studio），不是某个模型的缺陷。

- DGX 关思考的写法与 `reasoning_effort` 档位见 DGX 一节，别跨栈照抄。
- ☠️ **关思考的 kwargs 名写错是静默空操作**：旧栈那套 `{"thinking": false}` 打到新栈照样 200，思考却没关。判据只能看
  `usage.completion_tokens_details.reasoning_tokens`，不能看请求成没成。踩中这条的是 jobs-sg 的 `DisableThinking`（[jobs-sg.md](jobs-sg.md)）。
- Mac 的逃生口是 `mac/ornith-fast`（见「别名」）。实测数据与换 Ornith 的理由见
  [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md) 的「2026-08-25 修订」。
- ⚠️ M2 只暴露一个 35B：OMLX 池天花板 30GB 装不下两个（19.95 + 19.08GB），两个别名并存 = 交替调用持续换入换出
  （~18s/次，期间回 `is busy`）。

## Mac Studio 上游：`studio/qwen3.8-27b`

| | |
|---|---|
| 别名 → 上游 | `studio/qwen3.8-27b` → `openai/Qwen3.8-27B-MLX-4bit` @ `100.98.220.75:8000/v1` |
| 机器 | Mac Studio M5 Max / 128G，OMLX 0.7.0；池天花板 ~106G，常驻、不换入换出（M2「只暴露一个 35B」的约束不适用）|
| 模型 | HF `lmstudio-community/Qwen3.8-27B-MLX-4bit`（VLM，262k ctx），思维链分离到 `reasoning_content`。⚠️ OMLX 0.7 的模型 ID 不带 org，别照 M2 写成 `org__name` |
| 兜底 | 2026-11-15 起接 DGX 裸别名 `DeepSeek-V4.1-Flash-1017` 的兜底。换前经网关实测（短提示）：`reasoning_effort` none…max 七档和 `bogus` 全 200（OMLX 不校验，`none` 也照样思考；关思考要用 `chat_template_kwargs {"enable_thinking": false}`）；对话中间的 system 在 chat / `/v1/responses` / `/v1/messages` 三条路都 200；工具调用 `finish_reason=tool_calls` |
| key 白名单 | `LITELLM_VK`（sha256 前缀 2c15baf776…）、`key_alias=xiaogpt`（只有这一个模型）、`ext-team-1`（账户与 key 两层白名单都有）、`key_alias=open-notebook`（2026-11-11，第二备选）。其余窄 key 刻意没加，谁要用按坑 A 单独加 |

主机侧（OMLX 安装、key、模型下载、DFlash2 与实测性能）→ `macbook/ansible/README.md`；指标 →
[omlx-inference-metrics.md](omlx-inference-metrics.md)。

- ⚠️ **兜底时比 DGX 弱的两处**：预填充约 1000 tok/s（DGX 约 2,300），接近 262k 满窗的请求在兜底上要 4 分钟以上，
  撞 300 秒客户端超时；兜底流量与 xiaogpt、open-notebook 第二备选等指名调用挤同一个 OMLX 进程，
  而 N=2 时总吞吐不涨、每路减半（2026-10-22 实测）。DGX 一挂，这些指名调用也会跟着变慢。

- ☠️ **`mac/*` 与 `studio/*` 的 `api_key: dummy` 能用，是 Mac 上一个开关的结果**：OMLX 0.7 起非回环监听必须配 key，
  现行配法是 key + `allow_unauthenticated_inference: true`。开关一丢就全部 401，而网关清单正确、ArgoCD Synced。
  → [omlx-inference-metrics.md 的「鉴权」](omlx-inference-metrics.md#鉴权omlx-07-起)
- ⚠️ 网关里没有任何文生图模型：`studio/qwen-image-2.1` 2026-10-03 同日上线同日撤下，原因与当时的实现 →
  [decisions/studio-image-generation.md](../decisions/studio-image-generation.md)。

## 每把 key 的用量与来源 IP（spend log）

每次调用（含失败）在 `apps-pg` 的 `litellm` 库写一行 `LiteLLM_SpendLogs`：

| 列 | 内容 |
|---|---|
| `api_key` | key 的 sha256，不是原文 |
| `metadata->>'user_api_key_alias'` | 发 key 时给的 `key_alias`，没给就是空 |
| `"startTime"` / `model_group` / `call_type` / `status` | 时间、别名、路由、`success`/`failure` |
| `prompt_tokens` / `completion_tokens` / `total_tokens` | 用量。☠️ 别看 `spend`：自托管模型没有单价，全表 spend 都是 0 |
| `metadata->>'user_agent'` | 客户端 UA |
| `requester_ip_address` | 来源 IP，见下 |

- ⚠️ 不存对话内容（没开 `store_prompts_in_spend_logs`）。别为排障顺手打开，那会把外部使用者的 prompt 落进库。
- 没设 `maximum_spend_logs_retention_period`，行会一直留着，量级上不用管。
- `requester_ip_address`：公网调用记 Cloudflare 的 `CF-Connecting-IP`（真实客户端 IP，IPv6 客户端就是 IPv6；伪造不了），
  tailnet NodePort 记调用方的 `100.x`，集群内走 Service 记 pod IP。公网那条靠 `client_ip.py` hook 改写，为什么不用
  `general_settings.use_x_forwarded_for`、信任边界与防伪造实测都在它的文件头。
- ☠️ hook 上线（2026-10-03）前的行，公网调用一律是 `10.42.0.152`（k8s-node 的 CiliumInternalIP），补不回来。
- ⚠️ 被限流拒掉的 `/v1/responses` 请求，IP 是空串（LiteLLM 本身行为，与 hook 无关；chat 被限流的行有 IP）。
- hook 是否加载：每个 pod 首次改写打一条 WARNING，`kubectl --context k3s-homelab -n litellm logs deploy/litellm | grep client_ip`。

按 key × IP 看近 7 天用量（本机任意目录；没有别名的 key 显示哈希前 12 位，对照方法见坑 A）：

```bash
kubectl --context k3s-homelab -n databases exec deploy/apps-pg -- psql -U postgres -d litellm -c "
select coalesce(nullif(metadata->>'user_api_key_alias', ''), left(api_key, 12)) as key,
       requester_ip_address as ip,
       count(*) as calls, count(*) filter (where status = 'failure') as failed,
       sum(total_tokens) as tokens, max(\"startTime\")::timestamp(0) as last_seen
from \"LiteLLM_SpendLogs\" where \"startTime\" > now() - interval '7 days'
group by 1, 2 order by calls desc;"
```

## 发给外部的 key

⚠️ 存量 key 大多没有 `key_alias`，也都没设 rpm/tpm/并发上限（2026-10-03 盘点 18 把里 17 把无 alias）。
对外发 key 这样建（本机任意目录，`MK` / `GW` 见坑 A）：

```bash
curl -s -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"key_alias":"ext-<谁>","models":["studio/qwen3.8-27b"],"duration":"30d",
       "rpm_limit":60,"max_parallel_requests":2}' \
  "$GW/key/generate"
```

| 参数 | 为什么 |
|---|---|
| `key_alias` | spend log 聚合按它分组；必须唯一，重名直接拒绝 |
| `duration` | 到期自动失效，调用方拿到 401 `expired_key` |
| `rpm_limit` / `max_parallel_requests` | 超了回 429 `throttling_error`（同 digest 镜像本地实测过）。☠️ 别用 `max_budget` 限额：自托管模型 spend 恒为 0，限不住 |

- 吊销用 `/key/delete`（`{"key_aliases": [...]}` 或 `{"keys": [...]}`）。☠️ 删完别拿 `key/info` 核验：已删除的 key
  照样 200 并返回完整信息。看 `/key/list?key_alias=<别名>` 为空，或拿旧 key 调用得 401
  （[records/2026-10-26-litellm-keys-in-public-repo.md](../records/2026-10-26-litellm-keys-in-public-repo.md)）。
- 给使用者看的公开说明（不含密钥）→ [guides/llm-gateway-external-users.md](../guides/llm-gateway-external-users.md)。

## 消费方

| 消费方 | 用哪个别名 | 配置在哪 |
|---|---|---|
| `codex --profile mac` | `mac/ornith` | `~/.codex/mac.config.toml`（本机）|
| 本机任意 OpenAI 兼容客户端 | `studio/qwen3.8-27b` | 读 `LITELLM_VK`；目前没有固定消费方 |
| k8sgpt（默认，`--backend localai`）| `mac/ornith-fast` | `~/Library/Application Support/k8sgpt/k8sgpt.yaml`（本机）|
| k8sgpt（`--backend openai`）| `DeepSeek-V4.1-Flash-1017` | 同上。☠️ explain 输出为空：k8sgpt 0.4.39 实际按 2048 截断（无视 `maxtokens: 4096`），DGX 默认开思考，2048 全用在思考上（网关记 `success`、`completion_tokens=2048`），所以默认后端是 localai |
| oracle 上的 calibre 元数据作业 | `DeepSeek-V4.1-Flash-1017`（经 `litellm-external` NodePort）| [清单内嵌脚本](../../cloud/oracle/manifests/calibre-metadata/metadata-llm.yaml) |
| xiaogpt（小爱音箱，homelab `personal-services`）| `studio/qwen3.8-27b`，专用 key `key_alias=xiaogpt` | [xiaogpt.yaml](../../k8s/helm/manifests/personal-services/xiaogpt.yaml) 的 ConfigMap |
| Open Notebook（homelab `personal-services`）| `DeepSeek-V4.1-Flash-1017` + OMLX 原名的 4 个别名（chat / embedding / TTS / ASR）+ `studio/qwen3.8-27b`（第二备选），专用 key `key_alias=open-notebook`，2026-11-11 起 | [open-notebook.md](open-notebook.md)；key 由 provisioner 写进两个凭据 |
| jobs-sg enrich（homelab `jobs-sg`）| `custom_dgx/DeepSeek-V4.1-Flash-1017`（刻意不带兜底），专用 key `key_alias=jobs-sg`，2026-11-11 起 | [jobs-sg.md](jobs-sg.md)「LLM 富化」|
| `codex --profile dgx` / `m2` | 不走网关，直连 DGX / M2 的 OMLX | `~/.codex/{dgx,m2}.config.toml`（本机）|
| 外部使用者（UI 账户 `ext-team-1`）| 5 个自托管别名 + 17 个 OpenRouter `:free` 模型 | Postgres（账户与 key 各一层白名单），见「发给外部的 key」|
| M2 / Studio 上的 magpie（`homelab` provider）| `DeepSeek-V4.1-Flash-1017` → `studio/qwen3.8-27b`（magpie 的 `group/qwen`；组 id 是历史名，换栈没改，免得每个 agent 重设），另暴露若干 `openrouter/*` | 每台一把（`key_alias` 为 `m2-magpie` / `studio-magpie`），值在 Vault `secret/homelab/magpie`，`cd macbook/ansible && just magpie` 下发。☠️ 别写进 playbook：[泄露复盘](../records/2026-10-26-litellm-keys-in-public-repo.md) |

⚠️ 本机消费方全部读同一个 `LITELLM_VK`（`~/.zshrc`），坑 A 一旦发生是全体受影响。
