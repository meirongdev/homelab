# LLM 网关迁移到 LiteLLM（双自托管来源）

> 日期: 2026-08-01（2026-08-16 实施，纳入 Mac OMLX 第二上游）
> 状态: ✅ 已实施
> 关联: `docs/plans/apps/2026-08-01-litellm-gateway-migration.md`

## Context

homelab LLM 网关（llm.meirong.dev）原为一个自托管的 LLM 网关。其配置（enforce 开关/路由/
虚拟 key）存 PVC-SQLite，管理面无鉴权需 oauth2-proxy+ZITADEL 配套，且该旧网关实际未被使用，已于
2026-08-08 独立退役。

用户考虑换 LiteLLM 的契机是"Rust 重写"，但核实：截至 2026-08-01 Rust 网关只覆盖 `/v1/realtime`，
生产 proxy 仍是 Python。

本仓库有两个**自托管推理源**，都可从 homelab 控制面直连（Open Notebook 已生产验证接线）：
- **DGX Spark vLLM**（`100.97.87.120:8000`，`deepseek-v4-flash`，1M ctx）——跨境共享节点（SG↔CN，DERP hkg，RTT 66–83ms），常驻但他人机器、无告警、不可控。
- **MacPro M2 OMLX**（`100.89.15.120:8000`，`Qwen3.6-35B`，262k ctx）——境内低延迟但**笔记本无 SLA**（电池/合盖/负载可能掉）。

两者互不能全信，需要一个网关统一入口 + 自动 failover。

## Decision

- 用 **LiteLLM proxy**（v1.94.1，官方 Python proxy）替换旧 LLM 网关，hostname 不变（`llm.meirong.dev`）。
- **配置进 git**（config.yaml 的 ConfigMap），keys/spend 落同集群 Postgres（`litellm-pg`，local-path PVC）。
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
