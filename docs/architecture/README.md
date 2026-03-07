# Architecture Docs

> Source-of-truth for current production architecture.
> Last updated: 2026-03-07

## Read First

1. `tailscale-network.md`: 双集群互联模型（Pod CIDR only）
2. `observability-multicluster.md`: 日志/指标/链路追踪统一架构
3. `cloudflare-tunnel-observability.md`: Tunnel + Gateway 流量可观测
4. `k8s-qos-resource-management.md`: 资源配额与 QoS 约定
5. `gateway-controller-evaluation.md`: Traefik 与 Cilium Gateway 替换评估

## Design Notes

- `argocd-image-updater.md`: Image Updater 设计与约束
- `observability-otel-logging.md`: OTel 日志路径细节
- `TODO.md`: 路线图与待办（非运行事实）

## Lifecycle Rules

1. 任何当前生效的架构事实必须同步更新到本目录。
2. 临时排障过程不要写在本目录，写入 `../plans/`。
3. 文档中涉及命令时，必须注明执行上下文（cluster / path）。
