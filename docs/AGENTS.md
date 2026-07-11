# Homelab — Agent Context

> 双集群 homelab（homelab + oracle-k3s）基础设施即代码。
> 给 AI 助手的项目上下文。在根目录 `AGENTS.md` 软链此文件。

## Project Structure

```
homelab/
├── proxmox/terraform|ansible/   # VM 预配 (Proxmox VE)
├── k8s/
│   ├── ansible/                 # K3s 安装 (just setup-k8s)
│   ├── cilium/                  # Cilium Helm values (手动管理, 非 ArgoCD)
│   └── helm/                    # 应用部署 (values/, manifests/)
├── cloud/oracle/                # Oracle Cloud K3s (terraform|ansible|manifests/)
├── argocd/                      # GitOps (install|projects|applications/)
├── cloudflare/terraform/        # Cloudflare Tunnel + DNS + WAF
├── tailscale/terraform/         # Tailscale ACL + 预授权密钥
└── docs/                        # 文档
    ├── AGENTS.md                ← 本文件
    ├── ARCHITECTURE.md          # 架构概览
    ├── guides/                  # 面向任务的跨领域流程
    ├── reference/               # 当前生效的架构事实 (source of truth)
    ├── decisions/               # 技术决策记录 (轻量 ADR)
    ├── records/                 # 故障复盘/事故报告
    ├── runbooks/                # 运维操作手册 (SOP)
    └── plans/                   # 带日期的方案/复盘 (按类别: storage|networking|security|observability|apps)
```

## Key Commands

执行目录为 `k8s/helm/`，除非另有说明。

| 类别 | 命令 | 说明 |
|------|------|------|
| K3s | `just setup-k8s` | 安装 K3s (k8s/ansible/) |
| 部署 | `just deploy-all` | 部署 LGTM 全栈 (Loki/Grafana/Tempo/Mimir) |
| ArgoCD | `just deploy-argocd` | 安装 ArgoCD + 注册所有 Application (幂等) |
| ArgoCD | `just argocd-password` | 打印 admin 初始密码 |
| GitOps | `git push` → ArgoCD 自动同步 | 3 分钟轮询, 不可手动 kubectl apply 覆盖 |
| Vault | `just deploy-vault` | 部署 Vault |
| Vault | `just vault-init && just vault-unseal` | 初始化和解封 |
| 备份 | `just deploy-backup` | 部署 restic CronJob |
| 备份 | `just backup-run` | 手动触发备份 |
| Cilium | `just deploy-cilium` | 部署/升级 Cilium (k8s/cilium/) |
| Cloudflare | `just apply` | terraform apply (cloudflare/terraform/) |
| 集群互联 | `just connect-clustermesh` | Cilium ClusterMesh 连接 |

## Architecture Quick Reference

- **CNI**: 双集群 Cilium eBPF + VXLAN
- **Ingress**: Cilium Gateway API (唯一入口)
- **跨集群**: Tailscale Pod CIDR 路由 + Cilium ClusterMesh
- **外部流量**: Internet → Cloudflare DNS → Cloudflare Tunnel → Cilium Gateway → Service
- **homelab node**: 10.10.10.10 / TS 100.94.186.7 (Ryzen 5600H 笔记本)
- **oracle-k3s node**: 10.0.0.26 / TS 100.107.166.37 (Oracle Cloud Free Tier)
- **NAS (storage-106)**: 192.168.50.106 / TS 100.110.27.111

## Documentation Rules

1. **架构事实**写进 `reference/`，不在 plan 里留"唯一副本"
2. **临时决策/排障**写进 `plans/<category>/`
3. **可重复的 SOP**写进 `runbooks/`
4. **技术决策**写进 `decisions/`（记录当时场景和取舍）
5. **命令步骤必须可执行**，避免思路型描述
6. **过期内容**标注 `Deprecated` 并链接替代文档
7. **维护所有 README 索引**保持与目录同步

## Security Model

纵深防御 11 层: Cloudflare WAF → ZITADEL OIDC → Vault+ESO → PSA → Kyverno → Trivy → kube-bench → 节点 CIS → Cilium NetworkPolicy → Tetragon/Falco → restic 备份。

**硬约束**: homelab 是 Ryzen 5600H 单节点笔记本 (idle ~74°C)。所有安全组件 **fail-open + 控 CPU**。

## Storage Notes

- **NFS 已退役 (2026-07-11)**: 全部 PVC 用 `local-path`; 106 只做冷备份目标, 不再是运行时依赖
- **sqlite 应用必须用 `local-path`**, 不用 NFS (fcntl 锁在 NFS 上极慢)
- **备份**: restic CronJob 直推 106 ZFS 加密仓库 (sftp), 双集群每夜; homelab 另有 PVE 每周 vzdump 整 VM → 106 `backups`
- **恢复验证**: 2026-07-06 演练通过 (Vault raft + 2 PG + sqlite)
