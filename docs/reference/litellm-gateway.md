# LiteLLM 网关（运维事实与坑）

> Last updated: 2026-08-25
> Status: 生效事实
> Scope: `llm.meirong.dev` 这个 LLM 网关的**配置生效路径、鉴权分层、上游可用性边界** ——
> source of truth。为什么选 LiteLLM、上游怎么选、Mac 兜底为何换 Ornith，见
> [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md)（决策与实测数据）。

## 速览

| | |
|---|---|
| 集群 / ns | homelab / `litellm`（**钉控制面** —— 只有它的 netmap 里有 DGX 与 Mac）|
| 公网入口 | `llm.meirong.dev`（Cloudflare Tunnel → Cilium Gateway → HTTPRoute）|
| 推理鉴权 | master key + 虚拟 key（`Authorization: Bearer sk-…`）|
| 管理面 | `/ui`，LiteLLM 自带登录（`UI_USERNAME`/`UI_PASSWORD`，Vault→ESO）|
| 路由表 | `k8s/helm/manifests/litellm/litellm.yaml` 的 ConfigMap（**在 git 里**）|
| key / spend | 同集群 Postgres `litellm-pg`（**不在 git 里** —— 见坑 A）|

**配置真相源分成两半，这是本文档存在的理由**：

| 东西 | 存在哪 | 改法 |
|---|---|---|
| 模型列表 / `api_base` / `fallbacks` | git 的 ConfigMap | 改清单 → push → ArgoCD |
| **虚拟 key 能访问哪些模型** | **Postgres** | 只能调 API（坑 A）|
| 花费账本 / key 有效期 | Postgres | `/ui` 或 API |

## ☠️ 坑 A —— 虚拟 key 的模型白名单在 Postgres 里，git 完全管不到

**每个虚拟 key 带一份 `models` 白名单**，值是**模型别名的字面量**。所以在 git 里给网关改
别名（重命名、删除、新增），key 那边不会跟着变 —— 于是「清单正确 + 部署成功 + 调用全挂」。

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
  -d '{"key":"'"$VK"'","models":["custom_dgx/deepseek-v4-flash","deepseek-v4-flash",
       "mac/ornith","mac/ornith-fast","openrouter/*","nvidia/*"]}' \
  https://llm.meirong.dev/key/update
```

⚠️ **未验证但要当真的推论**：`fallbacks` 的目标**也是别名**。如果兜底别名不在 key 的白名单里，
DGX 不可达时该 key 大概率拿不到兜底（拿到的是 `key_model_access_denied` 而不是 Mac 的回答）。
本仓库当前两个别名都已在白名单里，所以没有实测过。真要确认：临时建一个只含
`deepseek-v4-flash` 的 key，制造 DGX 不可达再调它。**在验证之前，别把「有 fallbacks 就有兜底」
当成结论** —— 兜底链是否真的通，取决于 key 而不只是 config。

## ☠️ 坑 B —— `/v1/models` 返回的是「这个 key 能访问什么」，不是 live config

拿**虚拟 key** 查 `/v1/models`，看到的是白名单过滤后的结果。改完配置用它自查，会看到旧别名，
从而得出「配置没生效」的错误结论 —— 而真实原因是坑 A。

**验证配置有没有生效，只能用 master key**：

```bash
# live config（master key，不过白名单）
curl -s -H "Authorization: Bearer $MK" https://llm.meirong.dev/v1/models \
  | python3 -c 'import sys,json; print([m["id"] for m in json.load(sys.stdin)["data"]])'
```

两者对不上时的判据：master key 看到新别名 = **配置已生效，问题在 key**；
master key 也看不到 = 配置还没进容器，往坑 C 查。

## ☠️ 坑 C —— 改了 ConfigMap 而 pod 不重启（已自动化，但要知道机制）

两个原因叠加，缺一不可：

1. 挂载是 **`subPath`**（`mountPath: /app/config.yaml` + `subPath: config.yaml`）——
   subPath 挂载**不接收 ConfigMap 更新**，kubelet 不会去刷那个文件；
2. LiteLLM **只在启动时读一次 config**。

2026-08-25 实际后果：ArgoCD 同步完 ConfigMap（`Synced`/`Healthy`），而网关按**旧路由表**
继续服务，必须手动 `kubectl rollout restart deployment/litellm -n litellm` 才生效。

**现已由 pod 模板注解 `checksum/config` 自动化**（`scripts/check-embedded-scripts.py` 的
`STAMP_ONLY`，CI 强制）：config 一变哈希就变 → pod 模板变 → ArgoCD 自然滚动重启。
机制与「加新目标」见 [manifest-safety-checks.md](manifest-safety-checks.md) 的 E1 章节。

⚠️ 所以**不要手改那个注解**，改完 config 在 `k8s/helm/` 跑 `just gen-embedded-scripts`。
注解一旦被摘掉，上面那个静默失效会原样回来。

## ☠️ 上游 `nvidia/*` 打不通 —— 是 `model` 字段的双前缀，不是 key 的问题

清单里写的是 `model_name: "nvidia/*"` → `model: "openai/nvidia/*"`。LiteLLM 用别名里被
`*` 捕获的部分去替换 `model` 里的 `*`，于是发给上游的模型名**带上了多余的 `nvidia/`**。

2026-08-25 在 litellm pod 里直连 `integrate.api.nvidia.com` 实测（用的就是网关自己那把
`NVIDIA_API_KEY`）：

| 发出去的 model | 结果 |
|---|---|
| `meta/llama-3.3-70b-instruct`（裸名）| **200 OK** |
| `nvidia/meta/llama-3.3-70b-instruct`（网关实际发的形状）| **404 `page not found`** —— 与经网关调用时报的错逐字相同 |

**所以 key 是好的、上游是通的，坏的是 `model` 字段的写法。**

⚠️ **一个曾经的误判，写下来免得重复**：一度以为「NVIDIA 一把 key 只授权一个模型、要用别的
免费模型得另外生成 key」。**实测不成立** —— 拿这把 key 查 `GET /v1/models` 返回 **102 个模型**
（`deepseek-ai/deepseek-v4-flash-0731`、`meta/llama-3.3-70b-instruct`、`google/gemma-4-31b-it`、
`minimaxai/minimax-m3`、`mistralai/mistral-large` 等），且裸名调用成功。判据很简单：
**授权问题回 401/403，`404 page not found` 是路由/模型名对不上**——别把这两类混起来。

**怎么修（未部署验证）**：把 `model` 改成 `"openai/*"`，让捕获到的通配内容**单独**成为模型名：

```yaml
      - model_name: "nvidia/*"
        litellm_params:
          model: "openai/*"                       # 不是 openai/nvidia/* —— 后者会多带一层前缀
          api_base: https://integrate.api.nvidia.com/v1
          api_key: os.environ/NVIDIA_API_KEY
```

改完必须实调一次确认（`nvidia/meta/llama-3.3-70b-instruct` 应回 200），**别只看
`/v1/models` 里有没有它** —— 见下条。

⚠️ 它还**污染 `/v1/models`**：master key 查询会看到 200+ 个 `nvidia/` 前缀条目，内容却是
**OpenAI 的模型名**（`nvidia/gpt-4o`、`nvidia/dall-e-3`、`nvidia/sora-2`、`nvidia/o3` …），
NVIDIA 上并不存在。这是 LiteLLM 按 openai provider 的静态模型表展开通配的结果，与 key 能
访问什么无关。**别拿 `/v1/models` 里出现某个 `nvidia/X` 当作它可用的证据。**

**这把 key 实际能用的模型清单**（102 个，随 NVIDIA 目录变）现取：

```bash
POD=$(kubectl --context k3s-homelab -n litellm get pod -l app=litellm -o jsonpath='{.items[0].metadata.name}')
kubectl --context k3s-homelab -n litellm exec "$POD" -- python3 -c "
import os,json,urllib.request
r=urllib.request.Request('https://integrate.api.nvidia.com/v1/models',
    headers={'Authorization':'Bearer '+os.environ['NVIDIA_API_KEY']})
print('\n'.join(m['id'] for m in json.load(urllib.request.urlopen(r,timeout=30))['data']))"
```

## 上游是思维链模型：小 `max_tokens` 会把思维链漏进 `content`

`reasoning_content` 的切分依赖 `</think>` 闭合标签；token 用完标签不出现，parser 就失去切分
依据、把整段思考原样放进 `content`（不报错、不告警，只是答案变成一坨思考过程）。

- 受影响的是**所有**自托管上游（DGX 的 deepseek、Mac 的 Ornith 都是思维链模型），
  不是某个模型的缺陷；
- 逃生口是别名 **`mac/ornith-fast`** —— 走 OMLX 的 `fast` profile（`enable_thinking: false`），
  与 `mac/ornith` 共用同一份驻留权重、不触发换入换出；
- 实测数据、为什么换 Ornith、以及「换模型不能消除该失效模式」的反例，见
  [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md) 的「2026-08-25 修订」。

⚠️ **只暴露一个 Mac 35B**：OMLX 池天花板 30GB 装不下两个（19.95 + 19.08GB）。两个别名并存
= 交替调用持续换入换出（~18s/次，期间回 `is busy`）。

## 消费方

| 消费方 | 用哪个别名 | 配置在哪 |
|---|---|---|
| `codex --profile litellm` | `custom_dgx/deepseek-v4-flash` | `~/.codex/litellm.config.toml`（本机）|
| `codex --profile mac` | `mac/ornith` | `~/.codex/mac.config.toml`（本机）|
| k8sgpt（`--backend openai`）| `deepseek-v4-flash` | `~/Library/Application Support/k8sgpt/k8sgpt.yaml`（本机）|
| k8sgpt（`--backend localai`）| `mac/ornith-fast` | 同上 |
| Open Notebook | **不走网关** —— 直连 DGX 与 OMLX | [open-notebook.md](open-notebook.md) |

⚠️ 本机消费方全部读同一个 `LITELLM_VK`（`~/.zshrc`），所以坑 A 一旦发生是**全体**受影响。
