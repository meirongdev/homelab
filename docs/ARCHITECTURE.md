# Homelab Architecture

> 单页架构总览，双集群 homelab（homelab + oracle-k3s）。
> Last updated: 2026-07-31

## Network Topology

```
Internet → Cloudflare DNS → Cloudflare Tunnel(cloudflared) → Cilium Gateway API → Service
                                                                     │
                    ┌─────────────────────────────────────────────────┘
                    ▼
         ┌──────────────────────┐       Tailscale (Pod CIDR)      ┌──────────────────────┐
         │    homelab (K3s)     │ ◄──────────────────────────────► │   oracle-k3s (K3s)   │
         │  CNI: Cilium VXLAN   │     10.42.0.0/16 ←→ 10.52.0.0/16│  CNI: Cilium VXLAN   │
         │  node: 10.10.10.10   │      Cilium ClusterMesh          │  node: 10.0.0.26    │
         │  TS:  100.94.186.7   │                                  │  TS:  100.107.166.37│
         └──────────┬───────────┘                                  └──────────────────────┘
                    │ LAN 192.168.50.x
         ┌──────────▼───────────┐
         │  storage-106 (NAS)   │
         │  ZFS raidz1 + sanoid │
         │  ZFS + restic 仓库   │
         │  TS: 100.110.27.111  │
         └──────────────────────┘
```

## Cluster Comparison

| 维度 | homelab | oracle-k3s |
|------|---------|------------|
| 硬件 | Ryzen 5600H 笔记本, 16GB 物理（OS 实际可见 15.0GB（MemTotal 15717940 kB；核显 UMA 显存已从 2GB 调整为 512MB）；实测见 [2026-07-04 舰队架构优化 §4](plans/architecture/2026-07-04-fleet-architecture-optimization.md)） | Oracle Cloud Free Tier (ARM, 24GB) |
| 角色 | 指标中枢 + Vault + 本地模型接入 (Prometheus/Grafana/Vault/Open Notebook/Bifrost) | 公网服务 + GitOps 控制面 + 日志/追踪 + 身份面 (ArgoCD/Loki/Tempo/ZITADEL/Calibre/…) |
| 存储 | local-path (NFS retired 2026-07-11; 106 = cold backup target) | local-path only |
| 备份 | restic CronJob → 106 sftp | restic CronJob → 106 sftp (via TS) |
| 安全 | Tetragon + Kyverno + Trivy | Falco (oracle 无 Kyverno/Trivy) |
| GitOps | ArgoCD hub (homelab 本地) | ArgoCD spoke (经 TS 纳管) |

## Key Architecture Decisions

| 决策 | 结论 | 文档 |
|------|------|------|
| CNI | Cilium (eBPF + VXLAN)，双集群统一；从 Flannel 迁入 | [`plans/networking/2026-03-06-cilium-mesh-installation.md`](plans/networking/2026-03-06-cilium-mesh-installation.md)（无独立 ADR） |
| Ingress | Cilium Gateway API (非 Traefik) | [`decisions/gateway-controller-evaluation.md`](decisions/gateway-controller-evaluation.md) |
| 镜像更新 | 无自动升级（ArgoCD Image Updater 已于 2026-08-03 退役；可选 Renovate） | [`decisions/argocd-image-updater.md`](decisions/argocd-image-updater.md) |
| 告警投递 | Alertmanager 原生 telegramConfigs (Gotify 已退役) | [`decisions/alerting-telegram-migration.md`](decisions/alerting-telegram-migration.md) |
| 子域名 DNS | external-dns (HTTPRoute 声明式，取代 Terraform 手管) | [`decisions/external-dns-adoption.md`](decisions/external-dns-adoption.md) |
| 成本/右尺寸 | OpenCost 走 collector 旁路 + KRR 窄口径采集 | [`decisions/opencost-krr-data-sources.md`](decisions/opencost-krr-data-sources.md) |
| 配置漂移体检 | ArgoCD 原生 `orphanedResources` (否决 kor) | [`decisions/orphaned-resources.md`](decisions/orphaned-resources.md) |
| 备份工具 | restic (非 Kopia)，无 server 直推 106 | [`plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md`](plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md) |
| SSO | 应用原生 OIDC, 非共享入口层 SSO | [`plans/security/2026-03-08-cilium-zitadel-sso-plan.md`](plans/security/2026-03-08-cilium-zitadel-sso-plan.md) |
| 跨集群网络 | Tailscale Pod CIDR + Cilium ClusterMesh | [`reference/tailscale-network.md`](reference/tailscale-network.md) |

## Service Inventory

完整清单（含 namespace、内部服务、认证方式）在 [CONVENTIONS.md § Services](CONVENTIONS.md#services) —
**唯一真相源，此处不复制**。

分布速览（2026-08 大调整后）: homelab 跑 **Open Notebook / Prometheus / Grafana / Alertmanager / Vault / Bifrost**；oracle-k3s 跑 **ArgoCD 控制面 / Loki / Tempo / Calibre-Web**，其余（ZITADEL、Homepage、
Uptime Kuma、Miniflux、KaraKeep、IT-Tools、Stirling-PDF、Squoosh、Excalidraw、Trends、Timeslot）都在 oracle-k3s。

## Security (Defense in Depth)

11 层纵深防御: 边缘(WAF) → 身份(OIDC) → 密钥(Vault+ESO) → 准入(PSA) → 策略(Kyverno) → 供应链(Trivy) → CIS → 节点加固 → 网络(**仅 Hubble 可见性**) → 运行时(Tetragon/Falco) → 备份(restic)。

⚠️ 第 9 层是 11 层里唯一没落到"管控"的：集群内无自建 `CiliumNetworkPolicy`，**网络默认拒绝刻意延后**。

详见: [`reference/security.md`](reference/security.md)（逐层状态表 + 威胁覆盖矩阵）

## Current Active Work

开放项（离站备份、Terraform state → R2、prometheus-operator CRD 补升、DGX Spark 入编 等）
统一维护在 [`ROADMAP.md`](ROADMAP.md)，此处不复制。
