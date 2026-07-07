# Reference

> 当前生效的架构事实 source of truth。

## Network

1. [tailscale-network.md](tailscale-network.md) — 双集群互联模型 (Pod CIDR only)
2. [cloudflare-tunnel-observability.md](cloudflare-tunnel-observability.md) — Tunnel + Gateway 流量可观测

## Observability

1. [observability-multicluster.md](observability-multicluster.md) — 日志/指标/链路追踪统一架构
2. [observability-otel-logging.md](observability-otel-logging.md) — OTel 日志管道细节
3. [k8s-qos-resource-management.md](k8s-qos-resource-management.md) — 资源配额与 QoS 约定

## Security

1. [security.md](security.md) — 集群安全纵深防御 (11 层威胁矩阵)

## Resource Planning

1. [evolution-roadmap-2026-07-07.md](evolution-roadmap-2026-07-07.md) — 技术债盘点 + 工具链演进路线（含 Crossplane 不引入结论）
2. [resource-optimization-2026-07-06.md](resource-optimization-2026-07-06.md) — 资源分配优化明细
3. [architecture-optimization-2026-07-04.md](architecture-optimization-2026-07-04.md) — 物理层架构与机器角色建议
4. [simplification-recommendations-2026-03.md](simplification-recommendations-2026-03.md) — Oracle Cilium 迁移后简化建议

> 所有文档中的命令必须注明执行上下文 (cluster/path)。
