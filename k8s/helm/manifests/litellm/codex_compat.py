"""codex_compat — 把 Codex 私有的 Responses input item 降级成上游认识的形状。

挂在 LiteLLM 的 `async_pre_call_hook` 上（litellm_settings.callbacks），只处理
responses 路由，在转发给上游之前改写请求体。

## 为什么需要

codex 的多 agent 协议（模型 catalog 里 `multi_agent_version: "v2"`）会把 agent 之间的
消息作为 `{"type": "agent_message", author, recipient, content}` item 追加进会话历史 ——
父给子的 NEW_TASK、子回父的 FINAL_ANSWER 都走这一种。它是 codex 私有的 ResponseItem
变体，**不在 openai-python 的 `ResponseInputItemParam` union 里**；而 vLLM / OMLX 的
`/v1/responses` 正是拿那套 pydantic 模型校验 `input` 的，于是每个 union 分支各报一条错：

    HTTP 400 {"error":{"message":"216 validation errors:\\n
      {'type': 'string_type', 'loc': ('body','input','str'), ...
      ... 'msg': "Input should be 'shell_call'" ...

☠️ 那句 `Input should be 'shell_call'` 是误导：跟 shell 工具毫无关系，只是 pydantic 把
整个 union 挨个试了一遍、把每个分支的失败都列了出来。真正的原因只有一个 —— 多了一个
上游不认识的 item type。表现上是「codex 一派 subagent 就 Agent errored」。

没有这一层的话，任何强制派 subagent 的 skill（understand / understand-knowledge 之类）
在自托管上游上第一批 dispatch 就挂。

## 改写规则

2026-09-08 拿 DGX vLLM 的 `/openapi.json` 实测：`input` 只接受 30 种 `type` 字面量，
下面这 4 种是 codex 会发、而它不认的（其余 codex 变体 —— reasoning / function_call /
tool_search_call / compaction / compaction_trigger 等 —— 都在 union 里，不用动）：

  - agent_message                                → 降级成 role=user 的 message
  - context_compaction                           → 有正文就降级成 message，否则丢弃
  - encrypted_function_args                      → 丢弃（OpenAI 后端专用的不透明产物）
  - internal_chat_message_metadata_passthrough   → 丢弃（同上）

降级成 message 是无损的：agent_message 的正文本身就带着
`Message Type: FINAL_ANSWER / Task name: … / Sender: … / Payload:` 这个信封，而 codex 给
模型的系统提示就是按这个格式教它读的（"You will receive messages in the analysis channel
in the form: …"）。所以模型侧看到的东西没变，只是包装从私有 item 变成了普通 message。

白名单式改写：只碰上面这 4 种，其余原样透传 —— 上游以后支持了新的合法类型，这层不会挡。

## 作用域与失败模式

只处理 `aresponses` / `responses`，chat/completions 一律不碰。不按 model 分流：本网关没有
任何上游是真正的 OpenAI Responses 后端（DGX vLLM、Mac OMLX、OpenRouter、NVIDIA 都不认
agent_message），分流只会多一处要跟着改的地方。

任何异常都原样返回请求体。这层只做兼容降级，不该成为网关的新故障点 —— 改写失败最坏是
恢复成「没这层」的行为（多 agent 会话 400），而不是把普通请求也带下去。
"""

from typing import Any, Dict, List, Optional, Tuple

from litellm._logging import verbose_proxy_logger
from litellm.integrations.custom_logger import CustomLogger

REWRITE_TO_MESSAGE = ("agent_message", "context_compaction")
DROP = ("encrypted_function_args", "internal_chat_message_metadata_passthrough")

RESPONSES_CALL_TYPES = ("aresponses", "responses")


def _extract_text(item: Dict[str, Any]) -> str:
    """把 item 的 content 拼成纯文本。content 可能是 str，也可能是 part 列表。"""
    content = item.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: List[str] = []
    for part in content:
        if isinstance(part, str):
            parts.append(part)
        elif isinstance(part, dict):
            text = part.get("text")
            if isinstance(text, str):
                parts.append(text)
    return "".join(parts)


def _to_message(item: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """降级成一个 role=user 的 input message；没有正文就返回 None（交给调用方丢弃）。"""
    text = _extract_text(item)
    if not text:
        return None
    # codex 自己发的正文已经带信封；别处来的补一个，免得模型丢掉 sender/recipient。
    if not text.startswith("Message Type:"):
        author = item.get("author")
        recipient = item.get("recipient")
        if author or recipient:
            text = (
                "Message Type: MESSAGE\n"
                f"Task name: {recipient or 'unknown'}\n"
                f"Sender: {author or 'unknown'}\n"
                "Payload:\n" + text
            )
    # 刻意不带原 item 的 id：`amsg_…` 不是合法的 message id，上游没有理由认它。
    return {"type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}


def normalize_input(value: Any) -> Tuple[Any, Dict[str, int]]:
    """返回 (改写后的 input, 各类型命中计数)。input 不是 list 时原样返回。"""
    if not isinstance(value, list):
        return value, {}

    stats: Dict[str, int] = {}

    def bump(kind: str, item_type: str) -> None:
        key = f"{kind}:{item_type}"
        stats[key] = stats.get(key, 0) + 1

    out: List[Any] = []
    for item in value:
        if not isinstance(item, dict):
            out.append(item)
            continue
        item_type = item.get("type")
        if item_type in DROP:
            bump("dropped", item_type)
            continue
        if item_type in REWRITE_TO_MESSAGE:
            replacement = _to_message(item)
            if replacement is None:
                bump("dropped", item_type)
                continue
            bump("rewrote", item_type)
            out.append(replacement)
            continue
        out.append(item)
    return out, stats


class CodexCompat(CustomLogger):
    """`litellm_settings.callbacks` 里注册的那个实例。

    ⚠️ 首次改写刻意打 WARNING（之后才降到 INFO）：`verbose_proxy_logger` 在本部署里
    没设 `LITELLM_LOG`，**生效级别是 WARNING**，INFO 一律被丢掉。全用 INFO 的话
    「这层到底有没有在干活」就完全不可观测 —— 而它的失效形态本来就是安静的。
    一个 pod 一条，不刷屏。
    """

    def __init__(self) -> None:
        super().__init__()
        self._announced = False

    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict,
        call_type: str,
    ) -> Optional[dict]:
        if call_type not in RESPONSES_CALL_TYPES:
            return None
        try:
            new_input, stats = normalize_input(data.get("input"))
        except Exception as exc:  # 兼容层不许把请求搞挂
            verbose_proxy_logger.warning("codex_compat: input 改写失败，原样透传: %s", exc)
            return None
        if not stats:
            return None  # 返回 None = 不改动，省掉一次 data 覆写
        data["input"] = new_input
        summary = ", ".join(f"{k}={v}" for k, v in sorted(stats.items()))
        model = data.get("model", "?")
        if not self._announced:
            self._announced = True
            verbose_proxy_logger.warning(
                "codex_compat: 本层已生效（首次改写，后续降为 INFO）—— %s: %s", model, summary
            )
        else:
            verbose_proxy_logger.info("codex_compat: 归一化 %s 的 responses input: %s", model, summary)
        return data


codex_compat_handler = CodexCompat()
