# Homelab — Agent Context

> 双集群 homelab（homelab + oracle-k3s）基础设施即代码。
> 给 AI 助手的**唯一上下文文件**：根目录 `AGENTS.md`、`CLAUDE.md`、`.gemini.md`、
> `.github/copilot-instructions.md` 全部软链到本文件。
>
> 📖 **需要细节时按域读 `docs/reference/`**（生效事实 + 踩坑记录，索引
> [reference/README.md](reference/README.md)；总门户 [docs/README.md](README.md)）。
>
> **本文件只放三类东西**：①一句话讲不清就会出事的**陷阱** ②**去哪查**的指针
> ③**跨域的硬约束**。不要往这里搬：命令清单（`just --list` 自带）、目录树（`ls` 自带）、
> 实测数值（会漂，且 reference/ 才是唯一真相源）。架构事实进 `reference/`，决策进 `decisions/`。

## Project Structure

```
proxmox/{terraform,ansible}/   # VM 预配 (Proxmox VE)
k8s/{ansible,cilium,helm}/     # K3s 安装 · Cilium values(手动管理) · 应用部署(values/,manifests/)
cloud/oracle/                  # Oracle Cloud K3s (terraform|ansible|manifests/)
argocd/                        # GitOps (install|projects|applications/)
cloudflare/terraform/          # Tunnel + DNS + WAF          tailscale/terraform/  # ACL + 预授权密钥
zitadel/                       # 身份/SSO                     backup/               # restic (kustomize)
macbook/ansible/               # 远程无头 M2 MacBook
docs/                          # 见下方「Documentation Rules」
```

## Key Commands

完整清单跑 `just --list`（执行目录 `k8s/helm/`，除非另有说明）。**这里只列带坑的**：

| 命令 | 坑 |
|------|-----|
| `just deploy-argocd-apps` | ☠️ destination 未重写时，会把 homelab 全套负载装到 oracle |
| `just deploy-argocd` | ⚠️ 控制面在 **oracle-k3s**；本配方不含 Application 注册 |
| `just deploy-gateway-api-crds` | ⚠️ 升 Cilium 必跑（见下 Ingress 条）|
| `just connect-clustermesh <homelab-ts>:32379 <oracle-ts>:32379` | 需两个端点参数 |
| `just init/plan/apply`（`proxmox/terraform/`）| **`just` 不是 `make`**，那里的 Makefile 是空文件 |
| `make init/plan/apply`（`cloud/oracle/terraform/`）| **唯一**用 `make` 的 terraform root |

- **GitOps**：`git push` → ArgoCD 3 分钟轮询自动同步，**不可手动 `kubectl apply` 覆盖**。
  LGTM/otel/external-dns/backup 全 GitOps。
- ⚠️ **manual-helm 的例外**（改 values 必须手动 `helm upgrade`，提交≠部署）：
  Cilium / Vault / ESO / ArgoCD 本体。
- ⚠️ **新加子域名不需要动 DNS**：写一个 HTTPRoute 即可（external-dns 建记录 + 隧道通配路由）。
  **不要**改 `cloudflare/terraform`。机制见 [networking-ingress.md](reference/networking-ingress.md)。

## Architecture Quick Reference

- **GitOps 控制面在 oracle-k3s**（2026-08-02 迁移）：Application 里的
  `destination.server: kubernetes.default.svc` 指的是 **oracle**；homelab 负载必须显式写
  `https://100.94.186.7:6443`。日志(Loki)/追踪(Tempo) 同批迁 oracle，**但
  Prometheus/Grafana/Alertmanager 仍在 homelab** —— 遥测不是单向的。
  → [runbooks/argocd-control-plane-on-oracle.md](runbooks/argocd-control-plane-on-oracle.md)
- **CNI**：双集群 Cilium eBPF + VXLAN。**Ingress**：Cilium Gateway API（唯一入口）。
  ☠️ **Gateway API CRD 版本与 Cilium 是一对**：缺 CRD 则 operator 的 Gateway API 控制器
  **整个不初始化**，而**旧路由照常 200、无任何告警**，只有新增路由静默 503。升 Cilium 必跑
  `just deploy-gateway-api-crds`，验收看 operator 日志有无 `Required GatewayAPI resources`，
  **别拿 curl 旧域名当证据**。→ [records/2026-08-11-gateway-api-crd-stall.md](records/2026-08-11-gateway-api-crd-stall.md)
- **跨集群**：Tailscale 只做**节点级 underlay**（各节点自己的 /32 + NodePort），pod↔pod 走
  ClusterMesh VXLAN。⚠️ `AdvertiseRoutes` 只该有本节点 /32（Pod CIDR 子网路由 2026-07-07 已移除）。
  → [tailscale-network.md](reference/tailscale-network.md)
- **外部流量**：Internet → Cloudflare DNS → Tunnel → Cilium Gateway → Service
- ☠️ **跨仓库边界（2026-08-23）**：`stack.meirong.dev` 不是本仓库的东西 —— 它是
  `~/projects/meirongdev/home-stack`（公开仓库）用**自己的** terraform 部到 Cloudflare
  Workers 的，那条 DNS 记录由 Cloudflare 自建、**不在本仓库 state 里**。本仓库
  **既不许再声明一份**（Workers 自定义域名不能建在已有 CNAME 的主机名上），
  **也不许当游离记录清理**（删掉 = 站点域名解析消失，且本仓库无线索）。反过来 zone
  设置/WAF/隧道/R2 桶本体归本仓库独占。完整归属表 →
  [decisions/home-stack-repo-boundary.md](decisions/home-stack-repo-boundary.md)
- **节点**：homelab 自 2026-08-13 起是**双节点**——control-plane `k8s-node` `10.10.10.10`
  / TS `100.94.186.7`（Ryzen 5600H 笔记本）+ worker `k8s-worker-106` `192.168.50.107` /
  TS `100.74.162.97`（跑在 NAS 106 上的 2c/4G VM）· oracle-k3s `10.0.0.26` / TS
  `100.107.166.37` · NAS storage-106 宿主 `192.168.50.106` / TS `100.110.27.111`
  ⚠️ worker 与控制面 **不在同一网段**（LAN vs pve 的 `10.10.10.0/24`），且它多一条
  ip rule。加/改它必读 `k8s/ansible/playbooks/setup-k3s-worker.yaml` 的文件头三条约束
  （[ADR](decisions/storage106-as-homelab-worker.md)）。
- **oracle 重启/改 shape 后**跑 `cd cloud/oracle && just verify-node`（只读核全部不变量；
  **别在文档里写死它报的条数**，那是动态累加的）。

**按域查细节（`docs/reference/`）**：**术语/命名正典 `terminology.md`（写文档或注释前先对
一眼）**· 服务清单 `services.md`（唯一真相源）· ☠️ **LLM 网关 `litellm-gateway.md`** —— 配置真相源分两半：
模型/路由在 git，**虚拟 key 的模型白名单在 Postgres**；改网关别名不同步改 key 就
「清单正确 + ArgoCD Synced + 调用全挂」，且用虚拟 key 查 `/v1/models` 会误判成配置没生效 ·
GitOps/App `argocd-app-patterns.md` · 入口/DNS `networking-ingress.md` · 跨集群 `tailscale-network.md` ·
存储/备份 `storage.md` · 身份/OIDC `identity.md` · 安全逐层 `security.md` · 可观测
`observability-multicluster.md` + `observability-otel-logging.md` · 告警/SLO
`observability-alerting-slo.md` · **公网访问分析（谁在访问、真人/爬虫/自建监控）**
`public-traffic-analysis.md` · 成本 `cost-and-rightsizing.md` · 资源/QoS
`k8s-qos-resource-management.md`。

## Working Conventions

- **任务运行器** `just`（唯一例外 `cloud/oracle/terraform/` 用 `make`）·
  **Commits** Conventional Commits · **Helm** 配置进 `values/*.yaml`，不用内联 `--set` ·
  **SSH** 全舰队 key `~/.ssh/vgio`。
- **新增服务**走 skill `.claude/skills/add-service/SKILL.md`（manifest → HTTPRoute → homepage →
  Uptime Kuma 全流程）。**落点按资源画像选**，判据与实测容量见
  [cluster-placement-for-new-services.md](decisions/cluster-placement-for-new-services.md)：
  计算密集 / 大流量公共服务 / 只有 amd64 镜像 → **homelab**；轻量无状态 → **oracle-k3s**。
  ⚠️ 两边都不宽裕，**别照搬上游 manifest 的 requests**，按实测填。
- 新服务的硬性要求（错了通常静默失效）：⚠️ arm64 先确认镜像有 `linux/arm64`，pin
  **多架构 index digest** 不是单架构的 · 跨 ns 引用要 ReferenceGrant（清单写 **`v1beta1`**，
  理由见 H3）· 可写 PVC 一律 `local-path`（唯一例外是只读媒体的静态 NFS PV，见 Storage
  Notes）· oracle 密钥放 `secret/oracle-k3s/<service>` ·
  非核心挂 `priorityClassName: bulk`。
- ⚠️ **判断内存余量看 `free -m` 的 available 或 `rssBytes`，别信 `kubectl top node`**；
  requests 只反映申报、不反映实占（两者可差数百 Mi）。→ [k8s-qos-resource-management.md](reference/k8s-qos-resource-management.md)

## Documentation Rules

写文档前读 [docs/RULES.md](RULES.md) 的 **R1–R7**（目录归属/命名/文首字段/状态枚举/索引维护/
唯一真相源），CI 的 `check-docs.py` 强制。放错目录、漏建索引都算违规。最常踩的三条：

- **架构事实**进 `reference/`（唯一真相源），别在 plan 里留唯一副本；
  **决策**进 `decisions/`；**可重复 SOP** 进 `runbooks/`；**故障复盘**进 `records/`。
- `plans/` 是**写完即冻结的历史快照，不代表现状**——查现状永远看 `reference/`。
  被取代时**不删文件**，标状态 + 链到取代者。
- 命令步骤必须可执行，避免思路型描述；过期内容标 `Deprecated` 并链到替代文档。

## Manifest Safety (CI 强制)

☠️ **删任何清单文件前先 `grep '^kind:' <file>`** —— ArgoCD 按目录同步，删文件 = prune 掉
文件里的**全部**对象；内嵌的 `Namespace` 会连带删光同 ns 下**其它应用**的数据
（PVC 的 `Prune=false` 拦不住，被 prune 的是 ns）。2026-08-03 真这样删过一次。
⚠️ 反过来也要记得：`Prune=false` 意味着**退役服务时 PVC 不会被删**，得手工清。

`scripts/check-manifests.py` 强制 5 条**由真实事故反推**的规则：**H1** Namespace/CRD 独占文件 ·
**H2** Application 的 `path` 与 `destination` 同集群 · **H3** ReferenceGrant 声明 `v1beta1` ·
**H4** 新增 PVC 必须有备份归属 · **H5** Namespace 必须显式写 PSA 等级（漏写 = 静默吃默认
`privileged`）。另有 `scripts/check-embedded-scripts.py` 的 **E1**：ConfigMap 内嵌的脚本必须与
同目录的 `.py` 源一致，且 pod 模板带它的 checksum 注解 —— 改了 `.py` 就得在 `k8s/helm/` 跑
`just gen-embedded-scripts`，否则要么部署的是旧副本、要么 ConfigMap 变了 **pod 根本不重启**。
规则全文 + **静态查不出、只能靠人的那几类** →
[manifest-safety-checks.md](reference/manifest-safety-checks.md)。
搬有状态服务照 [runbooks/stateful-service-cross-cluster-migration.md](runbooks/stateful-service-cross-cluster-migration.md) 走。

## Security Model

纵深防御 11 层：Cloudflare WAF → ZITADEL OIDC → Vault+ESO → PSA → Kyverno → Trivy →
kube-bench → 节点 CIS → 网络 → Tetragon/Falco → restic。逐层状态与灰度路径见
[security.md](reference/security.md)。

- ⚠️ **第 9 层网络基本只到「可见性」**：集群内没有自建 `CiliumNetworkPolicy`（唯一例外是
  readlist 两个短命 Job 的 no-egress）；集群级默认拒绝**刻意延后**，别当成已生效。
- 🚫 **不提交任何公网 IP**（CI 强制 `check-public-ips.py`，全量跑）。节点一律用 Tailscale
  （`100.64/10`）或内网地址；文档写 `<ORACLE_PUBLIC_IP>` 占位符，真值现取
  `cd cloud/oracle/terraform && terraform output -raw instance_public_ip`。
  只放行第三方 anycast DNS，豁免写行内 `public-ip-ok: <理由>`。
- **硬约束**：homelab 控制面 `k8s-node` 是 Ryzen 5600H 热笔记本（空闲 ~60–62°C，抬温有实际代价 →
  [homelab-host-power-thermal.md](reference/homelab-host-power-thermal.md)）——2026-08-13 起
  集群另有 worker `k8s-worker-106`，但热约束与安全组件仍以控制面为准。
  所有安全组件 **fail-open + 控 CPU**。

## Storage Notes

- **NFS 退役只覆盖读写型 PVC（2026-07-11）**：应用自己的数据一律 `local-path`，
  **sqlite 应用尤其不能用 NFS**（fcntl 锁极慢）。
  ⚠️ **但 106 已不再是"非运行时依赖"**：2026-08-16 起 `media` ns 的 5 个**只读** NFS PV
  （`media-{movie,tv,anime,music,podcast}`）挂 106 的 ZFS，且 worker `k8s-worker-106`
  本身就是跑在 106 上的 VM —— **106 宕机 = 少一个节点 + 三个媒体服务无数据**，不再是
  "只暂停备份窗口"。媒体是大文件顺序读，不踩 sqlite 那个锁坑。
  这个例外的边界（只读 / 只媒体 / 不装 provisioner）→ [multimedia-repository-nfs-readonly.md](decisions/multimedia-repository-nfs-readonly.md)。
- **备份**：restic CronJob 直推 106 ZFS 加密仓库（sftp）。⚠️ **是三个 Job 不是两个**：
  homelab 控制面 03:00（`--host homelab`）· homelab worker 02:00（`--host homelab-worker`，
  2026-08-16 新增，控制面那份读不到 worker 的 hostPath）· oracle 03:30。
  两台 VM 另有 PVE 周备（k8s-node 在 pve、worker 在 106）。
  ⚠️ 备份是**显式白名单**，新增有状态应用不加进去就静默不备份（H4 查的就是这个）。
- 恢复演练 2026-07-06 通过。PVC 清单 / 迁移程序 / 备份设计 → [storage.md](reference/storage.md)。
