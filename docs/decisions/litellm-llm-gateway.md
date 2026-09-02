# LLM 网关迁移到 LiteLLM（双自托管来源）

> 日期: 2026-08-01（2026-08-16 实施，纳入 Mac OMLX 第二上游）
> 状态: ✅ 已实施
> 关联: `docs/plans/apps/2026-08-01-litellm-gateway-migration.md`
> 生效事实与运维坑（虚拟 key 白名单 / 配置生效路径 / 上游可用性）:
>   [reference/litellm-gateway.md](../reference/litellm-gateway.md)
> 修订: 2026-08-25：Mac 兜底模型由 `Qwen3.6-35B` 换为 `Ornith-1.5-35B-A3B`，
>   网关别名 `mac/qwen3.6-35b` → `mac/ornith`（下方 Decision 记录的是 2026-08-01 的原始决策，
>   不改写；换型理由与实测见本文件末尾「2026-08-25 修订」）。
> 修订: 2026-09-02：DGX 主力模型由 `DeepSeek-V4-Flash` 换为 `Qwen3.8-Flash-Next`（NVFP4），
>   别名 `custom_dgx/deepseek-v4-flash` / `deepseek-v4-flash` →
>   `custom_dgx/qwen38-flash-next` / `qwen38-flash-next`。换栈由上游 nv-dgx-spark 单方面做出，
>   本仓库只是跟着改引用；生效事实见
>   [reference/litellm-gateway.md](../reference/litellm-gateway.md) 的「DGX 主力模型」，
>   换栈理由与压测在 nv-dgx-spark 仓库。本文件的 Decision 仍不改写，见末尾「2026-09-03 修订」。

## Context

homelab LLM 网关（llm.meirong.dev）原为一个自托管的 LLM 网关。其配置（enforce 开关/路由/
虚拟 key）存 PVC-SQLite，管理面无鉴权需 oauth2-proxy+ZITADEL 配套，且该旧网关实际未被使用，已于
2026-08-08 独立退役。

用户考虑换 LiteLLM 的契机是"Rust 重写"，但核实：截至 2026-08-01 Rust 网关只覆盖 `/v1/realtime`，
生产 proxy 仍是 Python。

本仓库有两个**自托管推理源**，都可从 homelab 控制面直连（Open Notebook 已生产验证接线）：
- **DGX Spark vLLM**（`100.97.87.120:8000`，`deepseek-v4-flash`，1M ctx）：跨境共享节点（SG↔CN，DERP hkg，RTT 66–83ms），常驻但他人机器、无告警、不可控。
- **MacPro M2 OMLX**（`100.89.15.120:8000`，`Qwen3.6-35B`，262k ctx）：境内低延迟但**笔记本无 SLA**（电池/合盖/负载可能掉）。

两者互不能全信，需要一个网关统一入口 + 自动 failover。

## Decision

- 用 **LiteLLM proxy**（v1.94.1，官方 Python proxy）替换旧 LLM 网关，hostname 不变（`llm.meirong.dev`）。
- **配置进 git**（config.yaml 的 ConfigMap），keys/spend 落同集群 Postgres（2026-08-25 起是共享实例 `databases/apps-pg` 的 `litellm` 库；此前为本 ns 自带的 `litellm-pg`）。
- **砍掉 oauth2-proxy/ZITADEL client**：LiteLLM 管理面**自带认证**（`UI_USERNAME/UI_PASSWORD`，
  Vault→ESO），符合 security.md「自带认证」矩阵。备选（保留 oauth2-proxy 复用旧的 oauth2-proxy client）因双重登录
  +维护面被否决。
- **双自托管来源 fallback：DGX 主 + Mac 兜底**。config.yaml 里 `deepseek-v4-flash`（逻辑名）声明
  `fallbacks: ["mac/qwen3.6-35b"]`，DGX 不可达时自动切 Mac；Mac 也作为独立 `mac/qwen3.6-35b` 模型，
  供想绕开 fallback 的消费方直接指名。**不做双向均衡**（Mac 是笔记本，不该平摊生产性对话流量）。
- **网关只接对话/生成模型**，不接 Mac 的 embedding/STT/TTS/rerank（那些仍由 Open Notebook 直连 Mac）。
- 不接入 Rust ai-gateway（仅 `/v1/realtime`）。
- 镜像按 digest 钉死（v1.94.1 + postgres:17-alpine，amd64）。

## Consequences

- +一个 Postgres 运行时依赖（单副本 local-path，restic 通过 `pg_dump` 兜底，H4 白名单）。
- admin UI 由强口令（Vault 生成）而非 SSO 守护；单用户 + CF WAF 威胁模型下可接受。
- 网关**必须钉在控制面**：只有控制面的 netmap 里有 DGX/Mac，worker-106 是
  tagged-device 看不到这两个源；钉在 worker 既连不上上游、又会在 3G VM 上 OOM（实测）。
- Python proxy 内存占用比旧 LLM 网关（Go）高：limit 需 ≥2Gi（1Gi 实测首启跑 Prisma migration 时 OOMKilled）。
- 双自托管来源 fallback（替代原"双 DGX"设想）由 LiteLLM 原生 `fallbacks` 承载。
- 消费方（本机 codex）改用 `--profile litellm`，旧网关的 virtual key 迁移为 `LITELLM_VK`；
  可选 `--profile mac` 显式用 Mac 兜底模型。

## 相关文档

- [cluster-placement-for-new-services](cluster-placement-for-new-services.md)（落点判据）
- [dgx-clustermesh-not-adopted](dgx-clustermesh-not-adopted.md)（DGX 网络边界）
- `/docs/reference/open-notebook.md`（双上游接线唯一真相源）
- `/docs/plans/apps/2026-08-01-litellm-gateway-migration.md`（实施计划，冻结快照）

## 2026-08-25 修订：Mac 兜底模型换成 Ornith-1.5-35B-A3B

**换型理由不是「Qwen3.6 有 bug」**，而是它思考得太多，在小 `max_tokens` 下必然被截断：

思维链模型的 `reasoning_content` 切分依赖 `</think>` 闭合标签。token 用完时标签不会出现，
OMLX 的 parser 就失去切分依据，**把整段思维链原样放进 `content`**：不报错、不告警，
只是答案变成一坨思考过程。实测（同一提示词，`max_tokens=4096`）：

| 模型 | finish_reason | completion | content | reasoning_content |
|---|---|---|---|---|
| Qwen3.6-35B-A3B | `length` | 4096（截断） | 8438 字符（思维链） | 字段消失 |
| Qwen3.6-35B-A3B（`max_tokens=16384`）| `stop` | 3761 | 232 字符 | 9485 字符 ✅ |
| Ornith-1.5-35B-A3B | `stop` | 278 | 298 字符 | 813 字符 ✅ |

⚠️ **Ornith 并没有消除这个失效模式**，只是把触发概率降下来：给它一个需要深想的设计题
（多集群 Postgres 故障转移），同样 `max_tokens=4096` 下它一样 `finish_reason=length`、
一样把 16362 字符思维链漏进 `content`。**结构性的解只有两条**：把 `max_tokens` 给够，
或者走 OMLX 的 `fast` profile（`enable_thinking: false`，两个模型都已建好，
暴露为 `<model>:fast`，与基础模型共用同一份驻留权重、不触发换入换出）：
网关已把它接成别名 **`mac/ornith-fast`**，k8sgpt 用的就是这条。

☠️ **只暴露一个 Mac 35B**：OMLX 池天花板 30GB 装不下两个（Qwen3.6 19.95GB + Ornith 19.08GB
= 39.03GB）。两个别名并存 = 交替调用持续换入换出，按 `load_seconds_per_gb ≈ 0.88` 每次
~18s，期间 OMLX 对请求回 `is busy`（这台机器的头号故障模式，见
[reference/omlx-inference-metrics.md](../reference/omlx-inference-metrics.md)）。
Qwen3.6 仍在盘上、仍可直连 OMLX 指名调用，只是不再从网关暴露。

Mac 侧的 `is_default` 已于 2026-08-25 指向 Ornith，因此**不带模型名**的 OMLX 调用
（如 `codex --profile m2`）也随之切换。


---

## 2026-09-03 修订：DGX 主力换成 Qwen3.8-Flash-Next

决策**不变**（双自托管来源 + 严格的"主→兜底"单向 fallback + 别名与裸 vLLM 同名），
换栈本身也不是本仓库的判断 —— 上游 nv-dgx-spark 把 :8000 换了模型，旧名直接从
`/v1/models` 消失，跟着改引用是唯一选项。这里只记两件对以后决策有影响的事：

1. **本文件 Context 里「DGX = 1M ctx」这条依据失效了**（新栈 `max_model_len=262144`）。
   按它做过长上下文规划的下游要重算，已知受影响的是 Open Notebook 的长上下文角色。
   同理 NVIDIA 侧曾按"与 DGX 主力同款"选兜底候选的思路也失效了。
2. **"别名与裸 vLLM 同名"这个选择的代价被量化了一次**：一次改名要动 5 处配置
   （网关清单 / jobs-sg 直连 / Open Notebook 接线 / oracle calibre 作业 / 告警与面板注释），
   外加 **8 把虚拟 key 的白名单**（16 把里有 8 把引用了 DGX 别名，见
   [reference/litellm-gateway.md](../reference/litellm-gateway.md) 坑 A）。
   当初图的是"下游换 base_url 就能绕过网关"，代价就是上游动一次模型，本仓库要跟着扫一遍。
   **下次再改名仍然按真实模型名命名**（不要为了少改一处就把别名做成与模型无关的稳定名 ——
   那会让"清单说 deepseek、实际给 Qwen"这种谎话进网关）。
