# LLM API 使用说明（给拿到 key 的外部使用者）

> Last updated: 2026-10-30
>
> 这份文档是公开的，**不含任何密钥**。你的 API key 会单独私下发给你。
> 文档中的所有示例、配置与错误码均在公网端点经过实测验证。

---

## 目录

- [速览](#速览)
- [1. 快速验证：确认 key 可用](#1-快速验证确认-key-可用)
- [2. 模型选型与最佳配置推荐](#2-模型选型与最佳配置推荐)
  - [2.1 模型特性与选型推荐](#21-模型特性与选型推荐)
  - [2.2 核心配置与避坑指南（为什么觉得慢 & 怎么配最合理）](#22-核心配置与避坑指南为什么觉得慢--怎么配最合理)
- [3. 在终端 CLI 工具中指定与配置模型](#3-在终端-cli-工具中指定与配置模型)
  - [3.1 通用环境变量（各类 AI 终端工具）](#31-通用环境变量各类-ai-终端工具)
  - [3.2 Qwen Code CLI](#32-qwen-code-cli)
  - [3.3 Claude Code CLI](#33-claude-code-cli)
  - [3.4 Codex CLI](#34-codex-cli)
  - [3.5 Magpie CLI](#35-magpie-cli)
- [4. 在代码中调用（Python SDK 示例）](#4-在代码中调用python-sdk-示例)
  - [4.1 基础对话（指定模型）](#41-基础对话指定模型)
  - [4.2 思考（推理）模式控制](#42-思考推理模式控制)
  - [4.3 流式输出（推荐）](#43-流式输出推荐)
  - [4.4 图片视觉输入](#44-图片视觉输入)
  - [4.5 生成速度基准参考](#45-生成速度基准参考)
- [5. 常见错误与排查](#5-常见错误与排查)
- [6. 使用约定与限制](#6-使用约定与限制)

---

## 速览

| 配置项 | 对应参数 | 说明 |
|---|---|---|
| **接口地址 (Base URL)** | `https://llm.meirong.dev/v1` | 兼容 OpenAI 标准 API |
| **协议标准** | OpenAI Chat Completions（含流式、视觉输入、思考字段）| 支持 Anthropic 协议直接转译 |
| **鉴权方式** | `Authorization: Bearer <你的 key>` | HTTP Header |
| **可用模型** | 以你的 key 实际权限为准 | 用下方命令查询 |
| **服务可用性** | 自托管在个人硬件上，**无 SLA 保障** | 可能因维护或网络波动离线 |

> [!TIP]
> 任何支持配置「自定义 Base URL」的 OpenAI 兼容客户端（包括各类 SDK、Open WebUI、Chatbox、以及各类终端命令行工具）均可直接接入。

---

## 1. 快速验证：确认 key 可用

拿到 key 后，打开终端执行以下命令进行连通性测试：

```bash
curl -s https://llm.meirong.dev/v1/models \
  -H "Authorization: Bearer <你的 key>"
```

返回 JSON 中的 `data[].id` 即为**你这把 key 获权访问的模型列表**。在后续调用中，`model` 参数必须逐字匹配其中之一。

---

## 2. 模型选型与最佳配置推荐

### 2.1 模型特性与选型推荐

网关当前提供两套自托管主力模型，特性与硬件算力不同，应根据使用场景合理指定：

| 模型名（调用时填写的 ID） | 物理承载硬件 | 吞吐速度 (tok/s) | 上下文窗口 | 适用场景与推荐 |
|---|---|---|---|---|
| **`qwen3.8-flash-next-tp2`**（默认推荐）| DGX 双机 TP=2 (NVFP4 投机解码) | **~90–110** | 262k | **日常写代码、代码补全、Agent 多轮工具调用、日常快速问答**。延迟极低，首字毫秒级响应，推荐作为首选模型。 |
| **`studio/qwen3.8-27b`** | Mac Studio M5 Max (128G 统一内存) | **~30–45** | 262k | **复杂架构设计、深度逻辑推理、长文本深度归纳、图片/视觉多模态输入**。参数规模更大，逻辑更强。 |

---

### 2.2 核心配置与避坑指南（为什么觉得慢 & 怎么配最合理）

走网关使用 Key 访问时，网络与鉴权层的纯转发耗时仅增加 **~0.2 秒**（几乎不可感）。如果感觉响应明显缓慢或等待长达数秒，请对照以下三项核心配置进行优化：

#### ① 务必开启流式传输（Streaming）
* **原理**：大模型生成一段完整回答可能需要 3–8 秒。如果不开启流式传输（`stream: false`），客户端必须等待所有文字完全生成后才一次性返回，造成“界面卡死”的错觉。
* **最佳做法**：终端 CLI 工具（如 Qwen Code / Codex）默认均开启流式；若使用 SDK 或第三方应用，**务必确保启用 `stream: true`**，首字只需 0.5 秒左右即可实时打字输出。

#### ② 合理控制“思考（Thinking）模式”
* **原理**：这两个模型**默认都开启了深思（CoT 推理）模式**。模型在回答前会先在底层进行几十到数百个 Token 的思考，并输出在 `reasoning_content` 中。如果你的客户端界面没有实时渲染思考过程，你就会看着光标“空白发呆”好几秒。
* **最佳做法**：
  - **需要严谨推理/复杂重构时**：保留思考模式，但**务必保证 `max_tokens` 足够宽裕（建议 $\ge 1024$）**。若配额过小，配额全在思考阶段被耗光，会导致最终返回的答案为空。
  - **追求极速响应/代码补全/结构化输出时**：**显式关闭思考模式**。关闭后模型会跳过内心推导直奔主题，首字立刻输出：
    - Python SDK：在请求中传入 `extra_body={"chat_template_kwargs": {"enable_thinking": False}}`
    - 原生 HTTP 请求：在 JSON 顶层加入 `"chat_template_kwargs": {"enable_thinking": false}`

#### ③ 警惕超大 Prompt 预处理（Prefill）耗时
* **原理**：在终端代码工具中，客户端会将你工作区的上下文代码自动打包发送。大模型在吐出第一个字前，必须把输入的全部代码“读完一遍”（Prompt Prefill 阶段）。在读取数万 Token 的海量代码时，即使是 DGX 也需要 1–3 秒，Mac Studio 则需要数秒。
* **最佳做法**：确保项目根目录拥有完善的 `.gitignore`，避免把 `node_modules/`、`target/`、`.git/` 等构建产物和海量无关文件一并注入给模型。

---

## 3. 在终端 CLI 工具中指定与配置模型

以下是在常用终端 AI 编程助手工具中**指定模型**与**推荐配置**的说明：

### 3.1 通用环境变量（各类 AI 终端工具）

大多数终端工具（如 `aider`、`sgpt`、`open-interpreter` 等）会优先读取标准 OpenAI 环境变量：

```bash
export OPENAI_BASE_URL="https://llm.meirong.dev/v1"
export OPENAI_API_KEY="<你的 key>"
export OPENAI_MODEL="qwen3.8-flash-next-tp2"   # 指定默认模型
```

可将上述配置追加到你的 Shell 配置文件中（`~/.zshrc` 或 `~/.bashrc`）。

---

### 3.2 Qwen Code CLI

阿里开源的代码生成终端工具（`npm install -g @qwen-code/qwen-code`，启动命令为 `qwen`）。

#### 方法 A：环境变量方式（最简便、推荐）

```bash
export OPENAI_BASE_URL="https://llm.meirong.dev/v1"
export OPENAI_API_KEY="<你的 key>"
export OPENAI_MODEL="qwen3.8-flash-next-tp2"   # 日常极速编程

# 若需切换为 27B 深度推理模型：
# export OPENAI_MODEL="studio/qwen3.8-27b"

qwen
```

#### 方法 B：单次启动命令行参数指定模型

```bash
# 启动时使用 -m 指定模型
qwen --openai-base-url "https://llm.meirong.dev/v1" \
     --openai-api-key "<你的 key>" \
     -m "qwen3.8-flash-next-tp2"
```

#### 方法 C：配置文件持久化（`~/.qwen/settings.json`）

在 `~/.qwen/settings.json` 中配置，这样无需每次设置环境变量：

```json
{
  "model": {
    "baseUrl": "https://llm.meirong.dev/v1",
    "name": "qwen3.8-flash-next-tp2"
  },
  "modelProviders": {
    "openai": [
      {
        "id": "qwen3.8-flash-next-tp2",
        "name": "Qwen 3.8 Flash Next (DGX TP2)",
        "baseUrl": "https://llm.meirong.dev/v1"
      },
      {
        "id": "studio/qwen3.8-27b",
        "name": "Qwen 3.8 27B (Mac Studio)",
        "baseUrl": "https://llm.meirong.dev/v1"
      }
    ]
  },
  "security": {
    "auth": {
      "selectedType": "openai",
      "baseUrl": "https://llm.meirong.dev/v1",
      "apiKey": "<你的 key>"
    }
  }
}
```

---

### 3.3 Claude Code CLI

网关原生支持 Anthropic 协议转译。通过配置 Anthropic 环境变量，可无缝代理 Claude Code（`@anthropic-ai/claude-code`）：

```bash
export ANTHROPIC_BASE_URL="https://llm.meirong.dev"
export ANTHROPIC_API_KEY="<你的 key>"

# 启动并通过 --model 指定目标模型
claude --model "qwen3.8-flash-next-tp2"
```

> [!NOTE]
> Claude Code 启动时可能会提示该模型 ID 为非官方 Anthropic 模型，并自动设定为 200k 上下文窗口，这属于正常现象，不影响代码交互与执行。

---

### 3.4 Codex CLI

在 `~/.codex/config.toml` 中配置网关 Provider（注意：新版 Codex 必须使用 `wire_api = "responses"`）：

```toml
[model_providers.litellm]
name = "LiteLLM"
base_url = "https://llm.meirong.dev/v1"
wire_api = "responses"
env_key = "LLM_KEY"
```

在自定义 profile（如 `~/.codex/litellm.config.toml`）中指定模型：

```toml
model = "qwen3.8-flash-next-tp2"
model_provider = "litellm"
```

运行与启动：

```bash
export LLM_KEY="<你的 key>"
codex --profile litellm

# 也可以通过命令行参数动态切换模型：
# codex --profile litellm -m studio/qwen3.8-27b
```

---

### 3.5 Magpie CLI

若使用 Magpie 进行多模型路由分发：

```bash
# 添加网关 Provider
magpie provider add homelab https://llm.meirong.dev/v1 --key "<你的 key>" --type openai

# 创建路由组（DGX 主力优先，Mac Studio 兜底）
magpie group add qwen models=homelab/qwen3.8-flash-next-tp2,homelab/studio/qwen3.8-27b routing=order

# 连通性测试
magpie provider test homelab
```

---

## 4. 在代码中调用（Python SDK 示例）

环境安装：
```bash
pip install openai
```

### 4.1 基础对话（指定模型）

```python
import os
from openai import OpenAI

client = OpenAI(
    base_url="https://llm.meirong.dev/v1",
    api_key=os.environ.get("LLM_KEY", "<你的 key>"),
)

# 指定调用 DGX 主力极速模型
resp = client.chat.completions.create(
    model="qwen3.8-flash-next-tp2",
    messages=[{"role": "user", "content": "用三句话解释什么是 LRU 缓存。"}],
    max_tokens=512,
)

print(resp.choices[0].message.content)
```

---

### 4.2 思考（推理）模式控制

`studio/qwen3.8-27b` 及自托管模型默认开启推理思考：

```python
# 1. 深度思考场景：保留思考，max_tokens 必须预留充分
resp_deep = client.chat.completions.create(
    model="studio/qwen3.8-27b",
    messages=[{"role": "user", "content": "分析分布式系统中使用两阶段提交有哪些劣势？"}],
    max_tokens=2048,  # 留足思考与正文配额
)
# 思考过程在 reasoning_content，答案在 content
print("思考:", getattr(resp_deep.choices[0].message, "reasoning_content", None))
print("回答:", resp_deep.choices[0].message.content)

# 2. 极速场景：显式关闭思考，消除延迟
resp_fast = client.chat.completions.create(
    model="studio/qwen3.8-27b",
    messages=[{"role": "user", "content": "17 乘以 23 等于多少？直接输出数字。"}],
    max_tokens=64,
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},
)
print("直接回答:", resp_fast.choices[0].message.content)  # 391
```

---

### 4.3 流式输出（推荐）

强烈建议在所有客户端启用流式输出，彻底消除等待感：

```python
stream = client.chat.completions.create(
    model="qwen3.8-flash-next-tp2",
    messages=[{"role": "user", "content": "从 1 数到 5，逗号分隔。"}],
    max_tokens=64,
    stream=True,
)

for chunk in stream:
    if chunk.choices and chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
print()
```

---

### 4.4 图片视觉输入

`studio/qwen3.8-27b` 支持视觉理解，图片需以 base64 Data URL 内联传输：

```python
import base64

with open("photo.png", "rb") as f:
    b64 = base64.b64encode(f.read()).decode("utf-8")

resp = client.chat.completions.create(
    model="studio/qwen3.8-27b",
    messages=[{
        "role": "user",
        "content": [
            {"type": "text", "text": "简要描述这张图片中的主要内容。"},
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
        ],
    }],
    max_tokens=512,
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},
)

print(resp.choices[0].message.content)
```

---

### 4.5 生成速度基准参考

在开启流式输出的前提下，自托管节点实测基准速度如下：
- **`qwen3.8-flash-next-tp2`**：约 90–110 tok/s，首字延迟（TTFT）通常在 0.4–0.5 秒内。
- **`studio/qwen3.8-27b`**：约 30–45 tok/s，大模型推理及超长提示词（如 1.5 万 token）预处理约需 5–10 秒。

---

## 5. 常见错误与排查

接口返回标准 OpenAI 格式的错误响应（`{"error": {"message": ..., "type": ..., "code": ...}}`）：

| 状态码 | 错误类型 (`error.type`) / 响应特征 | 原因与排查处理 |
|---|---|---|
| **401** | `token_not_found_in_db` | 提供的 API key 无效（检查是否复制了多余字符或空格）。 |
| **401** | `expired_key` | 密钥已过有效期，请联系管理员续期。 |
| **403** | `key_model_access_denied` | 请求的 `model` 不在当前 key 的授权白名单内，请对照 `/v1/models` 检查拼写。 |
| **403** | 响应体包含 `error code: 1010` | 来源请求触发了 Cloudflare 安全拦截（通常因为客户端 User-Agent 为空或使用了默认 `Python-urllib`）；建议使用标准 SDK 或手动指定常见 UA。 |
| **429** | `throttling_error` | 超出该 key 的速率限制（如 60 RPM）或并发上限（如 2 并发）；稍作休眠重试即可。 |
| **400** | 具体见 `message` 说明 | 请求参数非法（例如非法档位参数、上下文超限等）。 |
| **502 / 503** | 网关离线或上游维护 | 自托管推理主机维护或短时重启中，建议加入指数退避重试。 |
| **524** | Cloudflare 超时 | 非流式请求超过 100 秒未返回。在处理超长上下文或复杂长链思考时，**请务必开启流式传输 (`stream=True`)**。 |

---

## 6. 使用约定与限制

- **凭据安全**：API key 仅限被授权人本人使用；禁止提交至公开 git 仓库、客户端前端代码或群聊中。如怀疑泄露请第一时间告知管理员进行吊销。
- **资源保护**：服务依托个人自建硬件运行，请勿用于非授权的大规模并发压测或批量爬取任务。
- **隐私保护**：网关仅对每次调用的时间、模型名、token 用量、客户端来源 IP 与 User-Agent 做统计与账本记录，**绝不记录或存储你的具体对话与 Prompt 内容**。
- **稳定性预期**：本服务属于个人实验性质，不提供 SLA 商业保障；关键任务请在客户端侧配置备用服务重试。
