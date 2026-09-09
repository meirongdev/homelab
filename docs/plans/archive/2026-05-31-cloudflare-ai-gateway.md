# Cloudflare AI Gateway — 设计与实现计划

> 日期: 2026-05-31
> 状态: ❌ **已退役**。落地过，随后 `cloudflare_ai_gateway` Terraform 资源被整体移除
> （`terraform state rm`），本仓库当前不存在任何 Cloudflare AI Gateway 资源。
> 接替者: 自建 LLM 网关 → [decisions/litellm-llm-gateway.md](../../decisions/litellm-llm-gateway.md)
> 与 [reference/litellm-gateway.md](../../reference/litellm-gateway.md)。
> 结论: 本页只作选型留档。**2026-09-09 合并**：原「设计」与「实现计划」两份文档
> （合计 639 行）压缩成本页。

## 当初想解决什么

给两个 LLM 后端——`nv-dgx-spark` 与一台经 Tailscale 互联的独立机器——做一个统一的
AI 出口，附带用量可见性与治理能力。目标不是把 AI Gateway「部署到某个 cluster」，
而是把它当作 **Cloudflare 账号层能力**管理；集群里的应用只负责调用。

## 三条设计决策

**1. 放 Cloudflare 层，不放任何 cluster。** 它是 Cloudflare 托管能力不是 K8s 工作负载；
两个集群都可能是调用方；与既有 Tunnel / DNS / WAF 的 IaC 分层一致。落点 `cloudflare/terraform/`。

**2. 只建 gateway 本身，不建 custom provider。** 当时 `nv-dgx-spark` 对外只有 Tailscale 地址
和 HTTP 端口，不满足 custom provider 对 **HTTPS base URL** 的要求。提前建只能二选一：
写假的占位 URL（配置无意义）或写 Tailscale 私网地址（请求不可达）——都不值得。

**3. 升级 provider 约束到 `~> 5.19`。** `cloudflare_ai_gateway` 资源自 5.19.0 起才可用，
当时仓库约束是 `~> 5.0`、本地停在 5.17.0。

## 值得留下的两条边界认知

☠️ **Tailscale 地址对 Cloudflare 边缘不可达。** AI Gateway 的上游请求不运行在 Tailnet 里，
所以 `100.x` 对你的设备可达 ≠ 对 Cloudflare 可达。自建模型要走 Cloudflare，
必须先有一个 Cloudflare 能访问的 HTTPS 暴露层。**这条至今成立**，是后来改走
自建网关（LiteLLM，直接跑在集群内、经 Tailscale 直连 DGX）的直接原因之一。

**缓存与限流默认关闭。** 推理请求带上下文、温度参数、会话状态，默认开缓存容易造出
「看起来成功但语义错误」的结果；限流则在摸清真实客户端并发模式前先关，避免误伤集成。

## 为什么最终退役

分阶段计划的 Phase 2/3（给自建模型加 HTTPS 暴露层 → 建 custom provider）从未执行——
为了让 Cloudflare 边缘够得着自建模型而专门加一层公网 HTTPS 暴露，代价高于收益。
需求改由集群内自建 LLM 网关满足：LiteLLM 直接经 Tailscale 连 DGX，
不需要任何东西暴露到公网，用量与路由治理也一并拿到。
