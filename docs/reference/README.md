# Reference

> 当前生效的架构事实 source of truth。所有文档中的命令必须注明执行上下文 (cluster/path)。

## 生效事实

改架构就必须同步这些文档。

### 网络

- [tailscale-network.md](tailscale-network.md) — 双集群互联模型（Tailscale 只做 node underlay，pod 流量走 ClusterMesh VXLAN）+ 路由踩坑
- [cloudflare-tunnel-observability.md](cloudflare-tunnel-observability.md) — Tunnel + Gateway 流量可观测（能看到什么、看不到什么）

### 可观测

- [observability-multicluster.md](observability-multicluster.md) — 日志/指标/链路追踪统一架构
- [observability-otel-logging.md](observability-otel-logging.md) — OTel 日志管道细节 + 4 种应用接入模式
- [k8s-qos-resource-management.md](k8s-qos-resource-management.md) — 资源配额与 QoS 约定
- [cost-and-rightsizing.md](cost-and-rightsizing.md) — OpenCost 成本归因 + KRR 右尺寸（定价模型、指标语义、运维操作）

### 安全

- [security.md](security.md) — 纵深防御 11 层逐层状态 + 威胁覆盖矩阵。⚠️ 第 9 层网络**只到可见性**，无自建 CiliumNetworkPolicy

### GitOps

- [argocd-app-patterns.md](argocd-app-patterns.md) — ArgoCD 管理模式、pattern 对比、新增 Application 的 3 个坑

### 应用

- [open-notebook.md](open-notebook.md) — AI 研读知识库：部署形态、模型接线（DGX + Mac OMLX，provisioner 声明式）、配置真相源地图、备份口径

---

> **本目录只放常青事实。** 带日期的诊断/建议（架构优化、技术债盘点、资源右尺寸建议）
> 属于快照，一律放 [`plans/architecture/`](../plans/architecture/README.md)——2026-07-31 已把 4 篇迁出。
