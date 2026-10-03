# LiteLLM 网关（运维事实与坑）

> Last updated: 2026-10-04
> Status: 生效事实
> Scope: `llm.meirong.dev` 这个 LLM 网关的配置生效路径、鉴权分层、上游可用性边界，
> 本文是 source of truth。为什么选 LiteLLM、上游怎么选、Mac 兜底为何换 Ornith，见
> [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md)（决策与实测数据）。

## 速览

| | |
|---|---|
| 集群 / ns | homelab / `litellm`（**钉控制面**，只有它的 netmap 里有 DGX 与 Mac）|
| 公网入口 | `llm.meirong.dev`（Cloudflare Tunnel → Cilium Gateway → HTTPRoute）|
| 推理鉴权 | master key + 虚拟 key（`Authorization: Bearer sk-…`）|
| 管理面 | `/ui`，LiteLLM 自带登录（`UI_USERNAME`/`UI_PASSWORD`，Vault→ESO）|
| 路由表 | `k8s/helm/manifests/litellm/litellm.yaml` 的 ConfigMap（在 git 里）|
| key / spend | 同集群共享 Postgres `databases/apps-pg` 的 `litellm` 库（**不在 git 里**，见坑 A；2026-08-25 前是本 ns 自带的 `litellm-pg`）|

**配置真相源分成两半，这是本文档存在的理由**：

| 东西 | 存在哪 | 改法 |
|---|---|---|
| 模型列表 / `api_base` / `fallbacks` | git 的 ConfigMap | 改清单 → push → ArgoCD |
| **虚拟 key 能访问哪些模型** | Postgres | 只能调 API（坑 A）|
| 花费账本 / key 有效期 | Postgres | `/ui` 或 API |

## DGX 主力栈：2026-09-30 起是 Qwen3.8-Flash-Next 双机 TP=2（vLLM）

上游（`~/projects/meirongdev/nv-dgx-spark`）单方面换栈，本仓库只是跟着改引用。**这一节是本
仓库关于该上游的唯一真相源**；换栈的技术理由与压测数据在 nv-dgx-spark 仓库，不在这里复制。
☠️ **下次上游再换模型/回滚，照
[runbooks/dgx-model-swap-homelab-followup.md](../runbooks/dgx-model-swap-homelab-followup.md) 走**
——它把"改哪四处、为什么必须动 key、哪三条阈值要重估、怎么验收"写成了可照抄的 SOP。
想**减少下一次的工作量**（CI 字面值门禁 / 契约回归 probe / 虚拟 key 卫生 / served name 漂移
哨兵，含被否决的选项）→
[plans/2026-09-03-dgx-model-swap-optimizations.md](../plans/2026-09-03-dgx-model-swap-optimizations.md)
（📐 未实施，所以本页的机制描述仍是现状，别照着它以为门禁已经存在）。

⚠️ 2026-09-30 这次换栈只改了清单（`c4795ac`），本节与 jobs-sg / open-notebook 两页到
2026-10-04 才补上，期间写的一直是上一栈 SGLang `:8888`。SOP 里「改文档」那步漏掉就是这个样子。

| | |
|---|---|
| 上游栈 id | `hibrid48tp2`（Qwen3.8-Flash-Next hibrid48 NVFP4，K=5 MTP 投机解码）。定义在上游 `stacks/hibrid48tp2/stack.env` |
| served name | `qwen3.8-flash-next-tp2` |
| 端点 | `100.97.87.120:8000/v1`（head 在 S1）。上一栈的 `:8888` 已不响应（2026-10-04 实测）|
| 引擎 | vLLM 0.30.0（`GET :8000/version`）。模型名写错回 **404** `The model ... does not exist`；上一栈 SGLang「任意名字原样回显 200」的坑不再存在 |
| `max_model_len` | 262144 |
| 拓扑 / 冷启动 | **双机 TP=2，占满 S1+S2 两台的 GPU**。09-20 起在 S2 上常驻的 `fndgx`（`100.67.164.92:18300`）已停。加载约 4–5 分钟（上游 `STACK_LOAD_TIME`）。☠️ 两个 rank 必须成对起停，上游 `make restart` 是唯一安全路径，别单独重启一台 |
| 自愈 | 未核实。运行时仍是 docker + tmux（`STACK_RUNTIME` / `STACK_TMUX`），重启策略写在 DGX 本机的启动脚本里，本仓库和上游仓库都看不到 |
| 并发 | `max-num-seqs=64`。上游实测单流约 99 tok/s、64 并发聚合约 562 tok/s |
| 关思考 | `chat_template_kwargs {"enable_thinking": false}`，直连与经网关都实测有效（`reasoning_tokens=0`）|
| `reasoning_effort` | 只认 `low` / `medium` / `xhigh`（默认）；`minimal`、`high` 回 400 `Unexpected reasoning effort …`。档位集合每次换栈都变过，别跨栈照抄 |
| CoT 字段 | ☠️ **直连是 `reasoning`，经网关是 `reasoning_content`**（LiteLLM 改写，原字段留在 `provider_specific_fields.reasoning`）。直连的消费方若只读 `reasoning_content`，会恒读到空 |
| `reasoning_tokens` | 有值，关思考时为 0。上一栈 SGLang 恒为 `null` 的问题不再存在 |
| 回滚 | 上游 `make switch TO=<stack-id>`（`make stack-check` 列出可选）。☠️ 回滚要把网关别名 + jobs-sg + open-notebook + oracle calibre 四处一起回退，**外加坑 A 的 key 白名单** |

✅ **经网关可以传 `reasoning_effort`**（2026-10-04 实测，镜像 v1.103.1）：对带前缀的
`custom_dgx/qwen3.8-flash-next-tp2` 传非法档位 `minimal`，回的是 DGX 自己的 400 原文，
说明参数确实转发到了上游。本页先前写的「网关传不了，报 `UnsupportedParamsError`」是
2026-09-19 旧版 LiteLLM 的行为，已不成立。

☠️ **但裸别名上，参数错误会被兜底悄悄吞掉**：同样传 `minimal` 给 `qwen3.8-flash-next-tp2`，
DGX 回 400 → 走 `fallbacks` → `mac/ornith` 接受这个参数 → **200**，只有响应里的 `model`
（`ornith-ai__…`）看得出换了模型。调参数、试档位时用带前缀的别名，错误才会原样回来。
机制见坑 A2 末尾。

⚠️ **质量**：上游只给了速度基准（`benchmarks/hibrid48tp2-2026-09-30/`），本仓库这次换栈
没有记录输出质量的验证。

## ☠️ 坑 A：虚拟 key 的模型白名单在 Postgres 里，git 完全管不到

**每个虚拟 key 带一份 `models` 白名单**，值是模型别名的字面量。所以在 git 里给网关改
别名（重命名、删除、新增），key 那边不会跟着变，于是「清单正确 + 部署成功 + 调用全挂」。

2026-08-25 实测：把 `mac/qwen3.6-35b` 改名为 `mac/ornith` 并新增 `mac/ornith-fast` 后，
`LITELLM_VK` 的白名单仍是旧列表，任何指名新别名的调用直接被拒：

```
key not allowed to access model. This key can only access
models=['custom_dgx/deepseek-v4-flash','deepseek-v4-flash','mac/qwen3.6-35b','openrouter/*','nvidia/*'].
Tried to access mac/ornith-fast
```

**排障时最容易误判的一点**：这条错误和「配置写错了」长得一样，但 ConfigMap 是新的、
ArgoCD `Synced`/`Healthy`、pod `Running`、探针全绿。**症状在 key，不在配置。**

⚠️ **改别名必须同步改 key**，顺序无所谓但两件都要做。取 master key 并更新（本机，任意目录）：

```bash
MK=$(kubectl --context k3s-homelab -n litellm get secret litellm-secret \
      -o jsonpath='{.data.master-key}' | base64 -d)

# 先看这个 key 现在允许什么（VK = 消费方实际用的虚拟 key）
curl -s -H "Authorization: Bearer $MK" "https://llm.meirong.dev/key/info?key=$VK" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("info") or d).get("models"))'

# 覆盖白名单（整个列表替换，不是增量）
curl -s -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"key":"'"$VK"'","models":["custom_dgx/qwen3.8-flash-next-tp2","qwen3.8-flash-next-tp2",
       "mac/ornith","mac/ornith-fast","openrouter/*"]}' \
  https://llm.meirong.dev/key/update
```

### 改名时先找出**全部**受影响的 key

白名单散在 Postgres 里，只改"自己那把"必然漏。列全量的口径有两个坑：`POST /key/list`
是 **405**（要 GET + 分页），且返回的 `keys` 是 token 的 **sha256**、不是 key 原文，
所以要逐把 `key/info` 才看得到白名单：

```bash
# ⚠️ 走 homelab 的 Tailscale NodePort：经 Cloudflare 的 llm.meirong.dev 查管理接口会被
#    WAF 以 `error code: 1010`(403) 挡（非浏览器 UA）。机制见 tailscale-network.md。
GW=http://100.94.186.7:31400
curl -s -H "Authorization: Bearer $MK" "$GW/key/list?page_size=50&page=1"   # 还有 page=2
curl -s -H "Authorization: Bearer $MK" "$GW/key/info?key=<那个 sha256>"      # 逐把看 models
```

想知道哪把是本机的 `LITELLM_VK`：`printf %s "$LITELLM_VK" | sha256sum` 去匹配列表即可。

⚠️ **爆炸半径实测（2026-09-03 与 2026-09-19 两次都是）**：16 把 key 里 **8 把**的白名单
写着 DGX 别名。一次改名的正确预期是"改 8 把"，不是"改 1 把"。
`/key/update` 是**整表替换**，所以脚本要先把原列表读出来、只映射要改的那两项、其余原样带回。

✅ **「兜底会不会被 key 白名单挡住」已实测，答案是不会**（2026-09-19）。本页早先写的是
「未验证但要当真的推论：兜底别名不在白名单里就拿不到兜底」—— **实测推翻了它**。
用线上同 digest 的镜像 + Postgres + 线上那份渲染后的 config（主上游指死端口）建三把 key：

| key 的白名单 | 打裸别名（必然要走兜底） |
|---|---|
| 只有 `qwen3.8-27b-sglang` | **200，内容来自兜底** |
| `qwen3.8-27b-sglang` + `mac/ornith` | 200，来自兜底 |
| `qwen3.8-27b-sglang` + 已死的 `mac/qwen3.6-35b` | 200，来自兜底 |

即**白名单只约束「你能指名什么」，不约束路由内部的兜底跳转**。同一把窄 key 直接指名
`mac/ornith` 仍然 **403**（`key not allowed to access model`）—— 所以最小权限与兜底可以并存，
窄 key（如 `calibre-metadata-llm`）不需要为了兜底而放宽。

## ☠️ 坑 A2：`fallbacks` 写在 `litellm_params` 里 —— 声明了但**从来没生效过**

**2026-09-19 实测确认并已修复。** 兜底链从 2026-08-01 落地起就一直声明在模型条目的
`litellm_params.fallbacks` 里：

```yaml
- model_name: <裸别名>
  litellm_params:
    model: openai/<served name>
    api_base: http://…
    fallbacks: ["mac/ornith"]      # ❌ 放在这里 = SDK 级 fallback，不解析 model_list
```

LiteLLM 把这里的 `fallbacks` 当作**透传给 SDK 的 kwarg**，于是主上游一失败，它拿裸字符串
`mac/ornith` 去找 provider，报：

```
litellm.BadRequestError: LLM Provider NOT provided. ... You passed model=mac/ornith
```

**正确位置是顶层 `router_settings.fallbacks`**，值是 `[{"<主>": ["<兜底>"]}]`：

```yaml
router_settings:
  fallbacks: [{"qwen3.8-flash-next-tp2": ["mac/ornith"]}]
```

☠️ **为什么拖了这么久没被发现**（三条叠加）：

1. **它只在主上游失败时才暴露**，而 DGX 平时是通的 —— 日常没有任何症状。
2. **报错长得像别的问题**。`LLM Provider NOT provided ... model=mac/ornith` 读起来像
   "Mac 那边配错了/睡着了"，而真正的错在**主上游那条**的声明位置。
3. **连接级失败与参数级失败的报错完全相同**，所以第一次撞见时（本页上方 `reasoning_effort`
   那条）没法据此判断是"只有参数错误才这样"还是"一直都这样"。

✅ **实测方法与结论**（不碰生产，全部在本地跑）：用线上同一 digest 的 `litellm/litellm`
镜像 + 从**真实清单渲染**出的 config（只把两个 `api_base` 换成"死端口"和"假 Mac"）：

| 场景 | 旧形态（`litellm_params.fallbacks`） | 修法（`router_settings.fallbacks`） |
|---|---|---|
| 主上游**连接失败**（死端口） | 500 `LLM Provider NOT provided` | **200，内容来自兜底** ✅ |
| 主上游 **400**（`reasoning_effort` 不支持） | 500 `LLM Provider NOT provided` | **400，原样回真实原因** ✅ |
| 直接指名 `mac/ornith` | 200 | 200 |

☠️ **第二行的机制别记错**（这条是 2026-09-19 上线后看生产日志才订正的，本页先前写的
"400 不兜底"是错的）：LiteLLM **并不**按错误类型决定要不要兜底 —— 它照样进
`run_async_fallback` 去试 `mac/ornith`，只是那一跳**在参数映射层就抛了同一个
`UnsupportedParamsError`**（`for model=ornith-ai__Ornith-1.5-35B-A3B-MLX-4bit`），
**没有任何 HTTP 请求真的发到 Mac**，最后 `raise error_from_fallbacks` 把真实的 400 抛回来。

净效果是我们想要的（调用方看到真实原因、Mac 没被打扰），但**不能据此以为 LiteLLM 会
识别 4xx 并跳过兜底**。换一种"主上游返回 4xx 而兜底模型能接受该参数"的组合，兜底就会
真的被打出去 —— 判据永远是日志里的 `run_async_fallback` / `Error doing the fallback`，
不是返回码。

修完之后那条误导性的 500 一并消失了（现在直接回 400 + 真实原因）。

☠️ **上面说的那种组合，2026-10-04 已经出现**：新版 LiteLLM 会把 `reasoning_effort` 转发给
上游，而 Mac 接受 `minimal`、DGX 不接受。于是裸别名传 `minimal` 时兜底真的打到了 Mac，
回 200（见本页 DGX 一节）。上面那张表第二行描述的是 09-19 的版本，现在不再成立。

⚠️ **只有裸别名配了兜底，`custom_dgx/` 前缀那条刻意不配**：它是给"我就是要打 DGX"的
消费方用的，被静默换成 Mac 反而有害（实测它现在会老老实实报连接错误）。

⚠️ **换模型时 `router_settings` 里的键名要跟着换**（它是别名字面量），漏改 = 兜底静默失效 ——
和坑 A 是同一类问题的两个位置。

## ☠️ 坑 B：`/v1/models` 返回的是「这个 key 能访问什么」，不是 live config

拿虚拟 key 查 `/v1/models`，看到的是白名单过滤后的结果。改完配置用它自查，会看到旧别名，
从而得出「配置没生效」的错误结论，而真实原因是坑 A。

**验证配置有没有生效，只能用 master key**：

```bash
# live config（master key，不过白名单）
curl -s -H "Authorization: Bearer $MK" https://llm.meirong.dev/v1/models \
  | python3 -c 'import sys,json; print([m["id"] for m in json.load(sys.stdin)["data"]])'
```

两者对不上时的判据：master key 看到新别名 = 配置已生效，问题在 key；
master key 也看不到 = 配置还没进容器，往坑 C 查。

## ☠️ 坑 C：改了 ConfigMap 而 pod 不重启（已自动化，但要知道机制）

两个原因叠加，缺一不可：

1. 挂载是 `subPath`（`mountPath: /app/config.yaml` + `subPath: config.yaml`），
   subPath 挂载**不接收 ConfigMap 更新**，kubelet 不会去刷那个文件；
2. LiteLLM 只在启动时读一次 config。

2026-08-25 实际后果：ArgoCD 同步完 ConfigMap（`Synced`/`Healthy`），而网关按旧路由表
继续服务，必须手动 `kubectl rollout restart deployment/litellm -n litellm` 才生效。

**现已由 pod 模板注解 `checksum/config` 自动化**（`scripts/check-embedded-scripts.py` 的
`STAMP_ONLY`，CI 强制）：config 一变哈希就变 → pod 模板变 → ArgoCD 自然滚动重启。
机制与「加新目标」见 [manifest-safety-checks.md](manifest-safety-checks.md) 的 E1 章节。

⚠️ 所以**不要手改那个注解**，改完 config 在 `k8s/helm/` 跑 `just gen-embedded-scripts`。
注解一旦被摘掉，上面那个静默失效会原样回来。

## ☠️ 坑 D：codex 一派 subagent 就 400 —— 上游不认 `agent_message`

**症状**：`codex --profile litellm`（或 `--profile dgx` 直连）跑任何会派 subagent 的
skill（`understand` / `understand-knowledge` 这类），第一批 dispatch 就

```
Agent errored: {"error":{"message":"216 validation errors:
  {'type': 'string_type', 'loc': ('body','input','str'), …
  … 'msg': "Input should be 'shell_call'" …
```

**这段报错文本是误导的**：跟 shell 工具、跟 tool schema 都没关系。pydantic 校验
`input` 里的 item 时把整个 union 挨个试了一遍，把每个分支的失败都列了出来，所以随便
哪条错误行都不指向真因。真因只有一个：**多了一个上游不认识的 item type**。

**机制**：codex 的多 agent 协议（模型 catalog 里 `multi_agent_version: "v2"`）把 agent
之间的消息作为 `{"type": "agent_message", author, recipient, content}` item 追加进会话
历史 —— 父给子的 NEW_TASK、子回父的 FINAL_ANSWER 都走这一种（所以父子两边会同时报错）。
它是 codex 私有的 ResponseItem 变体，**不在 openai-python 的 `ResponseInputItemParam`
union 里**；而 vLLM / OMLX 的 `/v1/responses` 正是拿那套 pydantic 模型校验请求体的。
LiteLLM 只是原样透传，所以经网关和直连上游的表现完全一样（只是网关会包一层
`litellm.BadRequestError: OpenAIException`）。

**已修**：网关侧的 `async_pre_call_hook` 在转发前把这些 item 降级掉
（`k8s/helm/manifests/litellm/codex_compat.py`，2026-09-08）。拿 DGX vLLM 的
`/openapi.json` 数过：`input` 只接受 30 种 `type` 字面量，codex 会发而它不认的就 4 种 ——

| item type | 处理 |
|---|---|
| `agent_message` | 降级成 `role=user` 的 message（正文本身带 `Message Type: … / Sender: …` 信封，模型侧读法不变）|
| `context_compaction` | 有正文降级成 message，否则丢弃 |
| `encrypted_function_args` | 丢弃（OpenAI 后端专用的不透明产物）|
| `internal_chat_message_metadata_passthrough` | 丢弃（同上）|

其余 codex 变体（`reasoning` / `function_call` / `tool_search_call` / `compaction` /
`compaction_trigger` …）都在 union 里，不用动。白名单式改写：只碰这 4 种。

```bash
# hook 是否在干活。每个 pod 生命周期里**只有一条**：首次改写打 WARNING
# （`本层已生效（首次改写…）`），后续降到 INFO。
kubectl --context k3s-homelab logs -n litellm deploy/litellm | grep codex_compat
```

☠️ 为什么首次要打到 WARNING：本部署没设 `LITELLM_LOG`，`verbose_proxy_logger` 的
**生效级别是 WARNING**（实测 `getEffectiveLevel()`），全用 INFO 的话上面那条 grep 永远
空转 —— 于是「这层没在干活」和「今天没有多 agent 流量」两种情况看起来一模一样。要看全部
改写记录（每请求一条）就给 Deployment 加 `LITELLM_LOG=INFO`。

☠️ **但修掉 400 并不等于 v2 能用**：本 hook 解决的只是「请求体被上游拒收」这一类失败。
codex 的 v2 通路在自托管上游上还有**另一个、与网关无关的**毛病 —— 派任务时那条
NEW_TASK 的 `agent_message` **payload 是空的**：

```
Message Type: NEW_TASK
Task name: /root/alpha
Sender: /root
Payload:            ← 就到这里，父 agent 传的 message 没了
```

判据是它出现在**子 agent 自己的本地 rollout 里**（`~/.codex/sessions/…jsonl`），
而 rollout 是 codex 发 HTTP 之前从自身状态写的 —— 所以不可能是网关或本 hook 造成的。
父 agent 的 `spawn_agent` 参数里 message 明明在（实测 85 字符）。三种组合都复现：
你自己的 dgx catalog、新建的 litellm catalog、传不传 `fork_turns` 都一样。合理推断是
v2 的任务投递依赖 OpenAI 后端那边的线程状态，自建 vLLM 没有那个能力。
（`use_responses_lite: true` 不是出路：实测 vLLM 服务不了那套 wire format，连接直接重试
5 次失败。）

**所以客户端侧的结论是反的：别给自托管的模型写 catalog 条目。**
没有条目时 codex 用 fallback metadata，协作走**客户端侧**投递 —— 任务作为普通
`role=user` message 进子 agent，`wait_agent` 的 `function_call_output` 带回答案，
压根不产生 `agent_message`。实测这条路是唯一真能干活的：

| catalog 条目 | collab 工具 | 任务能否到子 agent |
|---|---|---|
| 没有条目（fallback metadata）| 有 | ✅ 走普通 message，实测 ALPHA/BETA/GAMMA 全回来 |
| `multi_agent_version: "v2"` | 有 | ❌ NEW_TASK payload 为空（本 hook 只挡住了 400）|
| `"v1"` 或不写这个键 | **没有**（模型只能去摸 `exec_command`）| — 派不了 |

代价照单接受：codex 启动会警告 `Model metadata … not found`，且 `model_context_window`
不驱动自动压缩阈值（只有 catalog 的 `context_window` 才行），长会话有跑到中途被服务端
拒收的风险。**在 v2 的空 payload 修好之前，这个代价换的是「subagent 真能干活」。**

那本 hook 还留着干什么：① 它把这类失败从「整轮报错」降级成「正常跑」，codex 以后改默认、
或谁手动开了 v2，都不会再撞 400；② `encrypted_function_args` 等另三种类型同样会撞，
不限于多 agent 场景。

## 怎么查「哪些模型能免费用」

下次要挑模型解决问题，从这里开始查，别凭印象。

NVIDIA build.nvidia.com 曾是第四来源（`nvidia/*`），**2026-10-04 删除**：路由写成
`openai/nvidia/*` 会给上游模型名多带一层前缀，自 2026-08-25 起全部 404，没有消费方，
还给 `/v1/models` 灌进 200+ 个不存在的条目。当时的排查、修法与模型筛选（本机仓库根目录）：
`git show 9271654:docs/reference/litellm-gateway.md`。

### OpenRouter：按模型分免费/付费，公开 API 免鉴权可查

| 入口 | 用途 |
|---|---|
| `https://openrouter.ai/models` | UI，可按价格筛选 |
| `GET https://openrouter.ai/api/v1/models` | 免鉴权，419 个模型的全量元数据（含 pricing / context_length / knowledge_cutoff）|
| [openrouter.ai/docs/api_reference/limits](https://openrouter.ai/docs/api_reference/limits) | 官方限额（注意路径是下划线 `api_reference`，连字符版本 404）|

判据是 pricing 两个字段都为 0，本机任意目录：

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

（2026-08-25 实测输出 `免费模型: 21 / 419`。**别在 f-string 里嵌双引号**，那样在单引号
shell 里会 SyntaxError，第一版就这么写错过。）

⚠️ **别用 `:free` 后缀当判据**。官方文档只提后缀，但实测（2026-08-25）21 个零价模型里
有 4 个没有后缀（`stealth/ox-alpha`、`google/lyria-3-{clip,pro}-preview`、`openrouter/free`）。
接口的 pricing 字段才是权威。

**免费档限额**（官方 docs 原文）：20 请求/分；终身购买信用 < $10 → 50 请求/天，
≥ $10 → 1000 请求/天（买过一次就永久提档）。负余额会让免费模型也报 402。

⚠️ **免费档不能当兜底**：503 / 超时 / 429 都实际撞到过（`poolside/laguna-xs-2.1:free`
经 OpenRouter 直接 429）。它只配当「碰运气的额外一档」，不能进 `fallbacks` 链当依赖。

### ☠️ 同一个模型换 provider，思维链是否分离会变

这是挑模型时最容易踩的一条：**`reasoning_content` 能不能正确分离，取决于 provider 的
托管实现，不是模型本身**。同一个 `nemotron-3.5-lightning`，同一个提示词（2026-08-25；
NVIDIA 路由已删，结论对挑任何 provider 都成立）：

| 路径 | finish | content | reasoning_content |
|---|---|---|---|
| NVIDIA 直连 | `stop` | 84 字符，干净代码 | 1331 字符 ✅ |
| 经 OpenRouter（`openrouter/nvidia/nemotron-3.5-lightning:free`）| `length` | 思维链原文在这里 | 无 ❌ |

**所以「这个模型能用吗」必须按 `(provider, model)` 组合验证，不能只按模型名。**
判断办法就是发一次真实请求看 `message` 的 key 和 `content` 首行，与 Mac OMLX 那个坑同源
（见下一节），只是这次变量是 provider 而不是 `max_tokens`。

## 上游是思维链模型：小 `max_tokens` 会把思维链漏进 `content`

`reasoning_content` 的切分依赖 `</think>` 闭合标签；token 用完标签不出现，parser 就失去切分
依据、把整段思考原样放进 `content`（不报错、不告警，只是答案变成一坨思考过程）。

- 受影响的是所有自托管上游（DGX 的 `qwen3.8-flash-next-tp2`、Mac 的 Ornith、Studio 的
  Qwen3.8-27B 都是思维链模型），
  不是某个模型的缺陷；
- DGX 侧的开关与 Mac 不同：单请求发 `chat_template_kwargs: {"enable_thinking": false}`
  **真关掉思考**（2026-10-04 实测：`reasoning_tokens=0`、`content` 干净）。`reasoning_effort`
  的档位见本页 DGX 一节。⚠️ 档位集合每换一次栈都变过（09-03 那栈还认 `none`，V4-Flash
  只有 `max` 真生效），**别跨栈照抄档位**；
- ☠️ **关思考的 kwargs 名换了，写错是静默空操作**：新栈认 `enable_thinking`，旧栈那套
  `thinking` 打上去**不报错也不生效**。2026-09-03 用 jobs-sg 线上那份提示词实测三种写法
  **都回 200**，差别只在 `usage.completion_tokens_details.reasoning_tokens`：基线 142、
  `{"thinking": false}` 134（等于没关）、`{"enable_thinking": false}` 0（各 n=1，同一条
  短岗位描述；三档的 JSON 内容一致）。
  **判据只能看 reasoning_tokens，不能看请求成没成。**踩中这条的是 jobs-sg 的
  `DisableThinking`（见 [jobs-sg.md](jobs-sg.md)），它默认不发所以线上没坏；
- 逃生口是别名 `mac/ornith-fast`，走 OMLX 的 `fast` profile（`enable_thinking: false`），
  与 `mac/ornith` 共用同一份驻留权重、不触发换入换出；
- 实测数据、为什么换 Ornith、以及「换模型不能消除该失效模式」的反例，见
  [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md) 的「2026-08-25 修订」。

⚠️ **只暴露一个 Mac 35B**：OMLX 池天花板 30GB 装不下两个（19.95 + 19.08GB）。两个别名并存
= 交替调用持续换入换出（~18s/次，期间回 `is busy`）。

## Mac Studio 上游：`studio/qwen3.8-27b`（2026-10-03）

| | |
|---|---|
| 别名 → 上游 | `studio/qwen3.8-27b` → `openai/Qwen3.8-27B-MLX-4bit` @ `100.98.220.75:8000/v1` |
| 机器 | Mac Studio M5 Max / 128G，OMLX 0.7.0；池天花板 ~106G，**常驻、不换入换出**（M2 那条「只暴露一个 35B」的约束不适用）|
| 模型 | HF `lmstudio-community/Qwen3.8-27B-MLX-4bit`（VLM，262k ctx）。OMLX 0.7 的模型 ID **不带 org**，别照 M2 写成 `org__name` |
| 兜底 | **不在任何兜底链里**，只能指名调用。它是多出来的一个可选模型，不是 DGX 的替身 |
| key 白名单 | `LITELLM_VK`（2c15baf776…）、xiaogpt 的专用 key（`key_alias=xiaogpt`，只有这一个模型）、外部使用者的 `ext-team-1`（账户与 key 两层白名单都有）。其余 key 都是给特定消费方的窄 key，**刻意没加**；谁要用就按坑 A 单独加 |
| 实测（直连，2026-10-03）| 冷装载 14.4s；开了 DFlash2 投机解码后，写代码 ~100 tok/s、中文长文 ~43 tok/s（基线 31.9，配置与数据见 `macbook/ansible/README.md`）；思维链分离到 `reasoning_content`（同样受下面「小 `max_tokens` 漏进 `content`」影响）|

主机侧（OMLX 安装、key、模型下载）→ `macbook/ansible/README.md`；指标 → [omlx-inference-metrics.md](omlx-inference-metrics.md)。

## Mac Studio 文生图：已退役（2026-10-03）

同日上线、同日撤下，`studio/qwen-image-2.1` 已从网关、虚拟 key 白名单与 Studio 上全部移除，
**网关里现在没有任何文生图模型**。撤下的原因（生成期间把同机对话模型从 111 压到 18–26 tok/s、
进程内存按出现过的分辨率单调泄漏）与当时的实现 → [decisions/studio-image-generation.md](../decisions/studio-image-generation.md)。

对外使用者看的说明（公开、不含密钥）→ [guides/llm-gateway-external-users.md](../guides/llm-gateway-external-users.md)。

☠️ **`mac/*` 的 `api_key: dummy` 能用，是 Mac 上一个开关的结果**（2026-09-30 起）：OMLX 0.7 起
非回环监听必须配 key，现行配法是 key + `allow_unauthenticated_inference: true`，推理端点因此仍免鉴权。
那个开关一丢，`mac/*`（以及 `studio/*`）全部 401，而网关这边清单正确、ArgoCD Synced。
→ [omlx-inference-metrics.md 的「鉴权」](omlx-inference-metrics.md#鉴权omlx-07-起)

## 每把 key 的用量与来源 IP（spend log）

每次调用（含失败）在 `apps-pg` 的 `litellm` 库写一行 `LiteLLM_SpendLogs`。对外发了 key、
想知道它什么时候、从哪、用了多少，查的就是这张表：

| 列 | 内容 |
|---|---|
| `api_key` | key 的 sha256，不是原文 |
| `metadata->>'user_api_key_alias'` | 发 key 时给的 `key_alias`，**没给就是空**，见下方「发 key」 |
| `"startTime"` / `model_group` / `call_type` / `status` | 时间、别名、路由、`success`/`failure` |
| `prompt_tokens` / `completion_tokens` / `total_tokens` | 用量。☠️ **别看 `spend`**：自托管模型没有单价，全表 spend 都是 0 |
| `metadata->>'user_agent'` | 客户端 UA |
| `requester_ip_address` | 来源 IP，见下 |

不存对话内容：没开 `store_prompts_in_spend_logs`，`messages` / `response` 全表 0 行非空、
`proxy_server_request` 是 `{}`（2026-10-03 核过）。别为排障顺手打开，那会把外部使用者的
prompt 落进库。表没有设 `maximum_spend_logs_retention_period`，行会一直留着（2026-10-03 时
2.3 MB），量级上不用管。

### `requester_ip_address` 记的是谁（2026-10-03 起）

| 进来的路径 | 记下的地址 |
|---|---|
| 公网 `llm.meirong.dev`（Cloudflare）| Cloudflare 的 `CF-Connecting-IP`，即真实客户端 IP；IPv6 客户端就是 IPv6 |
| tailnet NodePort `:31400` | 调用方的 `100.x` 地址 |
| 集群内走 Service | 调用方 pod IP |

第一行靠 `client_ip.py` hook 改写（为什么不用 `general_settings.use_x_forwarded_for`、信任边界
都在它的文件头）。LiteLLM 默认记 TCP 对端，公网调用到它这里对端已经是 `10.42.0.152`
（k8s-node 的 CiliumInternalIP）。

☠️ **2026-10-03 之前的行，公网调用一律是 `10.42.0.152`**，历史数据补不回来。

⚠️ 公网路径上这个字段伪造不了：客户端自己带 `CF-Connecting-IP`，Cloudflare 直接回 403
`error code: 1000`；伪造 `X-Forwarded-For` / `True-Client-IP` 能通过，但记下的仍是真实地址
（均经公网实测）。

⚠️ **被限流拒掉的 `/v1/responses` 请求，那行 IP 是空串**。这是 LiteLLM 本身的行为，不加 hook
也一样（本地同 digest 镜像实测）；chat 被限流的行有 IP。

hook 有没有加载：每个 pod 只在首次改写时打一条 WARNING。

```bash
kubectl --context k3s-homelab -n litellm logs deploy/litellm | grep client_ip
```

### 按 key × IP 看用量

本机任意目录。没有别名的 key 显示哈希前 12 位，对照方法见坑 A 的「改名时先找出全部受影响的 key」：

```bash
kubectl --context k3s-homelab -n databases exec deploy/apps-pg -- psql -U postgres -d litellm -c "
select coalesce(nullif(metadata->>'user_api_key_alias', ''), left(api_key, 12)) as key,
       requester_ip_address as ip,
       count(*) as calls, count(*) filter (where status = 'failure') as failed,
       sum(total_tokens) as tokens, max(\"startTime\")::timestamp(0) as last_seen
from \"LiteLLM_SpendLogs\" where \"startTime\" > now() - interval '7 days'
group by 1, 2 order by calls desc;"
```

### 发给外部的 key

2026-10-03 盘点：18 把 key 里 **17 把没有 `key_alias`**、**0 把设了 rpm/tpm/并发上限**。
对外发 key 时这样建（master key 取法见坑 A）：

```bash
curl -s -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"key_alias":"ext-<谁>","models":["studio/qwen3.8-27b"],"duration":"30d",
       "rpm_limit":60,"max_parallel_requests":2}' \
  http://100.94.186.7:31400/key/generate
```

| 参数 | 为什么 |
|---|---|
| `key_alias` | 上面的聚合查询按它分组；必须唯一，重名直接拒绝 |
| `duration` | 到期自动失效（`30d` → `expires` 为 30 天后），调用方拿到 401 `expired_key` |
| `rpm_limit` / `max_parallel_requests` | 超了回 429 `throttling_error`。**别用 `max_budget` 限额**：本地实测 max_budget=0.001 连发 6 次全是 200，spend 一直是 0 |

以上参数都在本地用同 digest 镜像实测过（`max_parallel_requests=1` 时 4 个并发 1 个 200、3 个 429）。
走 tailnet NodePort 是因为经 Cloudflare 调管理接口会被 WAF 拦（坑 A 那节）。

## 消费方

| 消费方 | 用哪个别名 | 配置在哪 |
|---|---|---|
| `codex --profile mac` | `mac/ornith` | `~/.codex/mac.config.toml`（本机）|
| 本机任意 OpenAI 兼容客户端 | `studio/qwen3.8-27b` | 读 `LITELLM_VK`；目前没有固定消费方 |
| k8sgpt（默认，`--backend localai`）| `mac/ornith-fast` | `~/Library/Application Support/k8sgpt/k8sgpt.yaml`（本机）|
| k8sgpt（`--backend openai`）| `qwen3.8-flash-next-tp2` | 同上。☠️ explain 输出为空：k8sgpt 0.4.39 实际按 2048 截断（无视配置里的 `maxtokens: 4096`），DGX 默认开思考，2048 全用在思考上。网关记 `success`、`completion_tokens=2048`。所以 2026-10-04 起默认后端改成 localai |
| oracle 上的 calibre 元数据作业 | `qwen3.8-flash-next-tp2`（经 `litellm-external` NodePort）| [清单内嵌脚本](../../cloud/oracle/manifests/calibre-metadata/metadata-llm.yaml) |
| xiaogpt（小爱音箱，homelab `personal-services`）| `studio/qwen3.8-27b`，专用 key `key_alias=xiaogpt`（2026-10-03 前借用 calibre 那把）| [xiaogpt.yaml](../../k8s/helm/manifests/personal-services/xiaogpt.yaml) 的 ConfigMap |
| Open Notebook | **不走网关**，直连 DGX 与 OMLX | [open-notebook.md](open-notebook.md) |
| `codex --profile dgx` / `m2` | **不走网关**，直连 DGX / M2 的 OMLX | `~/.codex/{dgx,m2}.config.toml`（本机）。原来经网关的 `--profile litellm` 已不存在 |
| 外部使用者（UI 账户 `ext-team-1`）| 5 个自托管别名 + 17 个 OpenRouter `:free` 模型 | Postgres（账户与 key 各一层白名单），见上方「发给外部的 key」 |

⚠️ 本机消费方全部读同一个 `LITELLM_VK`（`~/.zshrc`），所以坑 A 一旦发生是全体受影响。
