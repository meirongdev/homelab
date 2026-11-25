# Homelab — Agent Context

> 双集群 homelab（homelab + oracle-k3s）基础设施即代码。根目录 `AGENTS.md`、`CLAUDE.md`、`.gemini.md`、
> `.github/copilot-instructions.md` 都软链到本文件。
> **本文件只放三类东西**：①一句话讲不清就会出事的陷阱 ②去哪查的指针 ③跨域硬约束。
> 细节、实测数值、事故经过都在 `docs/reference/`（唯一真相源，索引 [reference/README.md](reference/README.md)，
> 总门户 [docs/README.md](README.md)）；别往这里搬命令清单（`just --list`）和目录树（`ls`）。

## Project Structure

```
proxmox/{terraform,terraform-storage,ansible}/  # pve 上的 VM · 106 上的 worker VM · 两台宿主机
k8s/{ansible,cilium,helm}/     # K3s 安装 · Cilium values(手动管理) · 应用部署(manifests/,values/=homelab)
cloud/oracle/                  # Oracle K3s (terraform|ansible|manifests|values|cloudflare)
argocd/                        # GitOps (install|projects|applications/)
cloudflare/terraform/          # Tunnel + DNS + WAF          tailscale/{terraform,ansible}/  # ACL · 节点 tailscale
zitadel/                       # 身份/SSO                     backup/               # restic (kustomize)
macbook/ansible/               # 无头M2+Studio · M5开发环境  images/               # 自研镜像(各一条 build workflow)
scripts/                       # just check 的检查器 · tf-r2.sh · 运维脚本
docs/                          # 见下方「Documentation Rules」
根 justfile · versions.just    # 根 justfile 聚合全部子 justfile；versions.just = 两集群共享的版本
```

## Key Commands

全部配方跑根目录 `just --list`；homelab 应用层的配方从根跑要加前缀（`just helm deploy-cilium` ≡ `cd k8s/helm && just deploy-cilium`）。**只列带坑的**：

| 命令 | 坑 |
|------|-----|
| `just deploy-argocd-apps` | ☠️ destination 未重写时，会把 homelab 全套负载装到 oracle |
| `just deploy-argocd` | ⚠️ 控制面在 oracle-k3s；本配方不含 Application 注册 |
| `just deploy-gateway-api-crds` | ⚠️ 升 Cilium 必跑（见下 Ingress 条）|
| `just connect-clustermesh <homelab-ts>:32379 <oracle-ts>:32379` | ☠️ 任一侧 deploy-cilium 后必跑 |

- **GitOps**：`git push` → ArgoCD 3 分钟轮询自动同步，**不可手动 `kubectl apply` 覆盖**。
  ⚠️ 例外是 manual-helm：Cilium / Vault / ESO / ArgoCD 本体，改 values 要手动 `helm upgrade`，提交≠部署。
- ⚠️ **新加子域名只写一个 HTTPRoute**（external-dns 建记录 + 隧道通配路由），不要改 `cloudflare/terraform`。
  → [networking-ingress.md](reference/networking-ingress.md)
- ⚠️ **`aiven/` 是外部托管的额外库，不是数据面**：不在集群、无 ArgoCD App、**不在 restic 备份面内**。
  应用数据只有集群内 `apps-pg` 一个家，往外挪要先立 ADR。→ [aiven/README.md](../aiven/README.md)

## Architecture Quick Reference

- **GitOps 控制面在 oracle-k3s**：`destination.server: kubernetes.default.svc` 指 **oracle**，homelab 负载必须写
  `https://100.94.186.7:6443`。Loki/Tempo 在 oracle，**Prometheus/Grafana/Alertmanager 在 homelab**。
  → [argocd-control-plane-on-oracle.md](runbooks/argocd-control-plane-on-oracle.md)
- **CNI** 双集群 Cilium eBPF + VXLAN，**Ingress** 只走 Cilium Gateway API。☠️ **Gateway API CRD 与 Cilium 版本是一对**：
  缺 CRD 时旧路由照常 200、新路由静默 503、无告警。升 Cilium 必跑 `just deploy-gateway-api-crds`；
  唯一可靠的验收是**新建一条 HTTPRoute 能拿到 `.status`**（operator 日志里出现 `Required GatewayAPI resources are not found`
  才是故障，grep 不到不代表健康）。→ [networking-ingress.md](reference/networking-ingress.md)
- **跨集群**：Tailscale 只做节点级 underlay，pod↔pod 走 ClusterMesh VXLAN。⚠️ 只有 node0 通告自己的 /32，
  k8s-node/worker 什么都不通告（会投毒路由）。→ [tailscale-network.md](reference/tailscale-network.md)
- **外部流量**：Internet → Cloudflare DNS → Tunnel → Cilium Gateway → Service
- ☠️ **`stack.meirong.dev` 不归本仓库**：它由 `home-stack` 仓库部署到 Cloudflare Workers，DNS 由 Cloudflare 自建。
  本仓库**既不许再声明、也不许当游离记录清理**。→ [home-stack-repo-boundary.md](decisions/home-stack-repo-boundary.md)
- **节点**：homelab 控制面 `k8s-node` `10.10.10.10` / TS `100.94.186.7`（5600H 笔记本）+ worker `k8s-worker-106`
  `192.168.50.107` / TS `100.74.162.97`（106 上的 VM）· oracle-k3s `10.0.0.26` / TS `100.107.166.37` ·
  NAS 106 宿主 `192.168.50.106` / TS `100.110.27.111`。⚠️ worker 与控制面不在同一网段且多一条 ip rule，
  改它先读 `k8s/ansible/playbooks/setup-k3s-worker.yaml` 文件头。oracle 重启后跑 `just oracle verify-node`。

**按域查细节（`docs/reference/`）**：术语 `terminology.md`（写文档/注释前对一眼）· 服务清单 `services.md` ·
☠️ LLM 网关 `litellm-gateway.md`（**虚拟 key 的模型白名单在 Postgres 不在 git**，改别名不同步改 key 就「Synced 但调用全挂」）·
GitOps/App `argocd-app-patterns.md` · 入口/DNS `networking-ingress.md` · 跨集群 `tailscale-network.md` · 存储/备份 `storage.md` ·
身份 `identity.md` · 安全 `security.md` · 可观测 `observability-multicluster.md` · 告警/SLO `observability-alerting-slo.md` ·
公网访问 `public-traffic-analysis.md` · 成本 `cost-and-rightsizing.md` · 资源/QoS `k8s-qos-resource-management.md` ·
TF state `terraform-state.md`（走 `just tf`）。

## Working Conventions

- `just` 是任务运行器 · Conventional Commits · Helm 配置进 `values/*.yaml` 不用 `--set` · SSH 全舰队用 `~/.ssh/vgio`。
- **新增服务**走 [runbooks/add-service.md](runbooks/add-service.md)；放哪个集群按
  [cluster-placement-for-new-services.md](decisions/cluster-placement-for-new-services.md)（计算密集 / 大流量 / 只有 amd64 → homelab，
  轻量无状态 → oracle）。⚠️ 两边都不宽裕，requests 按实测填，别照搬上游。
- 新服务的硬性要求（错了通常静默失效）：arm64 先确认镜像有 `linux/arm64` 并钉**多架构 index digest** ·
  同 ns 后端**不需要** ReferenceGrant（真跨 ns 才要，写 `v1beta1`）· 可写 PVC 一律 `local-path` ·
  oracle 密钥放 `secret/oracle-k3s/<service>` · 非核心挂 `priorityClassName: bulk`。
- ⚠️ **判断内存余量看 `free -m` 的 available 或 `rssBytes`，别信 `kubectl top node`**（requests 只是申报）。
  → [k8s-qos-resource-management.md](reference/k8s-qos-resource-management.md)

## Documentation Rules

写文档前读 [docs/RULES.md](RULES.md)（R1–R8，CI 的 `check-docs.py` 强制，含链接锚点与 `just` 配方存在性）。最常踩的三条：

- 架构事实进 `reference/`（唯一真相源）· 决策进 `decisions/` · 可重复 SOP 进 `runbooks/` · 故障复盘进 `records/`。
- `plans/` 只放没做完的方案，**做完即删**：先把结论回写 reference/decisions、`git grep` 改掉指向它的链接，再删。
- 命令必须可执行；过期内容挪走有用部分后删除，不留 `Deprecated` 墓碑。

## Manifest Safety (CI 强制)

☠️ **删任何清单文件前先 `grep '^kind:' <file>`**：ArgoCD 按目录同步，删文件会 prune 掉里面全部对象，内嵌的
`Namespace` 会连带删光同 ns 下别的应用的数据（PVC 的 `Prune=false` 拦不住）。反过来，退役服务时 PVC 不会自动删，得手工清。

`check-manifests.py` 强制 **H1** Namespace/CRD 独占文件 · **H2** Application 的 path/values 与 destination 同集群 ·
**H3** ReferenceGrant 用 `v1beta1` · **H4** 新增 PVC 必须有备份归属 · **H5** Namespace 显式写 PSA 等级。
`check-embedded-scripts.py` 的 **E1**：改了 ConfigMap 内嵌脚本的 `.py` 源，要在 `k8s/helm/` 跑 `just gen-embedded-scripts`。
细节与静态查不出的那几类 → [manifest-safety-checks.md](reference/manifest-safety-checks.md)；
搬有状态服务照 [stateful-service-cross-cluster-migration.md](runbooks/stateful-service-cross-cluster-migration.md)。

## Security Model

纵深防御 11 层（WAF → OIDC → Vault+ESO → PSA → Kyverno → Trivy → kube-bench → 节点 CIS → 网络 → Tetragon → restic），
逐层状态见 [security.md](reference/security.md)。

- ⚠️ **第 9 层网络只到「可见性」**：集群级默认拒绝刻意延后，别当已生效。oracle 的 IMDS CCNP 只拦
  `169.254.169.254:80`（☠️ 同址 `:53` 是 VCN DNS，整址封掉 = CoreDNS 转发断）。
- 🚫 **不提交密钥**（gitleaks 全量扫）：放 Vault，配方现取经 env 传入（范例 `just omlx`）。
- 🚫 **不提交公网 IP**（`check-public-ips.py`）：用 Tailscale 或内网地址；文档写 `<ORACLE_PUBLIC_IP>`，真值现取
  `cd cloud/oracle/terraform && just tf output -raw instance_public_ip`；第三方 anycast DNS 写行内 `public-ip-ok: <理由>`。
- **硬约束**：homelab 控制面是会发热的 5600H 笔记本（→ [homelab-host-power-thermal.md](reference/homelab-host-power-thermal.md)），
  所有安全组件 **fail-open + 控 CPU**。

## Storage Notes

- 应用数据一律 `local-path`，**sqlite 绝不能上 NFS**（fcntl 锁极慢）。唯一例外是 `media` ns 的只读媒体 NFS PV，
  挂在 106 上 → 106 宕机 = 少一个 worker 节点 + 媒体服务无数据。→ [multimedia-repository-nfs-readonly.md](decisions/multimedia-repository-nfs-readonly.md)
- **备份**：restic CronJob 推 106 ZFS 加密仓库，⚠️ **三个 Job**（homelab 控制面、homelab worker、oracle），
  且是**显式白名单**：新增有状态应用不加进去就静默不备份（H4 查的就是这个）。→ [storage.md](reference/storage.md)
