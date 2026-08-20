# Homelab Architecture

> 单页架构总览，双集群 homelab（homelab + oracle-k3s）。
> Last updated: 2026-08-20

## Network Topology

```
Internet → Cloudflare DNS → Cloudflare Tunnel(cloudflared) → Cilium Gateway API → Service
                                                                     │
                    ┌─────────────────────────────────────────────────┘
                    ▼
  ┌───────────────────────────────────────────┐              ┌─────────────────────────┐
  │            homelab (K3s, 2 nodes)         │  Tailscale   │     oracle-k3s (K3s)    │
  │  CNI: Cilium VXLAN                        │  (node /32)  │  CNI: Cilium VXLAN      │
  │                                           │◄────────────►│  单节点                 │
  │  control-plane  k8s-node                  │              │    10.0.0.26            │
  │      10.10.10.10      TS 100.94.186.7     │  ClusterMesh │    TS 100.107.166.37    │
  │  worker         k8s-worker-106            │  10.42/16 ↔  │                         │
  │      192.168.50.107   TS 100.74.162.97    │    10.52/16  │                         │
  └───────────────────┬───────────────────────┘              └─────────────────────────┘
                      │ LAN 192.168.50.x
  ┌───────────────────▼───────────────────────┐
  │  storage-106 (NAS, Celeron J4105 / 8G)    │
  │  ZFS raidz1 + sanoid                      │
  │    ① restic 仓库（双集群备份目标）        │
  │    ② 承载 worker VM        （2026-08-13） │
  │    ③ 媒体只读 NFS 源       （2026-08-16） │
  │  TS 100.110.27.111                        │
  └───────────────────────────────────────────┘
```

⚠️ **106 不再是"纯冷备份目标"**：自 2026-08-13/16 起它同时是 worker 的宿主和媒体数据源，
宕机会拿走一个节点 + 三个媒体服务，不再只是暂停备份窗口。→ [reference/storage.md](reference/storage.md)

## Cluster Comparison

| 维度 | homelab | oracle-k3s |
|------|---------|------------|
| 节点数 | **2**（control-plane `k8s-node` + worker `k8s-worker-106`，2026-08-13 起） | 1（单节点） |
| 硬件 | 控制面：Ryzen 5600H 笔记本，16GB 物理 / OS 可见 15.0GB / k8s VM 13312MB（分配链与判据见 [homelab-host-power-thermal.md](reference/homelab-host-power-thermal.md)，**唯一真相源**）；worker：106 上的 2c/4G VM | Oracle Cloud Free Tier (ARM, **2 OCPU / 12GB**；2026-08-05 由 4/24 缩容，见 [runbook](runbooks/oracle-k3s-shape-downsize.md)) |
| 角色 | 指标中枢 + Vault + 本地模型接入 (Prometheus/Grafana/Vault/Open Notebook) | 公网服务 + GitOps 控制面 + 日志/追踪 + 身份面 (ArgoCD/Loki/Tempo/ZITADEL/Calibre/…) |
| 存储 | 可写卷全 local-path（NFS 于 2026-07-11 退出读写路径）+ `media` ns 的 **5 个只读 NFS PV**（106 ZFS，2026-08-16） | local-path only |
| 备份 | restic CronJob ×2 → 106 sftp（控制面 03:00 / worker 02:00） | restic CronJob → 106 sftp (via TS) |
| 安全 | Tetragon + Kyverno + Trivy | Falco + Trivy（oracle 无 Kyverno；Trivy 于 2026-08-03 补齐） |
| GitOps | ArgoCD spoke（2026-08-02 起被 oracle 控制面经 TS 纳管） | ArgoCD hub（2026-08-02 起控制面在此，in-cluster；`kubernetes.default.svc` = oracle） |

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
| 关系型数据库 | CNPG 一套模式、**两个** Cluster：`apps-pg`(共享应用库) + `zitadel-pg`(身份面独立)。应用不再自带 postgres，加 `Database`/`DatabaseRole` CR 即可 | [`decisions/shared-postgres-platform.md`](decisions/shared-postgres-platform.md) |
| 备份工具 | restic (非 Kopia)，无 server 直推 106 | [`plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md`](plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md) |
| SSO | 应用原生 OIDC, 非共享入口层 SSO | [`plans/security/2026-03-08-cilium-zitadel-sso-plan.md`](plans/security/2026-03-08-cilium-zitadel-sso-plan.md) |
| 跨集群网络 | Tailscale 节点级 underlay（各节点 /32 + NodePort）+ Cilium ClusterMesh VXLAN | [`reference/tailscale-network.md`](reference/tailscale-network.md) |

## Service Inventory

完整清单（含集群/namespace、域名、运维备忘）见 [reference/services.md](reference/services.md) —
**唯一真相源，此处不复制**。

## Security (Defense in Depth)

11 层纵深防御: 边缘(WAF) → 身份(OIDC) → 密钥(Vault+ESO) → 准入(PSA) → 策略(Kyverno) → 供应链(Trivy) → CIS → 节点加固 → 网络(**仅 Hubble 可见性**) → 运行时(Tetragon/Falco) → 备份(restic)。

⚠️ 第 9 层是 11 层里唯一没落到"管控"的：集群内无自建 `CiliumNetworkPolicy`，**网络默认拒绝刻意延后**。

详见: [`reference/security.md`](reference/security.md)（逐层状态表 + 威胁覆盖矩阵）

## Current Active Work

开放项（离站备份、Terraform state → R2、prometheus-operator CRD 补升、DGX Spark 入编 等）
统一维护在 [`ROADMAP.md`](ROADMAP.md)，此处不复制。
