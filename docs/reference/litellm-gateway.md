# LiteLLM 网关（运维事实与坑）

> Last updated: 2026-09-03
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

## DGX 主力模型：2026-09-02 换成 Qwen3.8-Flash-Next

上游（`~/projects/meirongdev/nv-dgx-spark`）单方面换栈，本仓库只是跟着改引用。**这一节是本
仓库关于该上游的唯一真相源**；换栈的技术理由与压测数据在 nv-dgx-spark 仓库，不在这里复制。

| | |
|---|---|
| served name | `qwen38-flash-next`（root `Qwen3.8-Flash-Next-NVFP4`，NVFP4 权重 126 GiB）|
| 端点 | **不变**：`100.97.87.120:8000/v1`。旧名 `deepseek-v4-flash` 已从 `/v1/models` 消失，所以旧引用是 **404**（不是 401，也不是"配置没生效"）|
| `max_model_len` | **262144**（旧栈 1000000）。按 1M 做过长上下文规划的下游全要重算 —— 已知受害者 [open-notebook.md](open-notebook.md) 的 `large_context_model` 与播客 profiles |
| 拓扑 / 冷启动 | 双节点 TP=2，两台都必须在；加载 **8–11 分钟**（旧栈 5m29s）。`DgxSparkVllmDown` 的 `for` 因此从 10m 抬到 15m，否则一次正常重启就烧 critical |
| 并发 | `--max-num-seqs 8`，但线上 `cache_config` 实测 `kv_cache_max_concurrency=5.34`（gmu 0.75）—— 真瓶颈是 KV 池，不是条数，所以排队告警阈值**没有**按 8 等比抬 |
| 工具调用 | ✅ 实测 `finish_reason=tool_calls`、arguments 是合法 JSON（calibre/jobs-sg 那批 JSON 消费方的前提）|
| 回滚 | `make qwen38fn-rollback` → `make v4flash-run`（旧权重/镜像保留）。☠️ 回滚要把网关别名 + jobs-sg + open-notebook + oracle calibre 四处一起回退，**外加坑 A 的 key 白名单** |

⚠️ **质量闸门还没跑**（nv-dgx-spark 侧的 aider-polyglot）：RadixArk 的 NVFP4 是无校准 RTN
量化，公开分数由量化方自报。速度闸门已过（decode 均值 58.6 tok/s，比旧栈 −12.8%，但并发
c4/c6 +25%/+29%、prefill +82%/+100%，真实代码任务 62.1 vs 63.8 基本打平）。也就是说
**「换模型」目前只有速度与工具调用被验证过，输出质量没有**。

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
  -d '{"key":"'"$VK"'","models":["custom_dgx/qwen38-flash-next","qwen38-flash-next",
       "mac/ornith","mac/ornith-fast","openrouter/*","nvidia/*"]}' \
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

⚠️ **爆炸半径实测（2026-09-03）**：16 把 key 里 **8 把**的白名单写着 DGX 别名，另有 4 把
还挂着早已不存在的 `mac/qwen3.6-35b`。一次改名的正确预期是"改 8 把"，不是"改 1 把"。
`/key/update` 是**整表替换**，所以脚本要先把原列表读出来、只映射要改的那两项、其余原样带回。

⚠️ **未验证但要当真的推论**：`fallbacks` 的目标也是别名。如果兜底别名不在 key 的白名单里，
DGX 不可达时该 key 大概率拿不到兜底（拿到的是 `key_model_access_denied` 而不是 Mac 的回答）。
本仓库当前两个别名都已在白名单里，所以没有实测过。真要确认：临时建一个只含
`qwen38-flash-next` 的 key，制造 DGX 不可达再调它。**在验证之前，别把「有 fallbacks 就有兜底」
当成结论**：兜底链是否真的通，取决于 key 而不只是 config。

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

## ☠️ 上游 `nvidia/*` 打不通：是 `model` 字段的双前缀，不是 key 的问题

清单里写的是 `model_name: "nvidia/*"` → `model: "openai/nvidia/*"`。LiteLLM 用别名里被
`*` 捕获的部分去替换 `model` 里的 `*`，于是发给上游的模型名带上了多余的 `nvidia/`。

2026-08-25 在 litellm pod 里直连 `integrate.api.nvidia.com` 实测（用的就是网关自己那把
`NVIDIA_API_KEY`）：

| 发出去的 model | 结果 |
|---|---|
| `meta/llama-3.3-70b-instruct`（裸名）| 200 OK |
| `nvidia/meta/llama-3.3-70b-instruct`（网关实际发的形状）| 404 `page not found`，与经网关调用时报的错逐字相同 |

**所以 key 是好的、上游是通的，坏的是 `model` 字段的写法。**

⚠️ **一个曾经的误判，写下来免得重复**：一度以为「NVIDIA 一把 key 只授权一个模型、要用别的
免费模型得另外生成 key」。实测不成立：拿这把 key 查 `GET /v1/models` 返回 102 个模型
（`deepseek-ai/deepseek-v4-flash-0731`、`meta/llama-3.3-70b-instruct`、`google/gemma-4-31b-it`、
`minimaxai/minimax-m3`、`mistralai/mistral-large` 等），且裸名调用成功。判据很简单：
**授权问题回 401/403，`404 page not found` 是路由/模型名对不上**，别把这两类混起来。

**怎么修（未部署验证）**：把 `model` 改成 `"openai/*"`，让捕获到的通配内容单独成为模型名：

```yaml
      - model_name: "nvidia/*"
        litellm_params:
          model: "openai/*"                       # 不是 openai/nvidia/* —— 后者会多带一层前缀
          api_base: https://integrate.api.nvidia.com/v1
          api_key: os.environ/NVIDIA_API_KEY
```

改完必须实调一次确认（`nvidia/meta/llama-3.3-70b-instruct` 应回 200），**别只看
`/v1/models` 里有没有它**，见下条。

⚠️ 它还污染 `/v1/models`：master key 查询会看到 200+ 个 `nvidia/` 前缀条目，内容却是
OpenAI 的模型名（`nvidia/gpt-4o`、`nvidia/dall-e-3`、`nvidia/sora-2`、`nvidia/o3` …），
NVIDIA 上并不存在。这是 LiteLLM 按 openai provider 的静态模型表展开通配的结果，与 key 能
访问什么无关。**别拿 `/v1/models` 里出现某个 `nvidia/X` 当作它可用的证据。**

这把 key 实际能用的模型清单（102 个，随 NVIDIA 目录变）现取：

```bash
POD=$(kubectl --context k3s-homelab -n litellm get pod -l app=litellm -o jsonpath='{.items[0].metadata.name}')
kubectl --context k3s-homelab -n litellm exec "$POD" -- python3 -c "
import os,json,urllib.request
r=urllib.request.Request('https://integrate.api.nvidia.com/v1/models',
    headers={'Authorization':'Bearer '+os.environ['NVIDIA_API_KEY']})
print('\n'.join(m['id'] for m in json.load(urllib.request.urlopen(r,timeout=30))['data']))"
```

## 怎么查「哪些模型能免费用」（两个 provider 口径完全不同）

下次要挑模型解决问题，从这里开始查，别凭印象。

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

### NVIDIA build.nvidia.com：不按模型分，是信用点制

**「哪些模型免费」对 NVIDIA 是个错问题**：所有 NIM 托管模型共用同一份免费额度，
注册赠 1000 点（约 1 点 = 1 次调用），可申请加到 5000；40 RPM（可申请 200）。
用完的是点数，不是某个模型的权限。

所以对 NVIDIA 要问的是「这把 key 能调哪些」，命令见上一节（查 `/v1/models` 的那条）。
单个模型的发布日期/能力/许可看 `https://build.nvidia.com/<model-id>/modelcard`。

⚠️ **列表里有不等于能调**，实测（2026-08-25）：`moonshotai/kimi-k2.6` 在那 102 个里但调用回
404；`nvidia/nemotron-3-ultra-550b-a55b` 回 503 `service temporarily overloaded`。

### ☠️ 同一个模型换 provider，思维链是否分离会变

这是挑模型时最容易踩的一条：**`reasoning_content` 能不能正确分离，取决于 provider 的
托管实现，不是模型本身**。同一个 `nemotron-3.5-lightning`，同一个提示词：

| 路径 | finish | content | reasoning_content |
|---|---|---|---|
| NVIDIA 直连 | `stop` | 84 字符，干净代码 | 1331 字符 ✅ |
| 经 OpenRouter（`openrouter/nvidia/nemotron-3.5-lightning:free`）| `length` | 思维链原文在这里 | 无 ❌ |

**所以「这个模型能用吗」必须按 `(provider, model)` 组合验证，不能只按模型名。**
判断办法就是发一次真实请求看 `message` 的 key 和 `content` 首行，与 Mac OMLX 那个坑同源
（见下一节），只是这次变量是 provider 而不是 `max_tokens`。

### 可用性实测（2026-08-25，绕过网关直连 NVIDIA）

同一编码任务，`max_tokens=700`：

| 模型 | 状态 | 延迟 | 出 tok | reasoning 分离 |
|---|---|---|---|---|
| `poolside/laguna-xs-2.1` | stop | 0.7–1.0s | 34 | 无思维链 |
| `nvidia/nemotron-3-super-120b-a12b` | stop | 2.5s | 90 | ✅ |
| `minimaxai/minimax-m3` | stop | 4.4s | 50 | 无思维链 |
| `nvidia/nemotron-3.5-lightning-30b-a3b` | stop | 9.0–15.8s | 424–456 | ✅ |
| `moonshotai/kimi-k3` | stop | 19.3s | 46 | ✅ |
| `stepfun-ai/step-3.7-flash` | stop | 44.6s | 342 | ✅ |
| `deepseek-ai/deepseek-v4-flash-0731` | stop / 超时 | 221.5s / >70s | 33 | 无思维链 |
| `nvidia/nemotron-3-ultra-550b-a55b` | 503 | — | — | — |
| `openai/gpt-oss-120b` | 超时 | >240s | — | — |

能用的那些输出全部正确、`content` 全部干净（NVIDIA 托管端的 parser 是对的）。

⚠️ **修正一条先前的推荐**：本文档曾把 `deepseek-v4-flash-0731` 标为「与 DGX 主力同款，
适合做同模型兜底」。**推理成立但实测否掉了它**（而且 2026-09-02 起 DGX 主力是
Qwen3.8-Flash-Next，连"同款"这个前提本身也不成立了）：221.5s 才吐 33 个 token，比本地 DGX（~4s）
慢两个数量级，当兜底只会让请求挂死。按数据要在 NVIDIA 里选一个，是
`poolside/laguna-xs-2.1`（0.7s、零思维链、专做 agentic coding，比本地 DGX 还快），
`nemotron-3.5-lightning-30b-a3b` 作为要多模态/更强推理时的第二选择。

⚠️ **免费档不能当兜底**：503 / 超时 / 429 都实际撞到过（`poolside/laguna-xs-2.1:free`
经 OpenRouter 直接 429）。它只配当「碰运气的额外一档」，不能进 `fallbacks` 链当依赖。

## NVIDIA provider 可用模型（只列近 3 个月发布的）

**口径**：只考虑发布日期在最近 3 个月内的模型，更早的一律不用（模型迭代太快，
旧版在编码/agent/工具调用上差一代就明显吃亏）。本表窗口 = 2026-05-25 ~ 2026-08-25。

☠️ **日期不能从 API 拿**：NVIDIA 的 `GET /v1/models` 里 `created` 字段是常量假值
（102 个模型全是 `735790403` = 1993-04-26）。所以下表日期全部来自**厂商公告/模型卡**，
刷新本表时必须重查，不能指望接口。每个模型的权威来源是
`https://build.nvidia.com/<model-id>/modelcard`。

### 窗口内 · 适合开发用途

| 模型 | 发布 | 是什么 |
|---|---|---|
| `nvidia/nemotron-3.5-lightning-30b-a3b` | 2026-08-11 | 30B MoE / 3B 激活，为 agent 执行做的「快」档，单 H100 可跑 |
| `meta/muse-glimmer-30b` | 2026-08-10 | Meta 自 Llama 4 后首个开放权重模型；30B dense 多模态、agent 调优、Apache 2.0 |
| `deepseek-ai/deepseek-v4-flash-0731` | 2026-07-31 | 曾是 DGX 主力同款（2026-09-02 起不再是），且免费档实测 221.5s / 超时，不可用（见上方实测表）|
| `moonshotai/kimi-k3` | 2026-07-16（权重 07-27）| 2.8T MoE、1M ctx、原生视觉；agentic coding 强 |
| `poolside/laguna-xs-2.1` | 2026-07-02 | 33B MoE / 3B 激活，专做 agentic coding |
| `minimaxai/minimax-m3` | 2026-05-31 | 1M ctx + 原生多模态 + 前沿编码，开放权重 |
| `stepfun-ai/step-3.7-flash` | 2026-05-29 | 198B MoE VLM（~11B 激活），面向编码 agent 与检索流程 |
| `nvidia/nemotron-3-ultra-550b-a55b` | 2026-06-04 | 550B/55B 激活推理模型；最强但也最慢，按需用 |

### 窗口内 · 但与开发无关（列出以免重复筛查）

| 模型 | 发布 | 为什么不用 |
|---|---|---|
| `nvidia/ising-calibration-1.5-31b` | 2026-07-20 | 量子标定图像解读专用 VLM |
| `thinkingmachines/inkling` | 2026-07-15 | base 模型（给你微调用的），不是 instruct，直接当助手用会很怪 |
| `google/diffusiongemma-26b-a4b-it` | 2026-06-10 | 文本扩散，实验性；快但不是通用助手 |
| `nvidia/nemotron-3.5-content-safety` | 2026-06-04 | 4B 护栏/审核模型 |

### 刚好落在窗口外（别再考虑）

`moonshotai/kimi-k2.6`（2026-04-20）· `google/gemma-4-31b-it`（2026-04-02）·
`nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`（2026-04-28）·
`nvidia/nemotron-3-super-120b-a12b`（2026-03-11）·
`nvidia/nemotron-3-nano-30b-a3b` 与 `nvidia/nemotron-nano-3-30b-a3b`（2025-12）·
`nvidia/cosmos-reason2-8b`（2025-12-19）· `openai/gpt-oss-120b` / `gpt-oss-20b`（2025-08）。

⚠️ **那 8 个名字带 code 的是陷阱**：`starcoder2-15b`、`codegemma-*`、
`deepseek-coder-6.7b-instruct`、`granite-*-code`、`codellama-70b`、`codestral-22b` 是
补全式老模型，不跟随指令、不会用工具，拿来当开发助手很难用。别被名字骗了。

其余约 70 个（`llama-3.1/3.2`、`gemma-2b/3`、`mistral-7b-v0.3`、`phi-3`、`granite-3.0`、
`yi-large`、`llama2-70b`、`mixtral-8x22b`、`nemotron-4-340b`、各类 embedding /
reranker / nemoguard / 视觉 / riva-translate / palmyra 垂类）全部早于窗口或非对话用途。

未逐一核实日期的（都不是对话模型，用不到就没查）：`mistralai/mistral-nemotron`、
`nvidia/llama-3.3-nemotron-super-49b-v1.5`、`nvidia/nemotron-3-embed-1b`、
`nvidia/llama-nemotron-embed-1b-v2`、`nvidia/llama-nemotron-embed-vl-1b-v2`、
`nvidia/nemotron-parse`、`nvidia/nemotron-nano-12b-v2-vl`、
`nvidia/ai-synthetic-video-detector`、`nvidia/riva-translate-4b-instruct-v2`、
`nvidia/llama-3.1-nemotron-safety-guard-8b-v3`、`writer/palmyra-creative-122b`。
**要用它们之前先查日期**，别假设在窗口内。

⚠️ 上表只说明「发布在窗口内」，不代表可用，可用性看上方实测表。

## 上游是思维链模型：小 `max_tokens` 会把思维链漏进 `content`

`reasoning_content` 的切分依赖 `</think>` 闭合标签；token 用完标签不出现，parser 就失去切分
依据、把整段思考原样放进 `content`（不报错、不告警，只是答案变成一坨思考过程）。

- 受影响的是所有自托管上游（DGX 的 `qwen38-flash-next`、Mac 的 Ornith 都是思维链模型），
  不是某个模型的缺陷；
- DGX 侧的开关与 Mac 不同：`--reasoning-parser qwen3` 已开，单请求可发
  `chat_template_kwargs: {"enable_thinking": false}` **真关掉思考**（实测 2026-09-03：
  `reasoning_tokens=0`、`content` 干净）。`reasoning_effort` 只接受
  `none`/`low`/`medium`/`xhigh`，**`high` 会被 400 拒**（报错文本还漏了 `none`，别照抄）。
  ⚠️ 这套枚举与旧栈 V4-Flash 完全不同（那边只有 `max` 真生效），**别跨栈照抄档位**；
- 逃生口是别名 `mac/ornith-fast`，走 OMLX 的 `fast` profile（`enable_thinking: false`），
  与 `mac/ornith` 共用同一份驻留权重、不触发换入换出；
- 实测数据、为什么换 Ornith、以及「换模型不能消除该失效模式」的反例，见
  [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md) 的「2026-08-25 修订」。

⚠️ **只暴露一个 Mac 35B**：OMLX 池天花板 30GB 装不下两个（19.95 + 19.08GB）。两个别名并存
= 交替调用持续换入换出（~18s/次，期间回 `is busy`）。

## 消费方

| 消费方 | 用哪个别名 | 配置在哪 |
|---|---|---|
| `codex --profile litellm` | `custom_dgx/qwen38-flash-next` | `~/.codex/litellm.config.toml`（本机）|
| `codex --profile mac` | `mac/ornith` | `~/.codex/mac.config.toml`（本机）|
| k8sgpt（`--backend openai`）| `qwen38-flash-next` | `~/Library/Application Support/k8sgpt/k8sgpt.yaml`（本机）|
| k8sgpt（`--backend localai`）| `mac/ornith-fast` | 同上 |
| oracle 上的 calibre 元数据作业 | `qwen38-flash-next`（经 `litellm-external` NodePort）| [清单内嵌脚本](../../cloud/oracle/manifests/calibre-metadata/metadata-llm.yaml) |
| Open Notebook | **不走网关**，直连 DGX 与 OMLX | [open-notebook.md](open-notebook.md) |

⚠️ 本机消费方全部读同一个 `LITELLM_VK`（`~/.zshrc`），所以坑 A 一旦发生是全体受影响。
