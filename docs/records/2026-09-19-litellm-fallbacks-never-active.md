# LiteLLM 兜底链从落地起就没生效过：`fallbacks` 写在了 `litellm_params` 里

> 日期: 2026-09-19（问题自 2026-08-01 网关落地即存在；10-04 复测补记）
> 影响: 「DGX 主 + Mac 兜底」七周里只是声明。主上游任何失败（连接级或参数级）裸别名都回 500
>       `LLM Provider NOT provided ... You passed model=mac/ornith`：既没切到 Mac，调用方也拿不到真实原因
> 根因: 兜底声明在模型条目的 `litellm_params.fallbacks` 里。LiteLLM 把它当作透传给 SDK 的 kwarg，
>       不解析 model_list，拿裸字符串 `mac/ornith` 去找 provider。路由层的兜底只认顶层 `router_settings.fallbacks`
> 处置: 挪到 `router_settings.fallbacks: [{"<主>": ["<兜底>"]}]`，先用线上同 digest 镜像在本地复现并验证修法再上线

## 经过

| 时间 | 事件 |
|------|------|
| 2026-08-01 | 网关落地，兜底链写在裸别名条目的 `litellm_params.fallbacks` 里 |
| 首次撞见 | 经网关传 `reasoning_effort` 回 500 `LLM Provider NOT provided ... model=mac/ornith`。读起来像 Mac 那边配错或睡着 |
| 2026-09-19 | 本地复现确认兜底从未生效，修法实测通过后上线；同日实测 key 白名单不挡兜底（见下） |
| 上线后 | 看生产日志订正了 400 那一行的机制（见下） |
| 2026-10-04 | 复测：网关已会把 `reasoning_effort` 转发给上游，裸别名传 DGX 不认、Mac 认的 `minimal` 时，兜底真的打到 Mac，回 200 |

## 复现方法

不碰生产：线上同一 digest 的 `litellm/litellm` 镜像 + 本地 Postgres + 从**真实清单渲染**出的 config，
只把两个 `api_base` 换成「死端口」和「假 Mac」。

| 场景 | 旧形态（`litellm_params.fallbacks`） | 修法（`router_settings.fallbacks`） |
|---|---|---|
| 主上游连接失败（死端口） | 500 `LLM Provider NOT provided` | 200，内容来自兜底 |
| 主上游 400（`reasoning_effort` 不支持） | 500 `LLM Provider NOT provided` | 400，原样回真实原因（09-19 当时；10-04 起见下） |
| 直接指名 `mac/ornith` | 200 | 200 |

## 为什么七周没被发现

1. 只在主上游失败时暴露，而 DGX 平时是通的，日常没有任何症状。
2. 报错长得像别的问题：`... model=mac/ornith` 指向 Mac，真正错的是主上游那条的声明位置。
3. 连接级与参数级失败的报错完全相同，所以第一次撞见（`reasoning_effort` 那次）无法据此判断是
   「只有参数错误才这样」还是「一直都这样」。

## 订正：400 那一行的机制

上线前的解读是「LiteLLM 识别 4xx，所以不兜底」，看生产日志后订正：LiteLLM **不按错误类型**决定要不要兜底。
它照样进 `run_async_fallback` 去试 `mac/ornith`，只是那一跳在参数映射层就抛了同一个
`UnsupportedParamsError`（`for model=ornith-ai__Ornith-1.5-35B-A3B-MLX-4bit`），没有任何 HTTP 请求发到
Mac，最后 `raise error_from_fallbacks` 把真实的 400 抛回。

净效果符合预期，但它依赖「兜底模型恰好也不接受这个参数」。2026-10-04 这个前提就破了：网关开始转发
`reasoning_effort`，Mac 接受 `minimal`、DGX 不接受，于是裸别名传 `minimal` 回 200，内容来自 Mac，
只有响应里的 `model` 看得出换了模型。

## 同日的第二个验证：key 白名单不挡兜底

ROADMAP 当时有一条推论：「4 把 key 的白名单挂着已死的 `mac/qwen3.6-35b`，那几条兜底现在就是断的」。
用同一套本地环境（主上游指死端口）建三把 key，打裸别名（必然要走兜底）：

| key 的白名单 | 结果 |
|---|---|
| 只有 `qwen3.8-27b-sglang` | 200，内容来自兜底 |
| `qwen3.8-27b-sglang` + `mac/ornith` | 200，来自兜底 |
| `qwen3.8-27b-sglang` + 已死的 `mac/qwen3.6-35b` | 200，来自兜底 |

同一把窄 key 直接指名 `mac/ornith` 仍 403（`key not allowed to access model`）。推论被推翻：当时兜底确实是断的，
但原因是声明位置，与白名单无关。那 4 把的悬空别名仍按卫生改成了 `mac/ornith`，16 把 key 的悬空别名归零。

## 留下的

- 兜底有没有发生，判据是日志里的 `run_async_fallback` / `Error doing the fallback`，不是返回码。
- 调参数、试档位用带 `custom_dgx/` 前缀的别名（刻意不配兜底），错误才会原样回来。
- `router_settings.fallbacks` 的键是别名字面量，换栈漏改同样是静默失效。
- 现行规则见 [reference/litellm-gateway.md](../reference/litellm-gateway.md) 坑 A2。
