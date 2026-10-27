# jobs-sg enrich 超时一夜从 1.2% 涨到 7.8%：推理跑飞，不是 DGX 慢

> 日期: 2026-09-04（当时 DGX 跑 `qwen38-flash-next`）
> 影响: 当晚 enrich `errors=21`（超时 21/269，前夜 3/242），run 记 partial，21 条岗位留在积压
> 根因: 推理模型在个别长岗位上触发推理循环，生成长度没有上界（最长一条 16754 completion token，
>       98.2% 是推理），300s 预算内拿不到结果。引擎读数与前夜一致，DGX 并没有变慢
> 处置: 清单加 `LLM_EXTRA_BODY={"reasoning_effort":"medium"}` 给推理封顶；`LLM_RETRIES` 保持 0；
>       不调大 `LLM_TIMEOUT`、不设 `LLM_MAX_TOKENS`。现状见 [reference/jobs-sg.md](../reference/jobs-sg.md)

## 经过

### 先排除「DGX 变慢」

引擎读数与前夜一致：每输出 token 0.043s、排队 0.06s、无抢占。慢的不是引擎，是个别请求要生成的
token 太多。

### 跑飞的形态

- 那条 OCBC 岗位不封顶要 16754 completion token（16448 是推理，占 98.2%），独占 GPU 跑 324s，
  夜里 8 并发折算约 720s。它会自己停，`finish=stop`，答案也对，只是 300s 内拿不到。
- 跑飞率随岗位正文长度上升（同一轮 298 条）：<1500 字符 0/54，1500–2500 1.2%，2500–3500 8.3%，
  >3500 15.9%。长不等于必挂，当晚最长的一条（12151 字符）就成功了。
- 生成长度是双峰的：正常 1000–2000 token、跑飞 >7000。这是触发了循环，不是内容多算得久。

### 为什么前任 `deepseek-v4-flash` 不出这个问题

靠的是自带天花板而不是速度：它每 token 慢 50%（0.064 vs 0.043s），300s 只买得到约 4700 token，
而它三晚约 640 次调用 p99≈4700、无一超过 5000，恰好落在预算里边，余量约为 0。2026-09-01 那晚
DGX 慢了 70%（0.064→0.110s，预算掉到 2737），当场挂 3 条。那次记的「DGX 变慢」和这次同源：
预算和生成长度的上沿贴得太近，哪头动都会挂。

### 找对旋钮

在当时的栈上实测（`max_tokens=3000` 兜底）：

| 请求 | 结果 |
|---|---|
| 不带参数 | 撞满 3000、`finish=length`、`content` 为空 |
| `chat_template_kwargs.thinking_budget=256` | 同上，静默无效 |
| `chat_template_kwargs.reasoning_max_tokens=256` | 同上，静默无效 |
| `chat_template_kwargs.max_thinking_tokens=256` | 同上，静默无效 |
| 顶层 `reasoning_effort: "low"` | 11.6s、reasoning 461、`finish=stop`、JSON 完整 |
| 顶层 `reasoning_effort: "minimal"` | HTTP 400 |

`reasoning_effort` 关不掉推理（`low` 仍有约 461 token），但能封顶；那个 400 说明服务端在校验
这个字段。参考文档一度写反（判据选成了「能不能把推理关掉」），据此误判它被静默忽略。

调大 `LLM_TIMEOUT` 没用，生成长度没有上界（`max_model_len` 262144）；`LLM_MAX_TOKENS` 硬封顶
更糟，模型会先把推理写满、`content` 返回 null，一次慢成功变成硬失败。

### 封顶效果

| | 默认 | `reasoning_effort: medium` |
|---|---|---|
| 前一夜超时的 5 条 | 全部 >300s 超时 | 全部 8–22s 完成，抽词更全（OCBC 那条 46→50 词） |
| 8 条正常岗位合计 | 244s / 9763 reasoning token | 82s / 3487 token，抽词几乎不变 |

### 重试

清单注释曾写「重试成功率几乎为 0」，那是 3 个样本得出的。把这轮超时的 21 条隔天重跑，16 条
一次就过（76%）：同一条岗位每次都是重新抽签，`temperature: 0` 也挡不住连续批处理带来的抖动。
`LLM_RETRIES` 仍留 0，理由换成「封顶后本来就不该有超时」。

## 之后换栈的复验

- 2026-09-19，`qwen3.8-27b-sglang`：机制成立、枚举换了。默认档是 `xhigh`；`medium` 在 6000 字
  真实提示词上把 completion 从 769 压到 409 token（推理 2816→1160 字），`low` 367 token；
  `minimal` 回 400（`Unexpected reasoning effort minimal. Supported types are xhigh (default),
  medium, and low.`）。清单里的 `medium` 原样有效。
- 2026-10-04，`qwen3.8-flash-next-tp2`（vLLM）：档位仍是 `low` / `medium` / `xhigh`（默认），
  `minimal` 和 `high` 回 400。只在一道短算术题上看过推理变短（默认 152 字 → `medium` 85 字），
  真实提示词上压缩多少没重测，跑飞的分布也没重测。
