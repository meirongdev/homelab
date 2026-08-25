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

## ☠️ 上游 `nvidia/*` 的通配透传是个假象 —— NVIDIA 的 key 按模型授权

**约束（build.nvidia.com 的平台行为，不是 LiteLLM 的问题）**：
一把 NVIDIA API key **只能调用它被授权的那个模型**。想用别的免费模型，**得为那个模型
另外生成一把 key**。**没有「一把 key 打通所有免费模型」这种用法。**

所以清单里 `model_name: "nvidia/*"` 这条通配**在「一把 key」的前提下根本不成立**：
它对外宣称能透传任意 `nvidia/<模型 ID>`，实际只有当前那把 key 授权的那一个能用。

⚠️ **当前这把 key（Vault `secret/homelab/litellm-nvidia`）绑的是哪个模型，仓库里没有记录**
（2026-08-16 加它的 commit `b45955a` 也没写）。要查只能去 build.nvidia.com 看这把 key 是从
哪个模型页面生成的。**下次轮换或新增 key 时请把模型 ID 写进清单注释**，否则又会丢。

**想再加一个免费模型，正确做法**（不要去改通配）：

1. 在 build.nvidia.com 上为该模型单独生成一把 key；
2. 进 Vault：`secret/homelab/litellm-nvidia-<模型简称>`，经 ESO 注入成**独立的**环境变量；
3. 在 config.yaml 里加一条**显式**的 model 条目（不是通配），`api_key` 指向那个新环境变量；
4. 别忘了把新别名加进虚拟 key 的白名单（坑 A）。

**两条观察，写下来免得下次重复排查**：

- 实测 `nvidia/meta/llama-3.3-70b-instruct` 返回的是
  `litellm.NotFoundError: OpenAIException - 404 page not found`。⚠️ 纯粹的授权范围问题通常
  回 401/403，而 `404 page not found` 更像 URL/模型名对不上 —— 所以**换对 key 之后仍要单独
  验证模型 ID 的写法**（现在是 `model: "openai/nvidia/*"`，`nvidia/` 这一段是否被当成模型名的
  一部分发给上游，没有验证过）。别假设「key 换对了就通了」。
- 它还**污染 `/v1/models`**：master key 查询会看到 200+ 个 `nvidia/` 前缀条目，内容却是
  **OpenAI 的模型名**（`nvidia/gpt-4o`、`nvidia/dall-e-3`、`nvidia/sora-2`、`nvidia/o3` …），
  这些在 NVIDIA 上并不存在。是 LiteLLM 按 openai provider 的静态模型表展开通配的结果。
  **别拿 `/v1/models` 里出现某个 `nvidia/X` 当作它可用的证据。**

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
