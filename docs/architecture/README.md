# Architecture Docs

> Source-of-truth for current production architecture.
> Last updated: 2026-06-05

## Core Architecture

1. [tailscale-network.md](tailscale-network.md) — 双集群互联模型（Pod CIDR only）
2. [observability-multicluster.md](observability-multicluster.md) — 日志/指标/链路追踪统一架构
3. [observability-otel-logging.md](observability-otel-logging.md) — OTel 日志管道细节
4. [cloudflare-tunnel-observability.md](cloudflare-tunnel-observability.md) — Tunnel + Gateway 流量可观测
5. [k8s-qos-resource-management.md](k8s-qos-resource-management.md) — 资源配额与 QoS 约定（当前值详见 resource-optimization-2026-07-06.md）
6. [security.md](security.md) — 集群安全纵深防御（边缘/身份/密钥/准入/扫描/网络/威胁矩阵）

## Design Notes

- [gateway-controller-evaluation.md](gateway-controller-evaluation.md) — Traefik vs Cilium Gateway 评估（结论: 现网已切换到 Cilium Gateway）
- [argocd-image-updater.md](argocd-image-updater.md) — Image Updater CRD 模型与约束
- [simplification-recommendations-2026-03.md](simplification-recommendations-2026-03.md) — Oracle Cilium 迁移后的下一步简化建议

## Roadmap

- [TODO.md](TODO.md) — 路线图与待办
- [resource-optimization-2026-07-06.md](resource-optimization-2026-07-06.md) — 2026-07 资源分配优化明细
- [architecture-optimization-2026-07-04.md](architecture-optimization-2026-07-04.md) — 物理层架构与机器角色分配建议

## Lifecycle Rules

1. 任何当前生效的架构事实必须同步更新到本目录。
2. 临时排障过程不要写在本目录，写入 `../plans/`。
3. 文档中涉及命令时，必须注明执行上下文（cluster / path）。
