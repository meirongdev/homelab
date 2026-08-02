# Homelab — Agent Context

> 双集群 homelab（homelab + oracle-k3s）基础设施即代码。
> 给 AI 助手的**常驻精简上下文**。根目录 `AGENTS.md` 与 `CLAUDE.md` 都软链到本文件。
>
> 📖 **需要细节时读 `docs/CONVENTIONS.md`**（长版，完整约定 + 架构 + 各组件踩坑记录，
> 另软链为 `.gemini.md` / `.github/copilot-instructions.md`）。本文件刻意保持精简以控制常驻上下文成本，
> **不要**把长篇内容往这里搬——架构事实进 `reference/`，决策进 `decisions/`，两者都在 CONVENTIONS.md 里有索引。

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
    ├── AGENTS.md                ← 本文件（简版；软链为根 AGENTS.md）
    ├── CONVENTIONS.md           # 完整约定+架构上下文（软链为 .gemini.md / copilot-instructions.md）
    ├── README.md                # 文档门户/索引
    ├── ARCHITECTURE.md          # 架构概览
    ├── ROADMAP.md               # 唯一的开放项清单
    ├── guides/                  # 面向任务的跨领域流程
    ├── reference/               # 当前生效的架构事实 (source of truth)
    ├── decisions/               # 技术决策记录 (轻量 ADR)
    ├── records/                 # 故障复盘/事故报告
    ├── runbooks/                # 运维操作手册 (SOP)
    └── plans/                   # 带日期的方案档案，写完即冻结
        └── apps|architecture|networking|observability|security|storage/
```
> **写文档前先读 `docs/README.md` 的「文档组织规则」（R1-R7）**：目录归属、命名、
> 文首必填字段、状态枚举、索引维护、唯一真相源。放错目录/漏建索引都算违规。

## Key Commands

执行目录为 `k8s/helm/`，除非另有说明。

| 类别 | 命令 | 说明 |
|------|------|------|
| K3s | `just setup-k8s` | 安装 K3s (k8s/ansible/) |
| 部署 | GitOps（`git push`） | LGTM/otel/external-dns 全 GitOps：charts+values 在 `argocd/applications/` 与 `k8s/helm/values/` |
| ArgoCD | `just deploy-argocd` | 安装/升级 ArgoCD chart + AppProject (幂等)。⚠️ **控制面在 oracle-k3s**，不含 Application 注册 |
| ArgoCD | `just deploy-argocd-apps` | 注册 Application 对象。☠️ destination 未重写时跑它会把 homelab 全套负载装到 oracle |
| ArgoCD | `just argocd-password` | 打印 admin 初始密码 |
| GitOps | `git push` → ArgoCD 自动同步 | 3 分钟轮询, 不可手动 kubectl apply 覆盖 |
| Vault | `just deploy-vault` | 部署 Vault |
| Vault | `just vault-init && just vault-unseal` | 初始化和解封 |
| 备份 | GitOps（`backup` App） | restic CronJob 由 ArgoCD 同步，改 `backup/overlays/` + git push |
| 备份 | `just backup-run` | 手动触发备份 |
| Cilium | `just deploy-cilium` | 部署/升级 Cilium (k8s/cilium/) |
| Cloudflare | `just apply` | terraform apply (cloudflare/terraform/) |
| 集群互联 | `just connect-clustermesh <homelab-ts>:32379 <oracle-ts>:32379` | Cilium ClusterMesh 连接（需两个端点参数） |
| Proxmox | `just init/plan/apply` | `proxmox/terraform/`（**`just` 不是 `make`**，那里的 Makefile 是空文件） |
| Oracle | `make init/plan/apply` | `cloud/oracle/terraform/`（这里才用 `make`） |

⚠️ **新加子域名不需要动 DNS**：写一个 HTTPRoute 即可（external-dns 建记录 + 隧道通配路由转发），不要改 `cloudflare/terraform`。

## Architecture Quick Reference

- **GitOps 控制面在 oracle-k3s**（2026-08-02 迁移）：`destination.server: kubernetes.default.svc`
  在 Application 里指的是 **oracle**；homelab 负载必须显式写 `https://100.94.186.7:6443`。
  日志(Loki)/追踪(Tempo) 同批迁 oracle，**但 Prometheus/Grafana/Alertmanager 仍在 homelab**
  ——遥测不是单向的。见 `docs/runbooks/argocd-control-plane-on-oracle.md`
- **CNI**: 双集群 Cilium eBPF + VXLAN
- **Ingress**: Cilium Gateway API (唯一入口)
- **跨集群**: Tailscale Pod CIDR 路由 + Cilium ClusterMesh
- **外部流量**: Internet → Cloudflare DNS → Cloudflare Tunnel → Cilium Gateway → Service
- **homelab node**: 10.10.10.10 / TS 100.94.186.7 (Ryzen 5600H 笔记本)
- **oracle-k3s node**: 10.0.0.26 / TS 100.107.166.37 (Oracle Cloud Free Tier)
- **NAS (storage-106)**: 192.168.50.106 / TS 100.110.27.111

## Documentation Rules

1. **架构事实**写进 `reference/`，不在 plan 里留"唯一副本"
2. **临时决策/排障**写进 `plans/<category>/`（**写完即冻结的历史快照，不代表现状**——查现状看 `reference/`）
3. **可重复的 SOP**写进 `runbooks/`
4. **技术决策**写进 `decisions/`（记录当时场景和取舍）
5. **命令步骤必须可执行**，避免思路型描述
6. **过期内容**标注 `Deprecated` 并链接替代文档
7. **维护所有 README 索引**保持与目录同步

## Security Model

纵深防御 11 层: Cloudflare WAF → ZITADEL OIDC → Vault+ESO → PSA → Kyverno → Trivy → kube-bench → 节点 CIS → 网络(见下) → Tetragon/Falco → restic 备份。

⚠️ **第 9 层网络只到"可见性"**：Hubble 已开，但集群内**没有任何自建 `CiliumNetworkPolicy`**（`kubectl get cnp,ccnp -A` 为空；`argocd` ns 里那几条 NetworkPolicy 是 argo-cd chart 自带的）。网络默认拒绝是**刻意延后**的（单用户威胁模型下收益边际低、debug 成本高），不要把它当成已生效的管控。逐层状态与灰度路径见 `docs/reference/security.md`。

**硬约束**: homelab 是 Ryzen 5600H 单节点笔记本 (idle ~74°C)。所有安全组件 **fail-open + 控 CPU**。

## Storage Notes

- **NFS 已退役 (2026-07-11)**: 全部 PVC 用 `local-path`; 106 只做冷备份目标, 不再是运行时依赖
- **sqlite 应用必须用 `local-path`**, 不用 NFS (fcntl 锁在 NFS 上极慢)
- **备份**: restic CronJob 直推 106 ZFS 加密仓库 (sftp), 双集群每夜; homelab 另有 PVE 每周 vzdump 整 VM → 106 `backups`
- **恢复验证**: 2026-07-06 演练通过 (Vault raft + 2 PG + sqlite)
