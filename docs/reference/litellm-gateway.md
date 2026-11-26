# LiteLLM 网关（运维事实与坑）

> Last updated: 2026-11-26
> Status: 生效事实
> Scope: `llm.meirong.dev` 这个 LLM 网关的配置生效路径、鉴权分层、路由与 key（上游与兼容层在 [litellm-upstreams.md](litellm-upstreams.md)），
> 本文是 source of truth。为什么选 LiteLLM、上游怎么选、兜底为何几经更换（Qwen3.6 → Ornith → Studio），见
> [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md)（决策与实测数据）。

## 速览

| | |
|---|---|
| 集群 / ns | homelab / `litellm`（**钉控制面**，只有它的 netmap 里有 DGX 与 Mac）|
| 公网入口 | `llm.meirong.dev`（Cloudflare Tunnel → Cilium Gateway → HTTPRoute）|
| tailnet 入口 | `100.94.186.7:31400`（NodePort Service `litellm-external`）。oracle 的作业和管理接口都走这里：经 Cloudflare 调管理接口会被 WAF 以 `error code: 1010`(403) 挡（非浏览器 UA）|
| 推理鉴权 | master key + 虚拟 key（`Authorization: Bearer sk-…`）|
| 管理面 | `/ui`，LiteLLM 自带登录（`UI_USERNAME`/`UI_PASSWORD`，Vault→ESO）|
| 路由表 | `k8s/helm/manifests/litellm/litellm.yaml` 的 ConfigMap（在 git 里）|
| key / spend | 同集群共享 Postgres `databases/apps-pg` 的 `litellm` 库（**不在 git 里**，见坑 A）|

**配置真相源分成两半，这是本文档存在的理由**：

| 东西 | 存在哪 | 改法 |
|---|---|---|
| 模型列表 / `api_base` / 降级顺序与健康检查 | git 的 ConfigMap | 改清单 → push → ArgoCD |
| **虚拟 key 能访问哪些模型** | Postgres | 只能调 API（坑 A）|
| **哪些 key 改道到 Studio 首选**（key 级 `aliases`）| Postgres | 只能调 API（「按 key 分首选」）|
| 花费账本 / key 有效期 | Postgres | `/ui` 或 API |

### 别名

| 别名 | 上游 | 降级 |
|---|---|---|
| `DeepSeek-V4.1-Flash-1017` | 外发 key 与默认的首选。三级：DGX（11-17 起实际跑 Qwen3.8-Flash-Next，见 [litellm-upstreams.md](litellm-upstreams.md)）→ Studio 的 Qwen3.8-27B → M2 的 Ornith。由谁作答由网关按健康状况决定，DGX 宕机、恢复都不用改配置。homelab 内部的 key 请求这个名字会被改道到 `homelab/qwen3.8-27b` | 自动，见「自动降级」|
| `qwen3.8-flash-next-tp2` | **兼容别名**（2026-11-15）：DeepSeek 之前那个 DGX 栈的名字，外发 key 的使用者还在用。三级上游始终与上一行一致；4 把 ext-* key 与 ext-team-1 账户的白名单已加回这个名字。11-17 起 DGX 又跑回这个模型，名不副实的反倒是上一行；不动客户端是刻意的代价。spend log 连续两周没有旧名调用再删，删时同步从那 5 处白名单和健康检查列表拿掉 | 与上一行一致 |
| `homelab/qwen3.8-27b` | homelab 内部的首选（2026-11-15）。三级，顺序与上两行相反：Studio 的 Qwen3.8-27B → DGX → M2。**不进任何白名单**，只有带 key 级 `aliases` 的内部 key 经改道到达 | 自动，见「按 key 分首选」|
| `custom_dgx/DeepSeek-V4.1-Flash-1017` | DGX | 刻意不降级：给「就要打 DGX」的消费方，静默换成别的模型反而有害（DGX 不通时如实报连接错误）|
| `mac/ornith` / `mac/ornith-fast` | M2 的 OMLX，Ornith-1.5-35B-A3B；`-fast` 走 OMLX 的 `fast` profile（关思考），两者共用同一份驻留权重 | 无（同一份权重是裸别名的第 3 级）|
| `studio/qwen3.8-27b` | Mac Studio 的 OMLX（见 [litellm-upstreams.md](litellm-upstreams.md)「Mac Studio 上游」）| 外发 key：无（同一份权重是裸别名的第 2 级）。内部 key：被改道到 `homelab/qwen3.8-27b`，多了 DGX 兜底 |
| OMLX 模型 ID 原文 ×4：`ornith-ai__Ornith-1.5-35B-A3B-MLX-4bit`、`mlx-community__Qwen3-Embedding-4B-4bit-DWQ`（embedding）、`mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`（TTS）、`mlx-community__Qwen3-ASR-1.7B-8bit`（ASR）| M2 的 OMLX | 给 open-notebook：它的模型按名字绑在凭据上、改名要删了重建，所以网关按原名建别名（2026-11-11）|
| `openrouter/*` | OpenRouter 全量透传 | 免费档不能当兜底（见 [litellm-upstreams.md](litellm-upstreams.md)「哪些模型能免费用」）|

## ☠️ 坑 A：虚拟 key 的模型白名单在 Postgres 里，git 完全管不到

每个虚拟 key 带一份 `models` 白名单，值是别名字面量。在 git 里改别名（重命名、删除、新增），key 不会跟着变，
于是「清单正确 + ArgoCD Synced + 调用全挂」。症状：

```
key not allowed to access model. This key can only access models=[...]. Tried to access <新别名>
```

☠️ 这条错误和「配置写错了」长得一样，但 ConfigMap 是新的、ArgoCD `Synced`/`Healthy`、pod `Running`、探针全绿。
**症状在 key，不在配置**；用虚拟 key 查 `/v1/models` 还会把它误判成配置没生效（坑 B）。

- ⚠️ **改别名必须同步改 key**，顺序无所谓，两件都要做。白名单散在多把 key 里，只改「自己那把」必然漏
  （两次换栈都是 16 把里 8 把引用了 DGX 别名）。
- ⚠️ `/key/update` 是**整表替换**，不是增量：先读原列表，只映射要改的项，其余原样带回。
- `/key/list` 只认 GET + 分页（POST 回 405），返回的是 token 的 sha256 而不是原文，白名单要逐把 `key/info` 看。
  本机的 `LITELLM_VK` 是哪把：`printf %s "$LITELLM_VK" | sha256sum` 去匹配列表。
- ✅ 白名单只约束「你能指名什么」：降级在同一个别名组内完成，只含 `DeepSeek-V4.1-Flash-1017` 的窄 key
  照样被降到 Studio / M2，但直接指名 `studio/qwen3.8-27b` 仍 403。窄 key（如 `calibre-metadata-llm`）不需要为降级放宽。

本机任意目录（`VK` = 要查或要改的那把虚拟 key）：

```bash
GW=http://100.94.186.7:31400        # tailnet NodePort，不经 Cloudflare WAF
MK=$(kubectl --context k3s-homelab -n litellm get secret litellm-secret \
      -o jsonpath='{.data.master-key}' | base64 -d)

# 列全量（翻 page=2、3… 直到为空）
curl -s -H "Authorization: Bearer $MK" "$GW/key/list?page_size=50&page=1"

# 看一把 key 的白名单（key= 填原文或列表里的 sha256 都行）
curl -s -H "Authorization: Bearer $MK" "$GW/key/info?key=$VK" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("info") or d).get("models"))'

# 覆盖白名单（整个列表替换）
curl -s -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"key":"'"$VK"'","models":["custom_dgx/DeepSeek-V4.1-Flash-1017","DeepSeek-V4.1-Flash-1017",
       "mac/ornith","mac/ornith-fast","openrouter/*"]}' \
  "$GW/key/update"
```

## 自动降级：裸别名的三级上游（2026-11-15 起）

同一个 `model_name` 下三条 deployment，`order` 1 DGX → 2 Studio → 3 M2，叠加后台健康检查。配置在
`litellm.yaml`，下表是用线上同 digest 镜像（1.103.1）在本地对假上游实测的结果：

| 主上游怎么坏 | 只有 `order` | 加上健康检查剔除（现行）|
|---|---|---|
| 拒绝连接（引擎停了、主机在线；11-15 DGX 就是这样）| 同一请求内降级，多花 <0.5s；chat / responses、流式与否都过 | 同左 |
| 黑洞（整机离线，SYN 没回应）| ☠️ **每个请求先挨约 406s**（内核 SYN 重试约 127s × SDK 共 3 次）才降级，且单上游组默认不冷却，下一个请求照挨 | 探测标记后 0.3s 直接走第 2 级 |
| 前两级都坏 | 降到第 3 级 | 同左 |
| 主上游恢复 | — | 下一轮探测通过即切回 order 1，不用改配置 |

- 看这次是谁答的：响应头 `x-litellm-model-api-base`（响应体的 `model` 永远是别名本身）。
- 健康检查每 30s 一轮、16 token，单条超时 DGX 30s、Studio / M2 60s。所以上游**刚**坏的头一轮（DGX 最长约 60s）里，
  请求照常先打它：拒绝连接无所谓，黑洞或「收连接但不回」的那几个请求要等满超时才降级。之后的请求不受影响。
- ☠️ 超时要按「坏」和「忙」区分，别统一调小：上线当天统一 15s，DGX 宕机、全部流量压到 Studio 时，一个 2.8 万 token
  的预填充就让探测排队 10s 以上，Studio 两次被误判、请求被降到 M2（会话中途换模型，前缀缓存作废）。
  判据：`LiteLLM_HealthCheckTable`（只在状态变化时写一行）里 Studio 的 `Timeout exceeded`，对照 Studio 的
  `/opt/homebrew/var/log/omlx.log` 同一时刻有没有大 `prompt:` 的请求。
- ☠️ `background_health_check_model_groups` 必须列明：不列就探全部模型，包括 `openrouter/*`（真花钱）和
  M2 的 TTS / ASR / embedding（会让 OMLX 换入换出）。列明后范围外的组 0 次探测（实测）。换栈时这里的名字要跟着换，
  漏了 = 不再探活，整机离线时退回每请求 406s。
- ☠️ `health_check_staleness_threshold`（现为 180s）必须大于「最长单条超时 + 间隔」：健康状态一过期，过滤整个失效、
  所有上游重新放行。默认是间隔 ×2，太紧。
- ⚠️ 别设 router 级 `allowed_fails` / `allowed_fails_policy`：设了以后健康检查过滤被跳过，而且所有单上游别名也开始冷却。
- ⚠️ 不按错误类型区分：DGX 回参数级 400 也会降级，见 [litellm-upstreams.md](litellm-upstreams.md) DGX 一节「参数错误会被降级悄悄吞掉」。
- ⚠️ 别用 YAML 锚点给这 9 条去重：PyYAML 的别名是同一个 dict 对象，LiteLLM 会往 `model_info` 里写各自的 id。

**历史**：2026-11-15 前用的是 `router_settings.fallbacks: [{"<主>": ["<兜底>"]}]` 串别名。它是单上游组，没有冷却，
整机离线时就是上表左列的 406s。更早（08-01 至 09-19）`fallbacks` 写在模型条目的 `litellm_params` 里，那是透传给
SDK 的 kwarg，从来没生效过，主上游一失败就 500 `LLM Provider NOT provided ...`：
[records/2026-09-19-litellm-fallbacks-never-active.md](../records/2026-09-19-litellm-fallbacks-never-active.md)。

## 按 key 分首选：外发 DGX 首选，homelab 内部 Studio 首选（2026-11-15 起）

分工是用户定的：给出去的 key 用 DGX 当首选（别名 `DeepSeek-V4.1-Flash-1017`，实际跑什么见 [litellm-upstreams.md](litellm-upstreams.md)）、Studio 的 Qwen3.8-27B 兜底；homelab 内部反过来。
两边请求的是同一批名字（裸别名、兼容别名），按名字分不开，所以按 key 分：内部 key 带 LiteLLM 的 key 级 `aliases`
（`{"请求名": "改道到的组"}`），把三个名字改道到 `homelab/qwen3.8-27b`。客户端一个字不用改。

| 谁 | 请求 `DeepSeek-V4.1-Flash-1017` / `qwen3.8-flash-next-tp2` | 请求 `studio/qwen3.8-27b` |
|---|---|---|
| 外发 key（4 把 `ext-*`、`ext-team-1` 账户下的 key）、master key、以后新发的 key | 原组：DGX → Studio → M2 | 只有 Studio，不降级 |
| 带 `aliases` 的内部 key | 改道 `homelab/qwen3.8-27b`：Studio → DGX → M2 | 同左 |

带 `aliases` 的内部 key（2026-11-26 才真正写入，见下方「写完必须回读」）：`LITELLM_VK`（sha256 前缀 2c15baf776…，三台 Mac 的 Qwen Code / codex / k8sgpt）、
`m2-magpie`、`m5-magpie`、`studio-magpie`、`open-notebook`、`calibre-metadata-llm`、`xiaogpt`。
`jobs-sg` 刻意没带：它只用 `custom_dgx/` 前缀（就要打 DGX、不降级），这个名字也不在改道表里。

- 实测（2026-11-15，线上 1.103.1，临时 key）：白名单按客户端请求的**原名**查，白名单只有目标组、没有原名的 key 是 403；
  改道后响应体的 `model` 仍是原名，客户端看不出来。所以 `homelab/qwen3.8-27b` 不进任何白名单，外发 key 指名调它是 403。
- 谁答的：响应头 `x-litellm-model-api-base`。spend log 的 `model_group` 记的是改道后的组名，
  内部 key 的调用在那里显示为 `homelab/qwen3.8-27b`，不是客户端填的名字；`original_model_group` 也是改道后的组名
  （11-26 实测），客户端原本填了什么在库里查不到。
- ☠️ `/key/update` 传 `aliases` 是**整表替换**（实测：只传一条，原来那条就没了），改完立即生效，不用重启。
- ☠️ 改道目标组在 config 里不存在时，请求直接 400 `There are no healthy deployments for this model`（实测）。
  所以顺序是先 push 新组、等 pod 换上，再写 `aliases`；删组时反过来，先清 `aliases`。
- ☠️ 这又是一处不在 git 里的路由事实（与坑 A 同类）。换栈改名时，`aliases` 的**键**（客户端请求的原名）要跟着改：
  键对不上不会报错，只是不再改道，内部流量悄悄回到 DGX 首选。
- ☠️ **写完必须回读，别只改文档**：11-15 只上线了改道组，写 `aliases` 那一步漏了，本文与 CHANGELOG 却写成已完成，
  内部流量 10 天都是 DGX 首选（`LITELLM_VK` 431 次 DGX、8 次 Studio），11-25 查 400 时才发现。11-26 补写，判据两条：
  下方 psql 回读有 7 行；spend log 里内部 key 的 `model_group` 是 `homelab/qwen3.8-27b`、`api_base` 是 Studio。
- 改道组里 DGX 是第 2 级，那条 deployment 同样带 `upstream_compat` 声明。hook 按 deployment 改写（2026-11-25 起），
  降到 DGX 时照样改写，Studio 收到原样请求（[litellm-upstreams.md](litellm-upstreams.md) 坑 E）。
- 新增内部 key 时在 `/key/generate` 里带上同样的 `aliases`；不带就是外发口径（DGX 首选）。

```bash
# 回读：哪些 key 带改道（在 Postgres 里，git 看不到）
kubectl --context k3s-homelab -n databases exec deploy/apps-pg -- psql -U postgres -d litellm -c \
  "select coalesce(key_alias, left(token,10)) k, aliases from \"LiteLLM_VerificationToken\" where aliases::text <> '{}' order by 1;"

# 给一把内部 key 加改道（整表替换：先 /key/info 看原值，原来有别的条目要一起带上）
curl -s -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"key":"<token>","aliases":{"DeepSeek-V4.1-Flash-1017":"homelab/qwen3.8-27b",
       "qwen3.8-flash-next-tp2":"homelab/qwen3.8-27b","studio/qwen3.8-27b":"homelab/qwen3.8-27b"}}' \
  "$GW/key/update"
```

## ☠️ 坑 B：`/v1/models` 返回的是「这个 key 能访问什么」，不是 live config

拿虚拟 key 查 `/v1/models`，看到的是白名单过滤后的结果；改完配置用它自查会看到旧别名，从而误判「配置没生效」，
真实原因是坑 A。**验证配置有没有生效，只能用 master key**（本机任意目录，`MK` 取法见坑 A）：

```bash
curl -s -H "Authorization: Bearer $MK" https://llm.meirong.dev/v1/models \
  | python3 -c 'import sys,json; print([m["id"] for m in json.load(sys.stdin)["data"]])'
```

master key 看到新别名 = 配置已生效，问题在 key；master key 也看不到 = 配置还没进容器，往坑 C 查。

## ☠️ 坑 C：改了 ConfigMap 而 pod 不重启（已自动化，但要知道机制）

两个原因叠加：config 是 `subPath` 挂载（`/app/config.yaml`），subPath **不接收 ConfigMap 更新**；LiteLLM 只在启动时
读一次 config。不重启的后果是 ArgoCD `Synced`/`Healthy`，网关按旧路由表继续服务。两个 hook 的 `.py` 同理。

现由 pod 模板注解 `checksum/config`（hook 各有一个 `checksum/*-py`）自动化：内容一变哈希就变，ArgoCD 自然滚动重启。
CI 强制（`scripts/check-embedded-scripts.py` 的 `STAMP_ONLY`），机制见 [manifest-safety-checks.md](manifest-safety-checks.md) 的 E1。

⚠️ **别手改注解**：改完 config 在 `k8s/helm/` 跑 `just gen-embedded-scripts`。注解一旦被摘掉，静默失效原样回来。

## 上游与兼容层（在 litellm-upstreams.md）

网关背后各上游的事实拆在 [litellm-upstreams.md](litellm-upstreams.md)：「DGX 主力栈」（☠️ 对外别名与 DGX 实际跑的
模型刻意不一致）、「Mac Studio 上游」、思维链模型的小 `max_tokens` 陷阱、坑 D（codex 派 subagent 就 400）、
坑 E（DGX 回 400 的请求被兜底静默接走）、「哪些模型能免费用」。

## 每把 key 的用量与来源 IP（spend log）

每次调用（含失败）在 `apps-pg` 的 `litellm` 库写一行 `LiteLLM_SpendLogs`：

| 列 | 内容 |
|---|---|
| `api_key` | key 的 sha256，不是原文 |
| `metadata->>'user_api_key_alias'` | 发 key 时给的 `key_alias`，没给就是空 |
| `"startTime"` / `model_group` / `call_type` / `status` | 时间、别名、路由、`success`/`failure` |
| `prompt_tokens` / `completion_tokens` / `total_tokens` | 用量。☠️ 别看 `spend`：自托管模型没有单价，全表 spend 都是 0 |
| `metadata->>'user_agent'` | 客户端 UA |
| `requester_ip_address` | 来源 IP，见下 |

- ⚠️ 不存对话内容（没开 `store_prompts_in_spend_logs`）。别为排障顺手打开，那会把外部使用者的 prompt 落进库。
- 没设 `maximum_spend_logs_retention_period`，行会一直留着，量级上不用管。
- `requester_ip_address`：公网调用记 Cloudflare 的 `CF-Connecting-IP`（真实客户端 IP，IPv6 客户端就是 IPv6；伪造不了），
  tailnet NodePort 记调用方的 `100.x`，集群内走 Service 记 pod IP。公网那条靠 `client_ip.py` hook 改写，为什么不用
  `general_settings.use_x_forwarded_for`、信任边界与防伪造实测都在它的文件头。
- ☠️ hook 上线（2026-10-03）前的行，公网调用一律是 `10.42.0.152`（k8s-node 的 CiliumInternalIP），补不回来。
- ⚠️ 被限流拒掉的 `/v1/responses` 请求，IP 是空串（LiteLLM 本身行为，与 hook 无关；chat 被限流的行有 IP）。
- hook 是否加载：每个 pod 首次改写打一条 WARNING，`kubectl --context k3s-homelab -n litellm logs deploy/litellm | grep client_ip`。

按 key × IP 看近 7 天用量（本机任意目录；没有别名的 key 显示哈希前 12 位，对照方法见坑 A）：

```bash
kubectl --context k3s-homelab -n databases exec deploy/apps-pg -- psql -U postgres -d litellm -c "
select coalesce(nullif(metadata->>'user_api_key_alias', ''), left(api_key, 12)) as key,
       requester_ip_address as ip,
       count(*) as calls, count(*) filter (where status = 'failure') as failed,
       sum(total_tokens) as tokens, max(\"startTime\")::timestamp(0) as last_seen
from \"LiteLLM_SpendLogs\" where \"startTime\" > now() - interval '7 days'
group by 1, 2 order by calls desc;"
```

## 发给外部的 key

⚠️ 存量 key 大多没有 `key_alias`，也都没设 rpm/tpm/并发上限（2026-10-03 盘点 18 把里 17 把无 alias）。
对外发 key 这样建（本机任意目录，`MK` / `GW` 见坑 A）：

```bash
curl -s -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"key_alias":"ext-<谁>","models":["studio/qwen3.8-27b"],"duration":"30d",
       "rpm_limit":60,"max_parallel_requests":2}' \
  "$GW/key/generate"
```

| 参数 | 为什么 |
|---|---|
| `key_alias` | spend log 聚合按它分组；必须唯一，重名直接拒绝 |
| `duration` | 到期自动失效，调用方拿到 401 `expired_key` |
| `rpm_limit` / `max_parallel_requests` | 超了回 429 `throttling_error`（同 digest 镜像本地实测过）。☠️ 别用 `max_budget` 限额：自托管模型 spend 恒为 0，限不住 |

- 吊销用 `/key/delete`（`{"key_aliases": [...]}` 或 `{"keys": [...]}`）。☠️ 删完别拿 `key/info` 核验：已删除的 key
  照样 200 并返回完整信息。看 `/key/list?key_alias=<别名>` 为空，或拿旧 key 调用得 401
  （[records/2026-10-26-litellm-keys-in-public-repo.md](../records/2026-10-26-litellm-keys-in-public-repo.md)）。
- 给使用者看的公开说明（不含密钥）→ [guides/llm-gateway-external-users.md](../guides/llm-gateway-external-users.md)。

## 消费方

| 消费方 | 用哪个别名 | 配置在哪 |
|---|---|---|
| 三台 Mac 的 Qwen Code 与 codex | 默认 `DeepSeek-V4.1-Flash-1017`（`LITELLM_VK` 带 `aliases`，实际 Studio 首选、DGX 兜底），可指名 `studio/qwen3.8-27b` / `mac/ornith`。codex 默认仍是 ChatGPT 登录，经网关用 `codex -p litellm\|studio\|mac`（profile 里的推理档位对这些模型是空操作，见 [litellm-upstreams.md](litellm-upstreams.md)「推理档位经网关」）| `cd macbook/ansible && just llm-clients` 统一下发（2026-11-15 起；直连上游的旧 profile 已清掉）|
| 本机任意 OpenAI 兼容客户端 | `studio/qwen3.8-27b` | 读 `LITELLM_VK`；目前没有固定消费方 |
| k8sgpt（默认，`--backend localai`）| `mac/ornith-fast` | `~/Library/Application Support/k8sgpt/k8sgpt.yaml`（本机）|
| k8sgpt（`--backend openai`）| `DeepSeek-V4.1-Flash-1017` | 同上。☠️ explain 输出为空：k8sgpt 0.4.39 实际按 2048 截断（无视 `maxtokens: 4096`），DGX 默认开思考，2048 全用在思考上（网关记 `success`、`completion_tokens=2048`），所以默认后端是 localai |
| oracle 上的 calibre 元数据作业 | `DeepSeek-V4.1-Flash-1017`（经 `litellm-external` NodePort；key 带 `aliases`，实际 Studio 首选）。⚠️ 护栏没在 Studio 的 Qwen3.8-27B 上复验过，下次跑先 `DRY_RUN=1` | [清单内嵌脚本](../../cloud/oracle/manifests/calibre-metadata/metadata-llm.yaml) |
| xiaogpt（小爱音箱，homelab `personal-services`）| `studio/qwen3.8-27b`，专用 key `key_alias=xiaogpt`（带 `aliases`，改道后多了 DGX 兜底）| [xiaogpt.yaml](../../k8s/helm/manifests/personal-services/xiaogpt.yaml) 的 ConfigMap |
| Open Notebook（homelab `personal-services`）| `DeepSeek-V4.1-Flash-1017`（key 带 `aliases`，实际 Studio 首选）+ OMLX 原名的 4 个别名（chat / embedding / TTS / ASR）+ `studio/qwen3.8-27b`（第二备选），专用 key `key_alias=open-notebook`，2026-11-11 起 | [open-notebook.md](open-notebook.md)；key 由 provisioner 写进两个凭据 |
| jobs-sg enrich（homelab `jobs-sg`）| `custom_dgx/DeepSeek-V4.1-Flash-1017`（刻意不带兜底），专用 key `key_alias=jobs-sg`，2026-11-11 起 | [jobs-sg-enrich.md](jobs-sg-enrich.md) |
| 外部使用者（UI 账户 `ext-team-1`）| 5 个自托管别名 + 17 个 OpenRouter `:free` 模型。不带 `aliases`：DGX 首选 | Postgres（账户与 key 各一层白名单），见「发给外部的 key」|
| M2 / Studio 上的 magpie（`homelab` provider）| `DeepSeek-V4.1-Flash-1017` → `studio/qwen3.8-27b`（magpie 的 `group/qwen`；组 id 是历史名，换栈没改，免得每个 agent 重设。三把 magpie key 都带 `aliases`，两个名字实际都是 Studio 首选、DGX 兜底），另暴露若干 `openrouter/*` | 每台一把（`key_alias` 为 `m2-magpie` / `studio-magpie`），值在 Vault `secret/homelab/magpie`，`cd macbook/ansible && just magpie` 下发。☠️ 别写进 playbook：[泄露复盘](../records/2026-10-26-litellm-keys-in-public-repo.md) |

⚠️ 三台 Mac 的消费方全部读同一个 `LITELLM_VK`（chezmoi 写进各自的 `~/.secrets.sh`），坑 A 一旦发生是全体受影响。
