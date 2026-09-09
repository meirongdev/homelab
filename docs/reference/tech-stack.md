# Tech Stack — 技术栈全景

> Last updated: 2026-09-09
> Status: 生效事实
>
> 这套系统由哪些技术组成、每个是干什么的、为什么是它、配置和版本钉在哪。
>
> 这里刻意不复制版本号、服务清单和实测数值：那些各有真相源
> （见 [§6 真相源地图](#6-真相源地图配置和版本钉在哪)），本页只写「去哪查」。
> 细节在表格「深读」列指向的文档里。
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

配套的三条「后台链路」：

| 链路 | 一句话 |
|------|--------|
| 部署 | `git push` → ArgoCD 轮询 → 同步到两个集群（**Git 是唯一部署入口**，不手动 `kubectl apply`） |
| 密钥 | Vault 存 → ESO 拉成 Secret → Pod 挂载（**Git 里没有明文密钥**） |
| 观测 | 应用 stdout → OTel Collector → Loki（日志）/ Prometheus（指标）/ Tempo（追踪）→ Grafana |

## 2. 为什么是这些技术：五条贯穿全局的取舍

下面每一层的选型，多数能追回到这五条里的一条或几条：

| 约束 | 后果 |
|------|------|
| **单人运维，没有 on-call 轮值** | 一切以「静默失败可被发现」为准，而不是以功能多为准。故障复盘（[records/](../records/README.md)）比功能文档多得多，就是这个原因 |
| **控制面是一台热笔记本（Ryzen 5600H）** | 安全组件一律 fail-open + 限 CPU；抬温有真实代价 → [homelab-host-power-thermal.md](homelab-host-power-thermal.md) |
| **oracle 侧是 Free Tier ARM，两边都不宽裕** | 不照搬上游 `requests`；新服务落哪个集群有明确判据 → [cluster-placement-for-new-services.md](../decisions/cluster-placement-for-new-services.md) |
| **威胁模型是「单用户 + 公网暴露面」** | 边缘和身份做厚（WAF/OIDC/Vault），集群内横向移动的管控刻意延后 → [security.md](security.md) |
| **运维负担算在选型成本里** | 大量东西是**故意不装**的（Cert-Manager、Crossplane、Vault HA、Thanos/Mimir…），理由逐条记在 [ROADMAP.md 的「不做 / 已取消」](../ROADMAP.md#不做--已取消) |

## 3. 分层清单

每行的读法：**组件 → 它解决什么问题（给没用过的人）→ 在这套系统里的特殊之处 → 深读**。
「特殊之处」列写的是与照教程装一遍不同的地方，也就是踩过坑的地方。

### 3.1 硬件与宿主

| 组件 | 解决什么问题 | 在这里的特殊之处 |
|------|-------------|-----------------|
| **Proxmox VE** | 裸机上跑虚拟机的开源 hypervisor | 跑在一台笔记本上（`pve`）；VM 由 Terraform 声明，不在 Web UI 点 |
| **storage-106** | Celeron/8G 的 NAS，ZFS raidz1 + sanoid 快照 | ☠️ 它**不再是纯冷备份目标**：同时是 worker VM 的宿主 + 媒体只读 NFS 源，宕机会拿走一个节点和三个服务 → [storage.md](storage.md) |
| **Oracle Cloud Free Tier** | 永久免费的 ARM（Ampere A1）云主机 | 承载对外服务面；shape 缩容**不可逆** → [oracle-k3s-shape-downsize.md](../runbooks/oracle-k3s-shape-downsize.md) |
| **Mac M2 / DGX Spark** | 本地推理算力 | 不是集群节点，以 Service + 手写 Endpoints 接入 → [dgx-clustermesh-not-adopted.md](../decisions/dgx-clustermesh-not-adopted.md) |

### 3.2 预配（把机器变成节点）

| 组件 | 解决什么问题 | 在这里的特殊之处 |
|------|-------------|-----------------|
| **Terraform** | 声明式管理基础设施（VM、DNS、Tunnel、Tailscale ACL） | 按管辖对象分散成多个独立 root（`find . -name '*.tf'` 看当前有哪些），彼此不共享 state；state 目前在本地，迁 R2 是开放项 |
| **Ansible** | 声明式管理**机器内部**（装 K3s、内核参数、Tailscale） | Terraform 造壳，Ansible 装内容，边界清楚 |
| **just** | 任务运行器（比 Makefile 简单的命令入口） | 根 `justfile` 用 `mod` 聚合各子目录的 justfile，`just --list` 是命令的唯一清单，文档里不抄命令表 |

### 3.3 集群运行时

| 组件 | 解决什么问题 | 在这里的特殊之处 |
|------|-------------|-----------------|
| **K3s** | 单二进制的轻量 Kubernetes 发行版 | ☠️ 它把 apiserver/etcd/controller 合进一个进程，导致 kubelet **重复暴露**同一批指标（占该 job 80% series）→ [prometheus-series-reduction.md](../decisions/prometheus-series-reduction.md) |
| **containerd** | 容器运行时 | 镜像 GC 阈值是 **85% 磁盘**，低于此永不触发 —— 迁走工作负载后镜像不会自己消失 |

两个集群：`homelab`（控制面 `k8s-node` + worker `k8s-worker-106`，2026-08-13 起双节点）与
`oracle-k3s`。⚠️ 同一个集群在不同层有不同的官方名（kubectl context 是 `k3s-homelab`，
Cilium/ArgoCD/指标那层叫 `homelab`）→ 命名正典见 [terminology.md](terminology.md)。

### 3.4 网络

| 组件 | 解决什么问题 | 在这里的特殊之处 |
|------|-------------|-----------------|
| **Cilium** | 基于 eBPF 的 CNI：Pod 网络、Service 负载均衡、可观测（Hubble） | 双集群统一，从 Flannel 迁入 → [cilium-as-cni.md](../decisions/cilium-as-cni.md)。☠️ **不要显式设 MTU**（显式值不扣隧道开销 → 大包静默黑洞） |
| **Gateway API** | Ingress 的继任者：`Gateway`（入口）+ `HTTPRoute`（路由）分离 | Cilium 直接做 Gateway 控制器，不装 Traefik/nginx → [gateway-controller-evaluation.md](../decisions/gateway-controller-evaluation.md)。☠️ **CRD 版本与 Cilium 是一对**，缺 CRD 会让新路由静默 503 而旧路由照常 200 → [2026-08-11-gateway-api-crd-stall.md](../records/2026-08-11-gateway-api-crd-stall.md) |
| **Cilium ClusterMesh** | 让两个集群的 Pod 直接互通（跨集群 Service 发现） | 跑在 Tailscale 之上；重建任一集群后必须重跑 `just connect-clustermesh` |
| **Tailscale** | 基于 WireGuard 的零配置组网 | **只做节点级 underlay**（各节点自己的 /32 + NodePort），Pod↔Pod 交给 ClusterMesh。☠️ 广播「本该由别人送达的网段」会造成路由投毒 → [tailscale-network.md](tailscale-network.md) |
| **Cloudflare Tunnel + DNS + WAF** | 不开放公网端口的前提下把服务发布到互联网 | 集群零入站端口；TLS 在边缘终结，所以**集群内不需要 Cert-Manager** |
| **external-dns** | 按集群内资源自动增删 DNS 记录 | ⚠️ **新增子域名只写一个 HTTPRoute**，不要碰 `cloudflare/terraform` → [external-dns-adoption.md](../decisions/external-dns-adoption.md) |

深读入口：南北向 [networking-ingress.md](networking-ingress.md) · 东西向 [tailscale-network.md](tailscale-network.md)。

### 3.5 交付（GitOps）

| 组件 | 解决什么问题 | 在这里的特殊之处 |
|------|-------------|-----------------|
| **ArgoCD** | 持续把集群状态收敛到 Git 声明的状态 | ☠️ 控制面在 **oracle-k3s**，所以 Application 里的 `kubernetes.default.svc` 指的是 oracle，homelab 负载必须显式写 Tailscale 地址 → [argocd-control-plane-on-oracle.md](../runbooks/argocd-control-plane-on-oracle.md) |
| **App-of-Apps** | 用一个 Application 管住其它 Application | `root.yaml` watch `argocd/applications/`，加应用 = 加一个 YAML 再 push |
| **AppProject** | ArgoCD 的权限边界 | 每集群一个（`homelab` / `oracle-k3s`），写错 destination 由服务端拒绝 → [argocd-project-per-cluster.md](../decisions/argocd-project-per-cluster.md) |
| **Helm** | 消费上游 chart（values 覆盖默认值） | 只用来消费上游；**自研应用不打 chart** → [no-helm-chart-for-in-house-apps.md](../decisions/no-helm-chart-for-in-house-apps.md) |
| **Kustomize / 目录源** | 不模板化地组织自己的 YAML | 一个 App 一个目录，目录即清单，放进去就纳入同步 → [manifests-directory-per-app.md](../decisions/manifests-directory-per-app.md) |
| **Renovate** | 自动开 PR 升级钉住的版本 | 🚧 配置与 CI 已合入，**GitHub App 还没装**，当前无任何自动升级 → [renovate-adoption.md](../decisions/renovate-adoption.md) |

⚠️ **四个例外不走 ArgoCD**（改 values 后必须手动 `helm upgrade`，**提交 ≠ 部署**）：
Cilium / Vault / ESO / ArgoCD 本体。理由是它们要么是 ArgoCD 自己的依赖，要么改坏了会让 GitOps 失去自愈能力。

### 3.6 密钥与身份

| 组件 | 解决什么问题 | 在这里的特殊之处 |
|------|-------------|-----------------|
| **HashiCorp Vault** | 集中存密钥，带版本与审计 | 单实例（**刻意不做 HA**，理由在 ROADMAP）；oracle 跨 Tailscale 读它 |
| **External Secrets Operator (ESO)** | 把外部密钥库同步成 K8s Secret | 两集群各装一份（版本刻意不耦合）；`ExternalSecret` 是 Git 里唯一提到密钥的地方 |
| **ZITADEL** | 自托管的身份提供方（OIDC/OAuth2） | 数据库是 CNPG 独立实例；应用走**原生 OIDC** 而非统一入口层 SSO → [app-native-oidc-sso.md](../decisions/app-native-oidc-sso.md) |
| **oauth2-proxy** | 给没有认证能力的应用套一层 OIDC | 只作兜底，per-app 部署 → [identity.md](identity.md) |

### 3.7 数据与备份

| 组件 | 解决什么问题 | 在这里的特殊之处 |
|------|-------------|-----------------|
| **local-path** | K3s 自带的本地盘 PV | **可写卷一律用它**。☠️ sqlite 应用尤其不能放 NFS（fcntl 锁极慢） |
| **NFS（只读）** | 挂 106 的 ZFS 媒体库 | 2026-07-11 退役后的**唯一例外**：只读 + 只媒体 + 不装 provisioner → [multimedia-repository-nfs-readonly.md](../decisions/multimedia-repository-nfs-readonly.md) |
| **CloudNativePG (CNPG)** | 用 CR 声明式管理 PostgreSQL 集群 | 只在 oracle 装；homelab 那个同名的共享 Postgres 是裸 Deployment，**刻意不装 operator**（operator 本身比省下的开销贵）→ [shared-postgres-platform.md](../decisions/shared-postgres-platform.md) |
| **restic** | 去重加密备份 | 无 server，CronJob 直推 106 的 sftp 仓库；⚠️ 是**三个 Job**不是两个，且备份是**显式白名单**（新应用不加进去就静默不备份，CI 的 H4 查的就是这个）→ [storage.md](storage.md) |
| **ZFS + sanoid** | 备份目标端的快照与完整性 | 备份的备份：restic 仓库本身也在快照里 |

### 3.8 可观测

| 组件 | 解决什么问题 | 在这里的特殊之处 |
|------|-------------|-----------------|
| **Prometheus** | 拉取式指标存储 + PromQL | 在 homelab；两集群指标汇总到这里 |
| **Grafana** | 看板与查询前端 | 在 homelab，但要跨集群查 oracle 上的 Loki/Tempo |
| **Alertmanager** | 告警去重/路由/静默 | 投递到 Telegram（原生 `telegramConfigs`，Gotify 已退役）→ [alerting-telegram-migration.md](../decisions/alerting-telegram-migration.md) |
| **Loki** | 日志存储（按标签索引，不做全文索引） | ☠️ 在 **oracle**，不在 Prometheus 旁边 |
| **Tempo** | 分布式追踪存储 | 在 oracle；⚠️ 写入口与查询口是**两个端口** |
| **OpenTelemetry Collector** | 统一采集日志/指标/追踪并转发 | DaemonSet，取代 Promtail；应用接入有 4 种模式（含 linuxserver.io 那类只写文件不写 stdout 的）→ [observability-multicluster.md](observability-multicluster.md) |
| **Sloth** | 用 CR 生成 SLO 的 PromQL 与告警规则 | ☠️ `errorQuery` 必须 `OR on() vector(0)`，否则空集会让 SLO 变 NaN → [2026-08-12-slo-nan-poisoning.md](../records/2026-08-12-slo-nan-poisoning.md) |
| **OpenCost / KRR** | 成本归因 / 资源右尺寸建议 | 两者都因同一个 cAdvisor 缺口需要旁路采集 → [opencost-krr-data-sources.md](../decisions/opencost-krr-data-sources.md) |
| **Uptime Kuma** | 外部视角的可用性探测 | 兼任 dead man's switch 的接收端 —— 唯一不与被监控方共命运的告警 → [dead-mans-switch.md](dead-mans-switch.md) |

☠️ **遥测是双向的**：指标面在 homelab、日志与追踪面在 oracle。这是读监控相关文档时最容易搞错的一点
→ [observability-multicluster.md](observability-multicluster.md)。

### 3.9 安全

11 层纵深防御的完整状态表在 [security.md](security.md)，这里只列「每层用的是什么」：

| 组件 | 解决什么问题 | 在这里的特殊之处 |
|------|-------------|-----------------|
| **Pod Security Admission (PSA)** | K8s 内置的 Pod 安全基线 | ⚠️ Namespace **必须显式写等级**，漏写会静默吃默认 `privileged`（CI 的 H5） |
| **Kyverno** | 策略即代码（校验/变更准入） | 只在 homelab |
| **Trivy Operator** | 持续扫镜像 CVE 与配置 | 两集群都有；☠️ **四类静默失败**（TTL 卡吞吐 / 改 ignoreFile 不触发重扫 / arm64 扫不了 / 限流不自愈）→ [trivy-cve-ops.md](trivy-cve-ops.md) |
| **kube-bench** | CIS Kubernetes 基线自查 | CronJob 定期跑 |
| **Tetragon / Falco** | eBPF 运行时行为检测 | 两集群**分别选型**：Tetragon 在 homelab，Falco + Falcosidekick 在 oracle（规则库开箱即用，且该侧 CPU 余量大）。⚠️ 规则误报会吃掉整条通道，还会冒充心跳 → [security.md](security.md) |
| **Hubble** | Cilium 的网络流可见性 | ⚠️ 第 9 层**只到可见性**：集群内没有自建 `CiliumNetworkPolicy`，默认拒绝是**刻意延后**的，别当成已生效 |

### 3.10 仓库工程（CI 与护栏）

这些检查每条都是由一次真实事故反推出来的。

| 组件 | 解决什么问题 |
|------|-------------|
| `scripts/check-manifests.py` | H1–H5：Namespace 独占文件、App 的 path 与 destination 同集群、ReferenceGrant 版本、PVC 备份归属、PSA 等级 |
| `scripts/check-docs.py` | R1–R8：目录归属、命名、文首字段、索引完整性、长度预算 |
| `scripts/check-terminology.py` | T1–T4：不存在的集群名、拼写正典、过期的「单节点」表述 |
| `scripts/check-public-ips.py` | 禁止提交公网 IP |
| `scripts/check-version-pairs.py` | V1–V3：必须同步升级的版本对（如 Cilium ↔ Gateway API CRD） |
| `scripts/check-embedded-scripts.py` | E1：ConfigMap 内嵌脚本与 `.py` 源一致 + Pod 模板带 checksum 注解 |

本地一次跑完：`just check`（与 CI 同款）。规则全文 → [manifest-safety-checks.md](manifest-safety-checks.md)。

☠️ **删任何清单文件前先 `grep '^kind:' <file>`**：ArgoCD 按目录同步，删掉文件就 prune 掉里面的全部对象，
内嵌的 `Namespace` 会连带删光同 ns 下别的应用的数据 → [2026-08-03-namespace-prune-cascade.md](../records/2026-08-03-namespace-prune-cascade.md)。

## 4. 两个集群的分工

| | homelab | oracle-k3s |
|---|---------|------------|
| 定位 | 指标中枢 + 密钥 + 本地模型接入 | 公网服务面 + GitOps 控制面 + 日志/追踪 + 身份面 |
| 拿得动什么 | 计算密集、大流量、只有 amd64 镜像的 | 轻量无状态；ARM64，镜像必须有 `linux/arm64` |
| GitOps 角色 | spoke（被纳管） | hub（控制面在此） |

完整对比表在 [../ARCHITECTURE.md](../ARCHITECTURE.md)；新服务往哪放的判据在
[cluster-placement-for-new-services.md](../decisions/cluster-placement-for-new-services.md)。

## 5. 故意没有的东西

完整清单与重评触发条件在
[ROADMAP.md 的「不做 / 已取消」](../ROADMAP.md#不做--已取消)，典型的几条：
Cert-Manager（TLS 在边缘终结）· Crossplane · Vault HA · Thanos/Mimir ·
集群级网络默认拒绝（**延后不是取消**）· 镜像自动升级。

## 6. 真相源地图（配置和版本钉在哪）

改东西之前先在这张表里定位。**本页不复制任何具体数值** —— 复制就会漂。

| 想改/想查 | 唯一位置 |
|-----------|---------|
| 跑着哪些服务、在哪个集群/ns/域名 | [services.md](services.md) |
| 术语与集群命名 | [terminology.md](terminology.md) |
| Cilium 与 Gateway API CRD 版本（**一对，必须同步**） | 根 `versions.just` |
| 上游 chart 版本 | 对应的 `argocd/applications/<app>.yaml` 的 `targetRevision` |
| manual-helm 四件套的版本钉 | `k8s/helm/justfile` · `cloud/oracle/justfile` |
| Helm values | `k8s/helm/values/`（homelab）· `cloud/oracle/values/`（oracle） |
| 自研应用清单 | `k8s/helm/manifests/<app>/` · `cloud/oracle/manifests/<app>/` |
| 有哪些 Application（数量会变，别记死） | `ls argocd/applications/*.yaml` |
| 资源 requests/limits 的实际数值 | values 文件与集群本身；文档只写原则与判据 |
| 命令清单 | `just --list`（根 justfile 聚合全部子 justfile） |
| 密钥 | Vault（`secret/homelab/*` · `secret/oracle-k3s/*`），Git 里只有 `ExternalSecret` |

⚠️ 有一处真相源是**分裂**的：LiteLLM 网关的模型/路由在 Git，
**虚拟 key 的模型白名单在 Postgres**。改别名不同步改 key 就会「清单正确 + ArgoCD Synced + 调用全挂」
→ [litellm-gateway.md](litellm-gateway.md)。

## 7. 接下来读什么

| 你想干的事 | 去哪 |
|-----------|------|
| 理解整体拓扑 | [../ARCHITECTURE.md](../ARCHITECTURE.md) |
| 上手改这个 repo | [../AGENTS.md](../AGENTS.md)（命令、约定、硬约束） |
| 加一个新服务 | [add-service.md](../runbooks/add-service.md) |
| 深入某一层 | [reference/ 索引](README.md) |
| 搞明白「为什么不是另一种做法」 | [decisions/ 索引](../decisions/README.md) |
| 看这套系统怎么坏过 | [records/ 索引](../records/README.md) —— 多数「为什么这么规定」的答案在这里 |
