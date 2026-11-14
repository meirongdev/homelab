"""upstream_compat — 把请求改写成「目标上游声明过能接受」的形状，别让兜底静默接走。

挂在 LiteLLM 的 `async_pre_call_hook` 上（litellm_settings.callbacks）。只改写**指名的
model group 在 config.yaml 的 `model_info` 里声明过**的那两件事，没声明的上游一律不碰。

## 为什么需要

2026-11 的 DGX 栈（vLLM + Qwen chat template）有两种请求会回 400，而 Mac 的 OMLX 两种都接受
（11-15 换上的 DeepSeek-V4.1 / TensorFold 两种都接受，所以当前 config 里没有声明，本层对它是空操作；
留着它是为了下一个挑剔的栈只需加两行声明）：

  1. 对话中间出现 role=system 消息 → `400 System message must be at the beginning.`
     （Qwen 模板里的 raise_exception）。Claude Code 2.1.31x 起把 `# Environment` 块作为
     `messages[1]` 的 role=system 发出来，经 LiteLLM 翻译后原样到达 DGX。
  2. `reasoning_effort` 不在它的档位集合里 → `400 Unexpected reasoning effort high`。
     DGX 只认 low / medium / xhigh；magpie 一类代理会把客户端的 `high` 透传过来。

DGX 的裸别名（当时是 `qwen3.8-flash-next-tp2`）配了 `mac/ornith` 兜底，所以这两种 400 **不会报错**：
请求被悄悄转给 M2，调用方只觉得慢（Ornith 30–47s，DGX 几秒），响应里的 `model` 变成
`ornith-ai__…`。2026-11-13 查外发 key 时发现 3 把 key 的主力请求全落在 M2 上，DGX 空着。
没有这一层时，唯一的痕迹是 spend log 里 `original_model_group ≠ model_group`。

## 改写规则（声明在 config.yaml 的 model_info，换栈时跟模型条目一起改；值是 11-14 给 Qwen 栈写的）

  upstream_system_first: true
      非首位的 role=system 消息并进开头的 system 提示（追加在末尾，静态前缀不动，
      上游的前缀缓存照样命中）。chat 格式并进 messages[0]（没有就新建一条）；
      Anthropic 格式（/v1/messages）并进顶层 `system`。

  upstream_reasoning_efforts: [low, medium, xhigh]
      请求的档位不在集合里时，换成集合中**不低于**它的最小档；没有更高的就取最高档。
      high→xhigh、minimal→low、none→low（DGX 没有关思考的档位；真要关思考用
      chat_template_kwargs）。不认识的值不猜，原样交给上游报错。
      覆盖 chat 的 `reasoning_effort` 和 responses 的 `reasoning.effort`。chat 里
      {"effort","summary"} 这种 dict 形式会被 LiteLLM 原样转发、vLLM 只认字符串，所以压平成
      字符串。Ornith 也接受换后的值（11-14 实测 xhigh/medium/low 均 200），改写不会弄坏兜底。

  ⚠️ /v1/messages 打 `openai/` 上游时，LiteLLM（1.103.1）走的是 **Responses API**（上游收到
  `instructions` + `input`），不是 chat。本层在 Anthropic 格式上把 system 并进顶层 `system`，
  翻译后就全落在 `instructions` 里，`input` 不再有 system 项。

声明按**指名的 model group** 取：兜底到别的 group 时沿用同一份已改写的请求。

## 作用域与失败模式

- 不处理 Anthropic 的 `thinking` / `output_config`：那条路在 LiteLLM 参数映射层就以
  `UnsupportedParamsError … reasoning.effort` 拒掉，DGX 和 Ornith 都到不了；Claude Code 会去掉
  thinking 重试，重试那次才轮到本层的规则 1。
- 读声明靠 `proxy_server.llm_router.get_model_list()`；拿不到路由表就当没声明。
- 任何异常都原样透传请求（与 codex_compat 同一原则）：改写失败最坏是回到「没这层」的
  行为（DGX 400 → 兜底），不能把正常请求带下去。新值全部算好才一次性写回 data。

## 验证（本机任意目录）

    kubectl --context k3s-homelab -n litellm logs deploy/litellm | grep upstream_compat

每个 pod 首次改写打一条 WARNING（`本层已生效…`），之后降到 INFO：本部署没设 `LITELLM_LOG`，
INFO 被丢掉，全用 INFO 的话「没在干活」和「今天没流量」分不出。行为判据是
spend log 里外发 key 不再出现 `model_group='mac/ornith'` 且 `original_model_group` 为 DGX 别名。
"""

from typing import Any, Dict, List, Optional, Tuple

from litellm._logging import verbose_proxy_logger
from litellm.integrations.custom_logger import CustomLogger

KEY_EFFORTS = "upstream_reasoning_efforts"
KEY_SYSTEM_FIRST = "upstream_system_first"

# 从低到高。不在这里的值视为「不认识」，不改写。
EFFORT_ORDER = ("none", "minimal", "low", "medium", "high", "xhigh", "max")

CHAT_CALL_TYPES = ("completion", "acompletion")
ANTHROPIC_CALL_TYPES = ("anthropic_messages",)
RESPONSES_CALL_TYPES = ("responses", "aresponses")


# ── 纯函数（不碰 LiteLLM，便于单测）────────────────────────────────────────────


def nearest_effort(requested: Any, allowed: Optional[List[str]]) -> Optional[str]:
    """返回替换后的档位；不需要替换（或不该猜）时返回 None。"""
    if not isinstance(requested, str) or not allowed or requested in allowed:
        return None
    if requested not in EFFORT_ORDER:
        return None
    ranked = sorted((a for a in allowed if a in EFFORT_ORDER), key=EFFORT_ORDER.index)
    if not ranked:
        return None
    want = EFFORT_ORDER.index(requested)
    for level in ranked:
        if EFFORT_ORDER.index(level) >= want:
            return level
    return ranked[-1]


def map_chat_effort(value: Any, allowed: Optional[List[str]]) -> Tuple[Any, Optional[str]]:
    """chat 的 `reasoning_effort`。返回 (新值, 描述)；描述为 None 表示没改。

    可能是字符串，也可能是 {"effort": ..., "summary": ...}。后者 LiteLLM 会原样转发，而
    vLLM 只认字符串 → 400 → 兜底，所以对声明过档位的上游**压平成字符串**（summary 它本来
    也不支持）。
    """
    if isinstance(value, dict):
        effort = value.get("effort")
        target = nearest_effort(effort, allowed) or effort
        if isinstance(target, str) and allowed and target in allowed:
            return target, f"{effort}(dict)→{target}"
        return value, None
    new = nearest_effort(value, allowed)
    if new is None:
        return value, None
    return new, f"{value}→{new}"


def map_responses_reasoning(value: Any, allowed: Optional[List[str]]) -> Tuple[Any, Optional[str]]:
    """responses 的 `reasoning`（按规范就是 dict），只换里面的 effort。"""
    if not isinstance(value, dict):
        return value, None
    new = nearest_effort(value.get("effort"), allowed)
    if new is None:
        return value, None
    return {**value, "effort": new}, f'{value.get("effort")}→{new}'


def _text_of(content: Any) -> str:
    """把 content（str 或 part/block 列表）拼成纯文本。"""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: List[str] = []
    for part in content:
        if isinstance(part, str):
            parts.append(part)
        elif isinstance(part, dict) and isinstance(part.get("text"), str):
            parts.append(part["text"])
    return "".join(parts)


def hoist_system_chat(messages: Any) -> Optional[List[Any]]:
    """chat 格式：非首位的 system 消息并进 messages[0]。无需改动返回 None。"""
    if not isinstance(messages, list):
        return None
    late = {
        i for i, m in enumerate(messages)
        if i > 0 and isinstance(m, dict) and m.get("role") == "system"
    }
    if not late:
        return None
    texts = [t for t in (_text_of(messages[i].get("content")) for i in sorted(late)) if t]
    rest = [m for i, m in enumerate(messages) if i not in late]
    if not texts:
        return rest
    head = rest[0] if rest else None
    if isinstance(head, dict) and head.get("role") == "system":
        content = head.get("content")
        if isinstance(content, list):
            merged: Any = list(content) + [{"type": "text", "text": t} for t in texts]
        else:
            merged = "\n\n".join(x for x in [_text_of(content), *texts] if x)
        rest[0] = {**head, "content": merged}
    else:
        rest.insert(0, {"role": "system", "content": "\n\n".join(texts)})
    return rest


def hoist_system_anthropic(messages: Any, system: Any) -> Optional[Tuple[List[Any], Any]]:
    """Anthropic 格式：messages 里的 role=system 全部并进顶层 system。无需改动返回 None。"""
    if not isinstance(messages, list):
        return None
    late = {i for i, m in enumerate(messages) if isinstance(m, dict) and m.get("role") == "system"}
    if not late:
        return None
    blocks: List[Dict[str, Any]] = []
    for i in sorted(late):
        content = messages[i].get("content")
        if isinstance(content, str):
            if content:
                blocks.append({"type": "text", "text": content})
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text" and block.get("text"):
                    blocks.append(block)
                elif isinstance(block, str) and block:
                    blocks.append({"type": "text", "text": block})
    rest = [m for i, m in enumerate(messages) if i not in late]
    if isinstance(system, list):
        new_system: Any = list(system) + blocks
    elif isinstance(system, str) and system:
        new_system = [{"type": "text", "text": system}] + blocks
    else:
        new_system = blocks or system
    return rest, new_system


def rewrite(
    data: Dict[str, Any], call_type: str, efforts: Optional[List[str]], system_first: bool
) -> List[str]:
    """按声明改写 data，返回改动描述（空列表 = 没改）。先算好全部新值，最后一次性写回。"""
    updates: Dict[str, Any] = {}
    changes: List[str] = []

    if system_first and call_type in CHAT_CALL_TYPES:
        new_messages = hoist_system_chat(data.get("messages"))
        if new_messages is not None:
            updates["messages"] = new_messages
            changes.append("system 消息并到开头")
    elif system_first and call_type in ANTHROPIC_CALL_TYPES:
        hoisted = hoist_system_anthropic(data.get("messages"), data.get("system"))
        if hoisted is not None:
            updates["messages"], updates["system"] = hoisted
            changes.append("system 消息并进顶层 system")

    if efforts:
        if call_type in CHAT_CALL_TYPES and "reasoning_effort" in data:
            new_value, desc = map_chat_effort(data["reasoning_effort"], efforts)
            if desc:
                updates["reasoning_effort"] = new_value
                changes.append(f"reasoning_effort {desc}")
        elif call_type in RESPONSES_CALL_TYPES and isinstance(data.get("reasoning"), dict):
            new_value, desc = map_responses_reasoning(data["reasoning"], efforts)
            if desc:
                updates["reasoning"] = new_value
                changes.append(f"reasoning.effort {desc}")

    data.update(updates)
    return changes


# ── LiteLLM 接线 ──────────────────────────────────────────────────────────────


def declared_rules(model_group: Any) -> Tuple[Optional[List[str]], bool]:
    """从路由表读指名 group 的声明。拿不到路由表 / 没声明 → (None, False)。"""
    if not isinstance(model_group, str) or not model_group:
        return None, False
    import litellm.proxy.proxy_server as proxy_server  # 调用时才 import：proxy 启动后才有路由表

    router = getattr(proxy_server, "llm_router", None)
    if router is None:
        return None, False
    efforts: Optional[List[str]] = None
    system_first = False
    for deployment in router.get_model_list(model_name=model_group) or []:
        info = deployment.get("model_info") or {}
        declared = info.get(KEY_EFFORTS)
        if efforts is None and isinstance(declared, list):
            efforts = [e for e in declared if isinstance(e, str)]
        if info.get(KEY_SYSTEM_FIRST) is True:
            system_first = True
    return efforts, system_first


class UpstreamCompat(CustomLogger):
    """`litellm_settings.callbacks` 里注册的那个实例。日志策略见文件头「验证」。"""

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
        if call_type not in CHAT_CALL_TYPES + ANTHROPIC_CALL_TYPES + RESPONSES_CALL_TYPES:
            return None
        model = data.get("model")
        try:
            efforts, system_first = declared_rules(model)
            if not efforts and not system_first:
                return None
            changes = rewrite(data, call_type, efforts, system_first)
        except Exception as exc:  # 兼容层不许把请求搞挂
            verbose_proxy_logger.warning("upstream_compat: 改写失败，原样透传: %s", exc)
            return None
        if not changes:
            return None
        summary = "; ".join(changes)
        if not self._announced:
            self._announced = True
            verbose_proxy_logger.warning(
                "upstream_compat: 本层已生效（首次改写，后续降为 INFO）—— %s [%s]: %s", model, call_type, summary
            )
        else:
            verbose_proxy_logger.info("upstream_compat: %s [%s]: %s", model, call_type, summary)
        return data


upstream_compat_handler = UpstreamCompat()
