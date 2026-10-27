# codex 一派 subagent 就 400：自托管上游不认 `agent_message`，修掉后 v2 仍派不出任务

> 日期: 2026-09-08
> 影响: codex 经网关或直连自托管上游（DGX vLLM / OMLX）时，任何会派 subagent 的 skill
>       （`understand` / `understand-knowledge` 一类）第一批 dispatch 就报错，父子两边同时失败
> 根因: codex `multi_agent_version: "v2"` 把 agent 间消息作为私有 item `agent_message` 追加进
>       `/v1/responses` 的 `input`。它不在 openai-python 的 `ResponseInputItemParam` union 里，而 vLLM / OMLX
>       正是拿那套 pydantic 模型校验请求体。另有一个与网关无关的问题：v2 投递的 NEW_TASK payload 是空的
> 处置: 网关加 `async_pre_call_hook`（`k8s/helm/manifests/litellm/codex_compat.py`）降级 4 种上游不认的 item；
>       客户端侧不给自托管模型写 catalog 条目，协作改走客户端侧投递

## 现象

```
Agent errored: {"error":{"message":"216 validation errors:
  {'type': 'string_type', 'loc': ('body','input','str'), …
  … 'msg': "Input should be 'shell_call'" …
```

这段报错是误导的：与 shell 工具、tool schema 都无关。pydantic 校验 `input` 里的 item 时把整个 union
挨个试了一遍，把每个分支的失败都列了出来，随便哪一行都不指向真因。真因只有一个：多了一个上游不认识的 item type。

## 定位

- `agent_message` 的形状是 `{"type": "agent_message", author, recipient, content}`。父给子的 NEW_TASK、
  子回父的 FINAL_ANSWER 都走它，所以父子两边同时报错。
- LiteLLM 原样透传，经网关和直连上游表现一样，只是网关多包一层 `litellm.BadRequestError: OpenAIException`。
- 拿 DGX vLLM 的 `/openapi.json` 数过：`input` 只接受 30 种 `type` 字面量，codex 会发而它不认的就 4 种
  （`agent_message` / `context_compaction` / `encrypted_function_args` / `internal_chat_message_metadata_passthrough`）。
  其余 codex 变体（`reasoning` / `function_call` / `tool_search_call` / `compaction` / `compaction_trigger` …）都在 union 里。
- 修法验证：同一份真实 payload 经网关，改写前 400、改写后 200。

## 修掉 400 之后：v2 的 NEW_TASK payload 是空的

```
Message Type: NEW_TASK
Task name: /root/alpha
Sender: /root
Payload:            ← 就到这里，父 agent 传的 message 没了
```

- 它出现在**子 agent 自己的本地 rollout 里**（`~/.codex/sessions/…jsonl`），而 rollout 是 codex 发 HTTP 之前
  从自身状态写的，所以不可能是网关或 hook 造成的。父 agent 的 `spawn_agent` 参数里 message 明明在（85 字符）。
- 三种组合都复现：原有的 dgx catalog、新建的 litellm catalog、传不传 `fork_turns`。合理推断是 v2 的任务投递
  依赖 OpenAI 后端的线程状态，自建 vLLM 没有这个能力。
- `use_responses_lite: true` 不是出路：vLLM 服务不了那套 wire format，连接重试 5 次后失败。

## 客户端侧的结论是反的

| catalog 条目 | collab 工具 | 任务能否到子 agent |
|---|---|---|
| 没有条目（fallback metadata）| 有 | ✅ 走普通 `role=user` message，`wait_agent` 的 `function_call_output` 带回答案，ALPHA/BETA/GAMMA 全回来 |
| `multi_agent_version: "v2"` | 有 | ❌ NEW_TASK payload 为空（hook 只挡住了 400）|
| `"v1"` 或不写这个键 | 没有（模型只能去摸 `exec_command`）| 派不了 |

所以别给自托管模型写 catalog 条目。代价照单接受：启动警告 `Model metadata … not found`，且
`model_context_window` 不驱动自动压缩阈值（只有 catalog 的 `context_window` 才行），长会话有中途被服务端拒收的风险。

## 留下的

- hook 仍保留：codex 以后改默认、或有人手动开 v2，都不会再撞 400；另三种 type 也不限于多 agent 场景。
- hook 的首次改写打 WARNING 而不是 INFO：本部署没设 `LITELLM_LOG`，`verbose_proxy_logger` 的生效级别是 WARNING，
  全用 INFO 的话「这层没在干活」和「今天没有多 agent 流量」看起来一模一样。
- 现行规则与验证命令见 [reference/litellm-gateway.md](../reference/litellm-gateway.md) 坑 D。
