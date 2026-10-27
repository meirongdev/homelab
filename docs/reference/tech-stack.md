# Tech Stack — 技术栈全景

> Last updated: 2026-10-28
> Status: 生效事实
>
> 这套系统由哪些技术组成、每个是干什么的、为什么是它、配置和版本钉在哪。
> 版本号、服务清单和实测数值各有真相源，本页只写「去哪查」
> （[§6 真相源地图](#6-真相源地图配置和版本钉在哪)），细节在每行链接的文档里。
>
> 第一次读这个仓库：按 [docs/README.md 的学习路径](../README.md#学习路径) 走，本页是第 2 站。

## 1. 一分钟版：一个请求是怎么被服务的

```
浏览器
  │  https://<name>.meirong.dev
  ▼
Cloudflare DNS ──── 记录由 external-dns 按 HTTPRoute 自动建（不手写 DNS）
  │                 WAF / 限流 / TLS 在这里终结（集群内是明文 HTTP）
  ▼
Cloudflare Tunnel ── 集群零公网入站端口；cloudflared 从集群内主动外连
  │
  ▼
Cilium Gateway API ── 集群内唯一 HTTP 入口，按 HTTPRoute 分流
  │
  ▼
Service → Pod ────── 网络由 Cilium eBPF 承载；跨集群走 ClusterMesh over Tailscale
```

| 后台链路 | 一句话 |
|------|--------|
| 部署 | `git push` → ArgoCD 轮询 → 同步到两个集群（Git 是唯一部署入口，不手动 `kubectl apply`） |
| 密钥 | Vault 存 → ESO 拉成 Secret → Pod 挂载（Git 里没有明文密钥） |
| 观测 | 应用 stdout → OTel Collector → Loki（日志）/ Prometheus（指标）/ Tempo（追踪）→ Grafana |

## 2. 为什么是这些技术：五条贯穿全局的取舍

| 约束 | 后果 |
|------|------|
| **单人运维，没有 on-call** | 以「静默失败可被发现」为准，不以功能多为准；所以[故障复盘](../records/README.md)比功能文档多 |
| **控制面是一台热笔记本（Ryzen 5600H）** | 安全组件一律 fail-open + 限 CPU → [homelab-host-power-thermal.md](homelab-host-power-thermal.md) |
| **oracle 是 Free Tier ARM，两边都不宽裕** | 不照搬上游 `requests`；新服务落哪有判据 → [cluster-placement-for-new-services.md](../decisions/cluster-placement-for-new-services.md) |
| **威胁模型是「单用户 + 公网暴露面」** | 边缘和身份做厚（WAF/OIDC/Vault），集群内横向移动的管控刻意延后 → [security.md](security.md) |
| **运维负担算进选型成本** | 很多东西故意不装，见 [§5](#5-故意没有的东西) |

## 3. 分层清单

每行：它解决什么问题；在这里与照教程装不同的地方（多半是踩过的坑）→ 深读。

### 3.1 硬件与宿主

| 组件 | 是什么 · 在这里的特殊之处 |
|------|------|
| **Proxmox VE** | 裸机上跑虚拟机。跑在笔记本 `pve` 上，VM 由 Terraform 声明 |
| **storage-106** | NAS，ZFS raidz1 + sanoid 快照。☠️ 不只是备份目标：还是 worker VM 的宿主和媒体只读 NFS 源 → [storage.md](storage.md) |
| **Oracle Cloud Free Tier** | 永久免费的 ARM（Ampere A1）云主机，承载对外服务面。shape 缩容不可逆 → [runbook](../runbooks/oracle-k3s-shape-downsize.md) |
| **Mac M2 / Mac Studio / DGX Spark** | 本地推理算力，不是集群节点，LiteLLM 按 Tailscale IP 直连 → [litellm-gateway.md](litellm-gateway.md) · [为何不接 ClusterMesh](../decisions/dgx-clustermesh-not-adopted.md) |

### 3.2 预配（把机器变成节点）

| 组件 | 是什么 · 在这里的特殊之处 |
|------|------|
| **Terraform** | 声明式管理 VM、DNS、Tunnel、Tailscale ACL。多个独立 root（`find . -name '*.tf'` 现查），互不共享 state；state 在本地，迁 R2 是开放项 |
| **Ansible** | 管理机器内部（K3s、内核参数、Tailscale）。Terraform 造壳，Ansible 装内容 |
| **just** | 任务运行器。根 `justfile` 用 `mod` 聚合子 justfile，文档不抄命令表 |

### 3.3 集群运行时

| 组件 | 是什么 · 在这里的特殊之处 |
|------|------|
| **K3s** | 单二进制的轻量 Kubernetes 发行版。☠️ apiserver 与 kubelet 同进程，kubelet 的 `/metrics` 重复暴露 apiserver 指标 → [ADR](../decisions/prometheus-series-reduction.md) |
| **containerd** | 容器运行时。镜像 GC 阈值是 85% 磁盘，低于此不触发，迁走负载后镜像不会自己消失 |

两个集群：`homelab`（控制面 `k8s-node` + worker `k8s-worker-106`）与 `oracle-k3s`（单节点）。
⚠️ 同一个集群在不同层有不同的官方名（context `k3s-homelab`，Cilium/ArgoCD/指标层叫 `homelab`）→ [terminology.md](terminology.md)。

### 3.4 网络

南北向 [networking-ingress.md](networking-ingress.md) · 东西向 [tailscale-network.md](tailscale-network.md)。

| 组件 | 是什么 · 在这里的特殊之处 |
|------|------|
| **Cilium** | eBPF CNI：Pod 网络、Service 负载均衡、Hubble 可观测。双集群统一 → [ADR](../decisions/cilium-as-cni.md)。☠️ 不要显式设 MTU（不扣隧道开销，大包静默黑洞） |
| **Gateway API** | Ingress 的继任者，`Gateway` 与 `HTTPRoute` 分离。Cilium 直接做控制器，不装 Traefik/nginx → [ADR](../decisions/gateway-controller-evaluation.md)。☠️ CRD 版本与 Cilium 是一对，缺 CRD 时新路由静默 503 → [record](../records/2026-08-11-gateway-api-crd-stall.md) |
| **Cilium ClusterMesh** | 两个集群的 Pod 直接互通、跨集群 Service 发现。跑在 Tailscale 之上；重建任一集群后必须重跑 `just connect-clustermesh` |
| **Tailscale** | 基于 WireGuard 的组网。只做节点级 underlay（各节点自己的 /32 + NodePort），Pod↔Pod 交给 ClusterMesh。☠️ 广播别人该送达的网段会路由投毒 |
| **Cloudflare Tunnel + DNS + WAF** | 不开公网端口地发布服务。TLS 在边缘终结，所以集群内不需要 Cert-Manager |
| **external-dns** | 按集群内资源增删 DNS 记录。⚠️ 新增子域名只写一个 HTTPRoute，不碰 `cloudflare/terraform` → [ADR](../decisions/external-dns-adoption.md) |

### 3.5 交付（GitOps）

| 组件 | 是什么 · 在这里的特殊之处 |
|------|------|
| **ArgoCD** | 把集群收敛到 Git 声明的状态。☠️ 控制面在 oracle-k3s，`kubernetes.default.svc` 指 oracle，homelab 负载必须显式写 Tailscale 地址 → [runbook](../runbooks/argocd-control-plane-on-oracle.md) |
| **App-of-Apps** | 用一个 Application 管住其它 Application。`root.yaml` watch `argocd/applications/`，加应用 = 加一个 YAML 再 push |
| **AppProject** | ArgoCD 的权限边界。每集群一个（`homelab` / `oracle-k3s`），destination 写错由服务端拒绝 → [ADR](../decisions/argocd-project-per-cluster.md) |
| **Helm** | 消费上游 chart。自研应用不打 chart → [ADR](../decisions/no-helm-chart-for-in-house-apps.md) |
| **Kustomize / 目录源** | 不模板化地组织自己的 YAML。一个 App 一个目录，放进去就纳入同步 → [ADR](../decisions/manifests-directory-per-app.md) |

⚠️ manual-helm 四件套不走 ArgoCD：Cilium / Vault / ESO / ArgoCD 本体，改 values 后必须手动 `helm upgrade`（提交 ≠ 部署）。
它们要么是 ArgoCD 自己的依赖，要么改坏了会让 GitOps 失去自愈能力。

### 3.6 密钥与身份

| 组件 | 是什么 · 在这里的特殊之处 |
|------|------|
| **HashiCorp Vault** | 集中存密钥，带版本与审计。单实例（刻意不做 HA）；oracle 跨 Tailscale 读它 |
| **External Secrets Operator (ESO)** | 把外部密钥库同步成 K8s Secret。两集群各装一份，版本刻意不耦合；`ExternalSecret` 是 Git 里唯一提到密钥的地方 |
| **ZITADEL** | 自托管 IdP（OIDC/OAuth2），库是 CNPG 独立实例。应用走原生 OIDC，不做入口层统一 SSO → [ADR](../decisions/app-native-oidc-sso.md) · [identity.md](identity.md) |
| **oauth2-proxy** | 给不会 OIDC 的应用套一层。只作兜底，per-app 部署 → [identity.md](identity.md) |

### 3.7 数据与备份

| 组件 | 是什么 · 在这里的特殊之处 |
|------|------|
| **local-path** | K3s 自带的本地盘 PV。可写卷一律用它；☠️ sqlite 应用尤其不能放 NFS（fcntl 锁极慢） |
| **NFS（只读）** | 挂 106 的 ZFS 媒体库。NFS 退役后的唯一例外：只读 + 只媒体 + 不装 provisioner → [ADR](../decisions/multimedia-repository-nfs-readonly.md) |
| **CloudNativePG (CNPG)** | 用 CR 声明式管理 PostgreSQL。只在 oracle 装；homelab 的共享 Postgres 是裸 Deployment，刻意不装 operator → [ADR](../decisions/shared-postgres-platform.md) |
| **Aiven free tier** | 外部托管的 PostgreSQL（`aiven/terraform`）。额外小库，不在任何集群里、不在 restic 备份面内，不是 `apps-pg` 的替代品；计划名 `free-1-1gb` 等坑 → [aiven/README.md](../../aiven/README.md) |
| **restic** | 去重加密备份。CronJob 直推 106 的 sftp 仓库；⚠️ 三个 Job，且是显式白名单（不加进去就静默不备份，CI 的 H4 查这个）→ [storage.md](storage.md) |
| **ZFS + sanoid** | 备份目标端的快照与完整性。restic 仓库本身也在快照里 |

### 3.8 可观测

☠️ 遥测是双向的：指标面在 homelab，日志与追踪面在 oracle → [observability-multicluster.md](observability-multicluster.md)。

| 组件 | 是什么 · 在这里的特殊之处 |
|------|------|
| **Prometheus / Grafana** | 指标存储 + PromQL / 看板。都在 homelab；Grafana 跨集群查 oracle 的 Loki/Tempo |
| **Alertmanager** | 告警去重/路由/静默。投递 Telegram（原生 `telegramConfigs`）→ [ADR](../decisions/alerting-telegram-migration.md) |
| **Loki / Tempo** | 日志（按标签索引）/ 追踪存储。☠️ 都在 oracle；⚠️ Tempo 写入口与查询口是两个端口 |
| **OpenTelemetry Collector** | 统一采集并转发日志/指标/追踪。DaemonSet；应用接入有 4 种模式（含只写文件不写 stdout 的） |
| **Sloth** | 用 CR 生成 SLO 规则。☠️ `errorQuery` 必须 `OR on() vector(0)`，否则空集让 SLO 变 NaN → [record](../records/2026-08-12-slo-nan-poisoning.md) |
| **OpenCost / KRR** | 成本归因 / 右尺寸建议。都因同一个 cAdvisor 缺口需要旁路采集 → [ADR](../decisions/opencost-krr-data-sources.md) |
| **Uptime Kuma** | 外部视角的可用性探测。兼任 dead man's switch 接收端，唯一不与被监控方共命运的告警 → [dead-mans-switch.md](dead-mans-switch.md) |

### 3.9 安全

11 层的完整状态表在 [security.md](security.md)，这里只列每层用什么：

| 组件 | 是什么 · 在这里的特殊之处 |
|------|------|
| **Pod Security Admission (PSA)** | 内置 Pod 安全基线。⚠️ Namespace 必须显式写等级，漏写静默吃 `privileged`（CI 的 H5） |
| **Kyverno** | 策略即代码。只在 homelab |
| **Trivy Operator** | 持续扫镜像 CVE 与配置。两集群都有；☠️ 五类静默失败 → [trivy-cve-ops.md](trivy-cve-ops.md) |
| **kube-bench** | CIS 基线自查，CronJob 定期跑 |
| **Tetragon / Falco** | eBPF 运行时检测。两集群分别选型：Tetragon 在 homelab，Falco + Falcosidekick 在 oracle；⚠️ 规则误报会吃掉整条通道 |
| **Hubble** | Cilium 的网络流可见性。⚠️ 第 9 层只到可见性：没有自建 `CiliumNetworkPolicy`，默认拒绝刻意延后 |

### 3.10 仓库工程（CI 与护栏）

`just check` 在本地跑与 CI 同款的 6 个检查器，每条都由一次真实事故反推：
`check-manifests.py`（H1–H5）· `check-docs.py`（文档规则）· `check-terminology.py`（T1–T4）·
`check-public-ips.py` · `check-version-pairs.py`（V1–V4，必须同步升级的版本对）·
`check-embedded-scripts.py`（E1）。逐个说明见 [scripts/README.md](../../scripts/README.md)，
清单规则全文 [manifest-safety-checks.md](manifest-safety-checks.md)。

☠️ 删任何清单文件前先 `grep '^kind:' <file>`：内嵌的 `Namespace` 被 prune 会连带删光同 ns 的数据
→ [record](../records/2026-08-03-namespace-prune-cascade.md)。

## 4. 两个集群的分工

| | homelab | oracle-k3s |
|---|---------|------------|
| 定位 | 指标中枢 + 密钥 + 本地模型接入 | 公网服务面 + GitOps 控制面 + 日志/追踪 + 身份面 |
| 拿得动什么 | 计算密集、大流量、只有 amd64 镜像的 | 轻量无状态；ARM64，镜像必须有 `linux/arm64` |
| GitOps 角色 | spoke（被纳管） | hub（控制面在此） |

完整对比 [../ARCHITECTURE.md](../ARCHITECTURE.md)；新服务放哪 [cluster-placement-for-new-services.md](../decisions/cluster-placement-for-new-services.md)。

## 5. 故意没有的东西

Cert-Manager（TLS 在边缘终结）· Crossplane · Vault HA · Thanos/Mimir · 镜像自动升级 ·
集群级网络默认拒绝（延后不是取消）。理由与重评条件在 [ROADMAP.md「不做 / 已取消」](../ROADMAP.md#不做--已取消)。

## 6. 真相源地图（配置和版本钉在哪）

改东西前先在这里定位。本页不复制具体数值，复制就会漂。

| 想改/想查 | 唯一位置 |
|-----------|---------|
| 跑着哪些服务、在哪个集群/ns/域名 | [services.md](services.md) |
| 术语与集群命名 | [terminology.md](terminology.md) |
| Cilium 与 Gateway API CRD 版本（一对，必须同步） | 根 `versions.just` |
| 上游 chart 版本 | `argocd/applications/<app>.yaml` 的 `targetRevision` |
| manual-helm 四件套的版本钉 | `k8s/helm/justfile` · `cloud/oracle/justfile` |
| Helm values | `k8s/helm/values/`（homelab）· `cloud/oracle/values/`（oracle） |
| 自研应用清单 | `k8s/helm/manifests/<app>/` · `cloud/oracle/manifests/<app>/` |
| 有哪些 Application（数量会变） | `ls argocd/applications/*.yaml` |
| 资源 requests/limits | values 文件与集群本身；文档只写原则与判据 |
| 命令清单 | `just --list` |
| 密钥 | Vault（`secret/homelab/*` · `secret/oracle-k3s/*`），Git 里只有 `ExternalSecret` |

⚠️ LiteLLM 网关的真相源是分裂的：模型/路由在 Git，虚拟 key 的模型白名单在 Postgres。
改别名不同步改 key 就是「清单正确 + ArgoCD Synced + 调用全挂」→ [litellm-gateway.md](litellm-gateway.md)。

## 7. 接下来读什么

整体拓扑 [ARCHITECTURE.md](../ARCHITECTURE.md) · 上手改仓库 [AGENTS.md](../AGENTS.md)（命令、约定、硬约束）·
加新服务 [add-service.md](../runbooks/add-service.md) · 深入某一层 [reference/ 索引](README.md) ·
为什么不是另一种做法 [decisions/ 索引](../decisions/README.md) ·
这套系统怎么坏过 [records/ 索引](../records/README.md)（多数「为什么这么规定」的答案在这里）。
