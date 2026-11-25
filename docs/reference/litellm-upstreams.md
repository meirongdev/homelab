# LiteLLM 网关的上游与兼容层

> Last updated: 2026-11-25
> Status: 生效事实
> Scope: 网关背后各上游的生效事实（DGX 主力栈、Mac Studio、思维链模型的共性陷阱、OpenRouter 免费档），
> 以及两个兼容 hook（坑 D `codex_compat`、坑 E `upstream_compat`）。2026-11-25 从
> [litellm-gateway.md](litellm-gateway.md) 拆出；网关本身的配置生效路径、key 白名单（坑 A–C）、路由与消费方仍在那篇。

## DGX 主力栈：Qwen3.8-Flash-Next（vLLM 双机 TP=2，2026-11-17 起）

上游 `~/projects/meirongdev/nv-dgx-spark` 单方面换栈，本仓库只跟着改引用；本节是本仓库关于该上游的唯一真相源
（换栈理由与压测在上游仓库）。☠️ 再换模型或回滚，照
[runbooks/dgx-model-swap-homelab-followup.md](../runbooks/dgx-model-swap-homelab-followup.md) 走（改哪几处、为什么必须动 key、
哪些阈值要重估、怎么验收，改本节也是其中一步）。减负方案
[plans/2026-09-03-dgx-model-swap-optimizations.md](../plans/2026-09-03-dgx-model-swap-optimizations.md) 📐 未实施，门禁还不存在。

☠️ **对客户端的名字与 DGX 实际跑的模型刻意不一致**：2026-11-15 上游换成 DeepSeek-V4.1-Flash-1017（TensorFold）时
别名跟着改了名；11-17 13:43 上游又换回 Qwen3.8-Flash-Next，用户决定客户端不动——`custom_dgx/DeepSeek-V4.1-Flash-1017`、
裸别名 `DeepSeek-V4.1-Flash-1017`、兼容别名 `qwen3.8-flash-next-tp2` 照旧，只把四条 DGX deployment 的 `model:` 改成
`openai/qwen3.8-flash-next-tp2`（11-18），虚拟 key 白名单与健康检查组名都没动。改之前四条全 404，网关流量全部落在 Studio / M2。
判断 DGX 现在跑什么只看 `/v1/models`：2026-11-25 本机那份上游 checkout 的 `stacks/PRIMARY` 仍写 `dsv41`，与现网不符。

| | |
|---|---|
| 模型 / 引擎 | Qwen3.8-Flash-Next（hibrid48 权重，myllmbox cluster kit v5.4），vLLM，双机 TP=2 |
| served name | `qwen3.8-flash-next-tp2`。vLLM 对别的名字一律 404 |
| 端点 | `100.97.87.120:8000/v1`（head 在 S1）|
| `max_model_len` | 409600（2026-11-25 `/v1/models` 实测）|
| `reasoning_effort` | 只收 `none` / `low` / `medium` / `xhigh`（11-18 实测），`none` 真能关思考。集合外的档位由网关的 `upstream_compat` 改写（坑 E）|
| 中间的 system 消息 | 400（11-18 实测），由 `upstream_compat` 并进开头（坑 E）|
| 关思考 | `chat_template_kwargs {"enable_thinking": false}`（Qwen 栈 2026-10-04 实测；v5.4 只测过 `reasoning_effort: none`）。☠️ 旧键 `{"thinking": false}` 在 Qwen 栈上是静默空操作 |
| 并发 | 本栈的 `max-num-seqs` 未核（上一个 vLLM 栈是 64）。jobs-sg 的 `LLM_CONCURRENCY` 11-15 为 TensorFold 的 `max_batch_size: 4` 从 8 降到 4，换回 vLLM 后没调回（[ROADMAP](../ROADMAP.md) 第 9 条）|
| 指标与告警 | `vllm:*`。DGX 三条告警（Stuck / Restarted / RequestsQueued）是 `tensorfold:*` 与 `vllm:*` 两族的并集，哪族在就用哪族；`dgx-vllm-dashboard` 仍按 `tensorfold:*` 画，vLLM 期间面板为空 |
| 起停 / 换栈 / 回滚 | 只用上游的 `make restart` / `make switch TO=<stack-id>`（`make stack-check` 列出可选）。集群内消费方（jobs-sg、open-notebook、oracle calibre）都经网关：别名名字不变时只改网关的上游；别名改名时消费方与 [litellm-gateway.md](litellm-gateway.md) **坑 A 的 key 白名单**一起改 |

DeepSeek-V4.1 / TensorFold 那三天（11-15 ~ 11-17）的实测表（模型名写错照常 200、`max_batch_size: 4`、七档全收等）
对现网不适用，只留在 git 历史：`git show 0fc3f02:docs/reference/litellm-gateway.md`。换回那个栈时照 runbook 重测，别照抄。

- ✅ 经网关能传 `reasoning_effort`（2026-10-04 实测，镜像 v1.103.1）。想看 DGX 对档位的 400 原文（换栈后核档位集合就靠它），
  对 `custom_dgx/` 前缀别名传一个**不认识的值**，比如 `"bogus"`：声明了档位集合的栈上，`high` 这类已知档位会先被
  `upstream_compat` 改写（坑 E）。
- ☠️ **裸别名上，参数错误会被降级悄悄吞掉**：DGX 回 400 → 第 2 级 Studio 接受这个参数 → 200，只有响应头
  `x-litellm-model-api-base` 看得出换了上游。Studio 的 OMLX 不校验 `reasoning_effort`（`bogus` 也 200），所以**任何**档位错误都会被吞。
  调参数用带前缀的别名。机制见 [litellm-gateway.md](litellm-gateway.md)「自动降级」，Qwen 栈上的实例见坑 E。

## Mac Studio 上游：`studio/qwen3.8-27b`

| | |
|---|---|
| 别名 → 上游 | `studio/qwen3.8-27b` → `openai/Qwen3.8-27B-MLX-4bit` @ `100.98.220.75:8000/v1` |
| 机器 | Mac Studio M5 Max / 128G，OMLX 0.7.0；池天花板 ~106G，常驻、不换入换出（M2「只暴露一个 35B」的约束不适用）|
| 模型 | HF `lmstudio-community/Qwen3.8-27B-MLX-4bit`（VLM，262k ctx），思维链分离到 `reasoning_content`。⚠️ OMLX 0.7 的模型 ID 不带 org，别照 M2 写成 `org__name` |
| 降级 | 2026-11-15 起是裸别名 `DeepSeek-V4.1-Flash-1017` 的第 2 级（[litellm-gateway.md](litellm-gateway.md)「自动降级」）、内部改道组 `homelab/qwen3.8-27b` 的第 1 级（同篇「按 key 分首选」）。上线前经网关实测（短提示）：`reasoning_effort` none…max 七档和 `bogus` 全 200（OMLX 不校验，`none` 也照样思考；关思考要用 `chat_template_kwargs {"enable_thinking": false}`）；对话中间的 system 在 chat / `/v1/responses` / `/v1/messages` 三条路都 200；工具调用 `finish_reason=tool_calls` |
| key 白名单 | `LITELLM_VK`（sha256 前缀 2c15baf776…）、`key_alias=xiaogpt`（只有这一个模型）、`ext-team-1`（账户与 key 两层白名单都有）、`key_alias=open-notebook`（2026-11-11，第二备选）。其余窄 key 刻意没加，谁要用按 [litellm-gateway.md](litellm-gateway.md) 坑 A 单独加 |

主机侧（OMLX 安装、key、模型下载、DFlash2 与实测性能）→ `macbook/ansible/README.md`；指标 →
[omlx-inference-metrics.md](omlx-inference-metrics.md)。

- ⚠️ **Studio 比 DGX 弱的两处**（homelab 内部流量首选它，外发 key 的流量在 DGX 挂掉时降到它）：预填充约 1000 tok/s（DGX 的 DeepSeek 栈实测约 2,300，现行栈未测），接近 262k 满窗的请求要 4 分钟以上，
  撞 300 秒客户端超时；homelab 内部的全部流量与外发 key 的降级流量挤同一个 OMLX 进程，
  而 N=2 时总吞吐不涨、每路减半（2026-10-22 实测）。Studio 忙到探测超时（60s）时内部请求会降到 DGX，这是设计如此。

- ☠️ **`mac/*` 与 `studio/*` 的 `api_key: dummy` 能用，是 Mac 上一个开关的结果**：OMLX 0.7 起非回环监听必须配 key，
  现行配法是 key + `allow_unauthenticated_inference: true`。开关一丢就全部 401，而网关清单正确、ArgoCD Synced。
  → [omlx-inference-metrics.md 的「鉴权」](omlx-inference-metrics.md#鉴权omlx-07-起)
- ⚠️ 网关里没有任何文生图模型：`studio/qwen-image-2.1` 2026-10-03 同日上线同日撤下，原因与当时的实现 →
  [decisions/studio-image-generation.md](../decisions/studio-image-generation.md)。

## 上游是思维链模型：小 `max_tokens` 会把思维链漏进 `content`

`reasoning_content` 的切分依赖 `</think>` 闭合标签；token 用完标签不出现，parser 就把整段思考原样放进 `content`
（不报错、不告警）。受影响的是全部自托管上游（DGX、Mac Ornith、Studio），不是某个模型的缺陷。

- DGX 关思考的写法与 `reasoning_effort` 档位见 DGX 一节，别跨栈照抄。
- ☠️ **关思考的 kwargs 名写错是静默空操作**：旧栈那套 `{"thinking": false}` 打到新栈照样 200，思考却没关。判据只能看
  `usage.completion_tokens_details.reasoning_tokens`，不能看请求成没成。踩中这条的是 jobs-sg 的 `DisableThinking`（[jobs-sg-enrich.md](jobs-sg-enrich.md)）。
- Mac 的逃生口是 `mac/ornith-fast`（见 [litellm-gateway.md](litellm-gateway.md)「别名」）。实测数据与换 Ornith 的理由见
  [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md) 的「2026-08-25 修订」。
- ⚠️ M2 只暴露一个 35B：OMLX 池天花板 30GB 装不下两个（19.95 + 19.08GB），两个别名并存 = 交替调用持续换入换出
  （~18s/次，期间回 `is busy`）。

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
  现行（11-18 起）两条声明写在三条 DGX deployment 上（`custom_dgx/…` 与裸别名、兼容别名的 order 1），档位集合
  `none` / `low` / `medium` / `xhigh`。⚠️ 内部改道组 `homelab/qwen3.8-27b` 里 DGX 那条（order 2）没写：内部 key 降到 DGX
  时请求会不会被改写，取决于 hook 读到的是原名还是改道后的组名，未实测。11-15 ~ 11-17 的 DeepSeek / TensorFold 栈
  两种都接受，那三天声明撤掉过（`upstream_compat.py` 文件头「当前 config 里没有声明」一句是那时写的）。
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

