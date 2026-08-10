# Homelab — Agent Context

> 双集群 homelab（homelab + oracle-k3s）基础设施即代码。
> 给 AI 助手的**唯一上下文文件**：根目录 `AGENTS.md`、`CLAUDE.md`、`.gemini.md`、
> `.github/copilot-instructions.md` 全部软链到本文件。
>
> 📖 **需要细节时按域读 `docs/reference/`**（各组件生效事实 + 踩坑记录，索引见
> [docs/reference/README.md](reference/README.md)；文档总门户 [docs/README.md](README.md)）。
> 本文件刻意保持精简以控制常驻上下文成本，**不要**把长篇内容往这里搬——
> 架构事实进 `reference/`，决策进 `decisions/`。

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
├── zitadel/                     # 身份/SSO (terraform|scripts/)
├── backup/                      # restic 备份 (kustomize base+overlays)
├── macbook/ansible/             # 远程无头 M2 MacBook 配置
└── docs/                        # 文档
    ├── AGENTS.md                ← 本文件（唯一 AI 上下文；4 个软链见文首）
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
| Oracle | `make init/plan/apply` | `cloud/oracle/terraform/`（**唯一**用 `make` 的 terraform root） |

⚠️ **新加子域名不需要动 DNS**：写一个 HTTPRoute 即可（external-dns 建记录 + 隧道通配路由转发），
不要改 `cloudflare/terraform`。机制见 `docs/reference/networking-ingress.md`。

## Architecture Quick Reference

- **GitOps 控制面在 oracle-k3s**（2026-08-02 迁移）：`destination.server: kubernetes.default.svc`
  在 Application 里指的是 **oracle**；homelab 负载必须显式写 `https://100.94.186.7:6443`。
  日志(Loki)/追踪(Tempo) 同批迁 oracle，**但 Prometheus/Grafana/Alertmanager 仍在 homelab**
  ——遥测不是单向的。见 `docs/runbooks/argocd-control-plane-on-oracle.md`
- **CNI**: 双集群 Cilium eBPF + VXLAN
- **Ingress**: Cilium Gateway API (唯一入口)
- **跨集群**: Tailscale 只做**节点级 underlay**（各节点自己的 /32 + NodePort），pod↔pod 走
  Cilium ClusterMesh VXLAN。⚠️ **Pod CIDR 子网路由已于 2026-07-07 移除**，`AdvertiseRoutes`
  只该有本节点 /32。ClusterMesh 排障判据与告警兜底（`retrieved=true`、两个 secret 分工、
  up-but-stuck 不自愈）→ [tailscale-network.md](reference/tailscale-network.md)。
- **oracle 重启/改 shape 后**跑 `cd cloud/oracle && just verify-node`（一次核完全部不变量，
  只读；脚本结尾自己报「N 项通过 / M 项失败」——**别在文档里写死条数**，它是循环里动态累加的，
  2026-08-06 已从 23 漂到 24）。
- **外部流量**: Internet → Cloudflare DNS → Cloudflare Tunnel → Cilium Gateway → Service
- **homelab node**: 10.10.10.10 / TS 100.94.186.7 (Ryzen 5600H 笔记本)
- **oracle-k3s node**: 10.0.0.26 / TS 100.107.166.37 (Oracle Cloud Free Tier)
- **NAS (storage-106)**: 192.168.50.106 / TS 100.110.27.111

**按域查细节（`docs/reference/`）**: 服务清单 `services.md`（唯一真相源）· GitOps/App 清单
`argocd-app-patterns.md` · 入口/DNS `networking-ingress.md` · 跨集群网络 `tailscale-network.md` ·
存储/备份 `storage.md` · 身份/OIDC `identity.md` · 安全逐层 `security.md` ·
可观测采集 `observability-multicluster.md` + `observability-otel-logging.md` ·
告警/看板/SLO `observability-alerting-slo.md` · 成本 `cost-and-rightsizing.md`。

## Working Conventions

- **任务运行器**: `just`（唯一例外 `cloud/oracle/terraform/` 用 `make`）。
- **Commits**: Conventional Commits（`feat:` / `fix:` / `chore:`）。
- **Helm**: 配置进 `values/*.yaml`，不用内联 `--set`。
- **SSH**: 全舰队用 key `~/.ssh/vgio`。
- **新增服务**: 走 skill `.claude/skills/add-service/SKILL.md`（manifest → HTTPRoute →
  homepage → Uptime Kuma monitor 全流程）。**落点按资源画像选**，判据见
  [cluster-placement-for-new-services.md](decisions/cluster-placement-for-new-services.md)：
  **计算密集 / 大流量公共服务 / 只有 amd64 镜像 → homelab**（余 7.5 核 + 6.6GB，2026-08-10 实测；
  ⚠️ 但它 limits 已超卖且同机托着 Prometheus/Vault，**必须写显式 CPU limit**，且抬温有实际代价）；
  轻量无状态个人服务仍默认 **oracle-k3s**，但 ⚠️ **它不再"容量宽裕"**（2026-08-05 缩到
  **2 OCPU / 12GB**，单向不可逆；CPU requests 占 allocatable 71%、只剩约 0.5 核；limits 超卖；
  内存余量**看 `free -m` available 或 `rssBytes`，别信 `kubectl top node`**——
  实测数值与判据见 [k8s-qos-resource-management.md](reference/k8s-qos-resource-management.md)）。
  新服务 requests 按实测填（CPU 多数应用 10–25m 足够），非核心挂 `priorityClassName: bulk`；
  ⚠️ arm64 先确认镜像有 `linux/arm64`；跨 ns 引用要 ReferenceGrant（**`v1beta1`**）；
  PVC 一律 `local-path`；oracle 密钥放 `secret/oracle-k3s/<service>`，不放 `secret/homelab/*`。
  改 shape 走 `docs/runbooks/oracle-k3s-shape-downsize.md`。

## Documentation Rules

1. **架构事实**写进 `reference/`，不在 plan 里留"唯一副本"
2. **临时决策/排障**写进 `plans/<category>/`（**写完即冻结的历史快照，不代表现状**——查现状看 `reference/`）
3. **可重复的 SOP**写进 `runbooks/`
4. **技术决策**写进 `decisions/`（记录当时场景和取舍）
5. **命令步骤必须可执行**，避免思路型描述
6. **过期内容**标注 `Deprecated` 并链接替代文档
7. **维护所有 README 索引**保持与目录同步

## Manifest Safety (CI 强制)

☠️ **删任何清单文件前先 `grep '^kind:' <file>`** —— ArgoCD 按目录同步，删文件 = prune 掉
文件里的**全部**对象；内嵌的 `Namespace` 会连带删光同 ns 下**其它应用**的数据
（PVC 的 `Prune=false` 拦不住，被 prune 的是 ns）。2026-08-03 就这样删过一次。

`scripts/check-manifests.py` 在 CI 上强制 5 条**由真实事故反推**的规则：
**H1** Namespace/CRD 独占文件 · **H2** Application 的 `path` 与 `destination` 同集群 ·
**H3** ReferenceGrant 必须 `v1beta1` · **H4** 新增 PVC 必须有备份归属（白名单或写明豁免理由）·
**H5** Namespace 必须显式写 PSA 等级（漏写 = 静默吃默认 `privileged` 且无 warn/audit）。
规则全文 + **静态查不出、只能靠人的那几类** → `docs/reference/manifest-safety-checks.md`。
搬有状态服务照 `docs/runbooks/stateful-service-cross-cluster-migration.md` 走。

## Security Model

纵深防御 11 层: Cloudflare WAF → ZITADEL OIDC → Vault+ESO → PSA → Kyverno → Trivy → kube-bench → 节点 CIS → 网络(见下) → Tetragon/Falco → restic 备份。

⚠️ **第 9 层网络基本只到"可见性"**：集群内没有自建 `CiliumNetworkPolicy`，唯一自建的网络管控
是 readlist 两个短命 Job 的 `readlist-{snapshot,score}-no-egress`（2026-08-05）；集群级默认拒绝
**刻意延后**，别当成已生效。逐层状态与灰度路径见 `docs/reference/security.md`。

**硬约束**: homelab 是 Ryzen 5600H 单节点热笔记本（空闲 ~60–62°C；功耗/散热细节与降温度抓手见 [reference/homelab-host-power-thermal.md](reference/homelab-host-power-thermal.md)）。所有安全组件 **fail-open + 控 CPU**。

## Storage Notes

- **NFS 已退役 (2026-07-11)**: 全部 PVC 用 `local-path`; 106 只做冷备份目标, 不再是运行时依赖
- **sqlite 应用必须用 `local-path`**, 不用 NFS (fcntl 锁在 NFS 上极慢)
- **备份**: restic CronJob 直推 106 ZFS 加密仓库 (sftp), 双集群每夜; homelab 另有 PVE 每周 vzdump 整 VM → 106 `backups`
- **恢复验证**: 2026-07-06 演练通过 (Vault raft + 2 PG + sqlite)
- PVC 清单 / 迁移程序 / 备份设计细节 → `docs/reference/storage.md`
