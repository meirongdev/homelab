# LLM API 使用说明（给拿到 key 的外部使用者）

> Last updated: 2026-10-03
>
> 这份文档是公开的，**不含任何密钥**。你的 API key 会单独、私下发给你。
> 里面的每个示例，以及 4xx 错误码，都在 2026-10-03 经公网实测过（524 是 Cloudflare 的 100 秒规则）。

## 速览

| | |
|---|---|
| 接口地址（base URL）| `https://llm.meirong.dev/v1` |
| 协议 | OpenAI 兼容 Chat Completions（含流式、图片输入）|
| 鉴权 | 请求头 `Authorization: Bearer <你的 key>` |
| 你能用哪些模型 | **以你的 key 为准**，用下面「第一步」查 |
| 可用性 | 自托管在个人硬件上，**没有 SLA**，可能维护或临时离线 |

任何支持「自定义 base URL」的 OpenAI 客户端都能用：官方 Python / Node SDK、LangChain、
各类聊天客户端等，填上面的地址和你的 key 即可。

## 第一步：确认 key 能用

```bash
curl -s https://llm.meirong.dev/v1/models -H "Authorization: Bearer $LLM_KEY"
```

返回的 `data[].id` 就是**你这把 key 能用的全部模型名**，调用时 `model` 字段必须逐字写成它们之一。

## 模型

| 模型名 | 用途 | 说明 |
|---|---|---|
| `studio/qwen3.8-27b` | 对话（文本，也能看图）| Qwen3.8-27B，上下文 262k；**默认会先思考再回答**，见下文 |

你的 key 不一定包含上表全部模型，以 `/v1/models` 为准。

## 对话

```python
# pip install openai
import os
from openai import OpenAI

client = OpenAI(base_url="https://llm.meirong.dev/v1", api_key=os.environ["LLM_KEY"])

resp = client.chat.completions.create(
    model="studio/qwen3.8-27b",
    messages=[{"role": "user", "content": "用三句话解释什么是 LRU 缓存。"}],
    max_tokens=2048,
)
print(resp.choices[0].message.content)
```

### 思考（推理）模式

这个模型默认先思考、再作答：

- 思考过程在 `message.reasoning_content`（流式时在 `delta.reasoning_content`），**答案在 `content`**；
  只读 `content` 的客户端不受影响。
- 开着思考时 **`max_tokens` 要留足**（建议 ≥ 1024）。思考把额度用完的话，答案可能为空，
  或者思考内容被混进 `content`。
- 简单任务、要严格格式（JSON、分类）、要低延迟时，**关掉思考**：

```python
resp = client.chat.completions.create(
    model="studio/qwen3.8-27b",
    messages=[{"role": "user", "content": "17 乘以 23 等于多少？只回答数字。"}],
    max_tokens=64,
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},
)
print(resp.choices[0].message.content)   # 391
```

（不用 SDK 时，就在请求体顶层加 `"chat_template_kwargs": {"enable_thinking": false}`。）

### 流式输出

```python
stream = client.chat.completions.create(
    model="studio/qwen3.8-27b",
    messages=[{"role": "user", "content": "数到五，用逗号分隔。"}],
    max_tokens=64,
    stream=True,
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},
)
for chunk in stream:
    if chunk.choices and chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
print()
```

### 图片输入

```python
import base64

with open("photo.png", "rb") as f:
    b64 = base64.b64encode(f.read()).decode()

resp = client.chat.completions.create(
    model="studio/qwen3.8-27b",
    messages=[{"role": "user", "content": [
        {"type": "text", "text": "用一句话描述这张图片。"},
        {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
    ]}],
    max_tokens=512,
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},
)
print(resp.choices[0].message.content)
```

图片要以 base64 data URL 内联在请求里。

### 速度参考

生成速度随内容变化：代码约 90–110 token/s，英文问答约 60–75，中文长文约 40；
短 prompt 的首个 token 通常在 0.5 秒内。长 prompt 先要「读完」才开始回答，
大约每秒 1000 token（1.5 万 token 的 prompt 约等 15 秒）。

## 出错了怎么办

错误体是 OpenAI 格式：`{"error": {"message": ..., "type": ...}}`。

| HTTP | `error.type` / 响应体 | 含义与处理 |
|---|---|---|
| 401 | `token_not_found_in_db` | key 不对（多/少字符、复制错）|
| 401 | `expired_key` | key 已过期，联系给你 key 的人续期 |
| 403 | `key_model_access_denied` | `model` 写错，或不在你的 key 授权范围内，对照 `/v1/models` |
| 403 | 响应体是纯文本 `error code: 1010` | **按 User-Agent 被拦截**，与 key 无关。Python 标准库 `urllib` 的默认 UA 会中；改用 OpenAI SDK / `requests`，或自己设一个 `User-Agent` 头 |
| 429 | `throttling_error` | 超出你的 key 的速率或并发上限，等一会儿再试 |
| 400 | 见 `message` | 参数错误，具体原因在 `message` 里 |
| 502 / 503 / 空响应 | — | 服务重启中或机器离线，**稍后重试**（建议指数退避）|
| 524 | — | 非流式请求 100 秒内没返回会被中断。开着思考、要很长输出时容易撞上，改用 `stream=True` |

## 使用约定

- **key 只给你本人用**：别提交到 git、别写进前端或手机 App 代码、别贴到聊天群。
  怀疑泄露了就马上告诉给你 key 的人，旧 key 会被吊销、换一把新的。
- 你的 key 有**有效期、速率与并发上限**，具体以发 key 时的说明为准。
- **没有 SLA**：做重要的事请自己加重试与兜底，别把它当成唯一依赖。
- 请不要发送机密或敏感个人数据。
- 网关会按 key 记录每次调用的时间、模型、token 数、来源 IP 和 User-Agent，**不记录对话内容**。
- 不要用于压测或大批量离线任务；有这类需求先沟通。
