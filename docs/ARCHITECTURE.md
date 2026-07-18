# Homelab Architecture

> 单页架构总览，双集群 homelab（homelab + oracle-k3s）。
> Last updated: 2026-07-06

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
         │  NFS + restic 仓库   │
         │  TS: 100.110.27.111  │
         └──────────────────────┘
```

## Cluster Comparison

| 维度 | homelab | oracle-k3s |
|------|---------|------------|
| 硬件 | Ryzen 5600H 笔记本, 16GB 物理（OS 实际可见 13.5GB，~2GB 被核显 UMA 显存占用；实测见 [architecture-optimization-2026-07-04.md §4](reference/architecture-optimization-2026-07-04.md)） | Oracle Cloud Free Tier (ARM, 24GB) |
| 角色 | 主力集群 (observability/vault/calibre) | 轻量服务 (homepage/it-tools/uptime) |
| 存储 | NFS (ZFS raidz1) + local-path | local-path only |
| 备份 | restic CronJob → 106 sftp | restic CronJob → 106 sftp (via TS) |
| 安全 | Tetragon + Kyverno + Trivy | Falco (oracle 无 Kyverno/Trivy) |
| GitOps | ArgoCD hub (homelab 本地) | ArgoCD spoke (经 TS 纳管) |

## Key Architecture Decisions

| 决策 | 结论 | 文档 |
|------|------|------|
| CNI | Cilium (eBPF + VXLAN) | 详见 `decisions/` |
| Ingress | Cilium Gateway API (非 Traefik) | `decisions/gateway-controller-evaluation.md` |
| 镜像更新 | ArgoCD Image Updater (CRD 模式) | `decisions/argocd-image-updater.md` |
| 备份工具 | restic (非 Kopia) | `plans/storage/2026-07-04-*.md` |
| SSO | 应用原生 OIDC, 非共享入口层 SSO | `plans/networking/2026-03-08-*` |
| 跨集群网络 | Tailscale Pod CIDR + Cilium ClusterMesh | `reference/tailscale-network.md` |

## Service Inventory

| 服务 | 集群 | URL | 认证 |
|------|------|-----|------|
| Calibre-Web | homelab | book.meirong.dev | 内置 |
| Grafana | homelab | grafana.meirong.dev | 内置 |
| Vault | homelab | vault.meirong.dev | 内置 |
| ArgoCD | homelab | argocd.meirong.dev | 内置 |
| ZITADEL | oracle-k3s | auth.meirong.dev | OIDC |
| Homepage | oracle-k3s | home.meirong.dev | 公开 |
| Uptime Kuma | oracle-k3s | status.meirong.dev | 公开 |
| Miniflux | oracle-k3s | rss.meirong.dev | 内置 |
| KaraKeep | oracle-k3s | keep.meirong.dev | 内置 |

## Security (Defense in Depth)

11 层纵深防御: 边缘(WAF) → 身份(OIDC) → 密钥(Vault+ESO) → 准入(PSA) → 策略(Kyverno) → 供应链(Trivy) → CIS → 节点加固 → 网络策略 → 运行时(Tetragon/Falco) → 备份(restic)。

详见: `reference/security.md`

## Current Active Work

- **主线**: 存储本地化迁移 + 备份体系重建 → `plans/storage/2026-07-06-*.md`
- **下一步**: 离站备份, dead-man's switch, zpool/SMART 告警
- **完整路线图**: `plans/ROADMAP.md`
