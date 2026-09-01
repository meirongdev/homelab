# Terminology — 术语与命名正典

> Last updated: 2026-09-01
> Status: 生效事实
>
> **这是全仓库技术用语的唯一真相源。** 写文档、写注释、写 commit message 前对一下这里。
>
> 分两类，别混：
> - **标识符（identifier）** = 系统里真实存在的名字（context 名、节点名、标签值、文件名）。
>   **照抄，永远不要"统一"它**：改标识符是改系统，不是改文风。
> - **散文用语（prose term）** = 正文里指称同一个东西时该写什么。这一类才需要统一。
>
> 下面每张表都区分这两列。判据来自实测（`kubectl`、`cilium-config`、values 文件）与全仓
> 词频统计，不是偏好。

## ☠️ 一号陷阱：同一个集群在不同层有不同的官方名字

**homelab 集群没有单一名字。** 各层实测如下：

| 层 | homelab 集群 | oracle 集群 | 真值来源 |
|---|---|---|---|
| kubectl context | `k3s-homelab` | `oracle-k3s` | `kubectl config get-contexts` |
| Cilium cluster-name / ClusterMesh | `homelab`（id=1） | `oracle-k3s`（id=2） | `kube-system/cilium-config` |
| ArgoCD 里注册的 cluster name | `homelab` → `https://100.94.186.7:6443` | `in-cluster` | argocd cluster secret |
| 承载它的 Secret / ExternalSecret 名 | `homelab-cluster` | —（in-cluster 无需 secret） | `argocd` ns 实测 |
| 指标/日志的 `cluster=` 标签 | `homelab` | `oracle-k3s` | kube-prometheus-stack.yaml · otel-collector-config.yaml |
| K8s 节点名 | `k8s-node` / `k8s-worker-106` | `oracle-k3s` | `kubectl get nodes` |
| 正文散文 | homelab | oracle-k3s | 本表 |

两个后果，都真的咬过人：

1. **`k3s-homelab` 只在 kubectl context 这一层成立。** 其余各层都叫 `homelab`。
   写脚本默认值时尤其容易搞错：`cleanup-duplicates.sh` 的默认 context 曾长期是
   `k3s-homelab`（在 calibre 迁走后就指错了集群），见
   [records/2026-08-18-calibre-dedup-stale-paths.md](../records/2026-08-18-calibre-dedup-stale-paths.md)。
2. ⚠️ **`oracle-k3s` 同时是集群名、context 名、和那台节点的名字。** 说"oracle-k3s 上"时，
   如果指的是节点（比如 `kubectl describe node oracle-k3s`）就写"oracle-k3s **节点**"。

**不存在的写法，写了就是错**（CI 拦）：`homelab-k3s` · `k3s-oracle` · `k8s-homelab` ·
`oracle-k8s`。

⚠️ 但 **`homelab-cluster` 是真名**，不在禁止列里：它是 `argocd` ns 里那个 Secret /
ExternalSecret 的名字。这正是"标识符照抄、别统一"的例子：它看着像该被normalize 成
`homelab`，实际改了就是改资源名。

## 节点与宿主

**标识符照抄，别改**：

| 标识符 | 是什么 | 集群/角色 | 地址 |
|---|---|---|---|
| `k8s-node` | homelab **控制面**节点（VM on `pve`） | k3s-homelab · amd64 | `10.10.10.10` · TS `100.94.186.7` |
| `k8s-worker-106` | homelab **worker** 节点（VM on `storage-106`） | k3s-homelab · amd64 · 2c/4G | `192.168.50.107` · TS `100.74.162.97` |
| `oracle-k3s` | oracle 的**唯一节点**（与集群同名） | oracle-k3s · arm64 | `10.0.0.26` · TS `100.107.166.37` |
| `pve` | Proxmox VE **宿主**（Ryzen 5600H 笔记本），不是 k8s 节点 | — | `192.168.50.4` |
| `storage-106` | NAS **宿主**（Celeron J4105）。三个角色：备份目标 + 承载 worker VM + 媒体只读 NFS 源 | — | `192.168.50.106` · TS `100.110.27.111` |

⚠️ **`k8s-worker-106` 的 VM / Ansible inventory 名仍是 `k3s-exp`**（改名要 destroy/recreate，
不值得）。所以同一个东西：节点叫 `k8s-worker-106`、VM 叫 `k3s-exp`。两个都是有效标识符，
按层用。→ [decisions/storage106-as-homelab-worker.md](../decisions/storage106-as-homelab-worker.md)

**散文用语**：

| 该写 | 别写 | 理由 |
|---|---|---|
| **控制面** | 控制平面 · master · 主节点 | 判据：定正典时全仓 `控制面` 97 : `控制平面` 1。`master` 在本仓库另有含义（`master key`），且是 K8s 弃用术语 |
| **worker** | 工作节点 · 从节点 | 与节点名 `k8s-worker-106` 一致 |
| **宿主** / **宿主机** | 物理机 · 母机 | 指 `pve` / `storage-106` 这层 |
| **storage-106** | storage106 · 106 号机 | 带连字符才是主机名 |
| 106 | — | ✅ 可用作 `storage-106` 宿主的简称。但**不要**用它指 worker 节点或那台 VM |

## ☠️ 二号陷阱："单节点"现在必须指明是哪个集群

**homelab 自 2026-08-13 起是双节点**（控制面 + worker）。**oracle-k3s 至今仍是单节点。**

所以裸写"单节点"已经有歧义。规则：

- 讲 oracle → "oracle-k3s 单节点" ✅
- 讲 homelab 现状 → **不要**写"homelab 单节点"，写"homelab 控制面"或"双节点"
- 讲历史成因（大量 values 注释属于此类，如 "单节点无需反亲和"）→ 保留，但新写要加时间限定
- `plans/` 与 `decisions/` 是冻结快照（R1），里面的"单节点"不改也不算错

⚠️ 热约束仍以**控制面**为准：worker 只有 2c/4G，安全组件与热预算的判断没有因为加了 worker
而放宽。→ [homelab-host-power-thermal.md](homelab-host-power-thermal.md)

## 平台与发行版

| 该写 | 什么时候 | 例 |
|---|---|---|
| **K3s** | 指这套发行版本身、它的安装/配置/内置组件 | "K3s 内置 traefik 已 disable" |
| **Kubernetes** / **K8s** | 指平台通用概念，与发行版无关 | "非 K8s 工作负载"、"K8s 节点" |
| `k8s/` | 仓库目录名（标识符） | `k8s/helm/values/` |

两个都对，别互相"纠正"。写 `K3S` 全大写是错的（全仓 0 次）。

## 入口层

这三个词指**不同**的东西，不是同义词：

| 词 | 指什么 |
|---|---|
| **Gateway API** | CRD 规范本身（`gateway.networking.k8s.io`）。⚠️ 它的版本与 Cilium 是一对，升 Cilium 必跑 `just deploy-gateway-api-crds` |
| **Cilium Gateway** | 本仓库对 Gateway API 的**实现**（Cilium 的 Gateway API 控制器 + Envoy） |
| **入口** / 入口层 | 泛指"外部流量进集群"这一层，不特指实现 |
| **HTTPRoute** | 加子域名时实际要写的对象（写它就够，DNS 由 external-dns 建） |

🚫 **`Ingress`（K8s 的 Ingress 资源）本仓库不使用**，Traefik 也已 disable。正文里出现
"Ingress" 只应是在讲历史或对比。别把 `Ingress` 和 `入口` 当同义词混用：前者是具体资源类型。
→ [networking-ingress.md](networking-ingress.md)

## GitOps

| 该写 | 别写 | 说明 |
|---|---|---|
| **ArgoCD** | Argo CD（带空格） | 上游官方拼法是 "Argo CD"，但本仓库统一 `ArgoCD`（定正典时全仓 455 : 0）。已成事实，不改 |
| **Application** | — | 指 ArgoCD 的 CRD 对象本身，首次出现或强调对象类型时用全称 |
| **App** | — | ✅ 沿用的简称，指同一个东西。表格/列举里用它没问题 |
| **GitOps 托管** | 自动部署 | 指"push 后 ArgoCD 3 分钟轮询自动同步" |
| **manual-helm** | 手动部署 | 指必须手动 `helm upgrade` 的那几个：Cilium / Vault / ESO / ArgoCD 本体。**提交 ≠ 部署** |

⚠️ Application 里 `destination.server: kubernetes.default.svc` 指的是 oracle（GitOps 控制面
2026-08-02 起在 oracle）。homelab 负载必须显式写 `https://100.94.186.7:6443`。
→ [argocd-app-patterns.md](argocd-app-patterns.md)

## 存储与备份

| 该写 | 说明 |
|---|---|
| **local-path** | 唯一的 StorageClass，所有**可写**卷都用它（媒体的 5 个只读 NFS PV 是静态 PV，不属于任何 SC）|
| **restic 仓库** | 备份目标（106 上的 ZFS 加密仓库，sftp）。别写 "restic repo/repository" 混用 |
| **vzdump** | PVE 每周整 VM 备份，与 restic 是两条独立路径 |

☠️ **"NFS 已退役（2026-07-11）"的确切范围 = 应用的可写数据不再放 NFS**，且 `nfs-client`
provisioner 已卸载。它不等于"哪儿都没有 NFS"，而且 2026-08-16 之后连"运行时无人挂载"
也不再成立：

| 还在用 NFS 的地方 | 状态 |
|---|---|
| `media` ns 的 5 个静态只读 PV（`/storage/{movie,tv,anime,music,podcast}`） | **运行时挂着**，2026-08-16 起 |
| `/storage`、`/storage/calibre` 两个遗留 export | 仍在（Ansible 管理），无人挂载 |
| PVE 的 `backups` storage | 一直是 NFS |

说"退役"时把范围讲清楚，别写成"运行时零依赖"。
→ [storage.md](storage.md) · 例外的完整理由 [decisions/multimedia-repository-nfs-readonly.md](../decisions/multimedia-repository-nfs-readonly.md)

⚠️ **"备份"是显式白名单**，不是"默认都备"。新增有状态应用不加进去就静默不备份（H4 查这个）。
反过来 `Prune=false` 意味着**退役服务时 PVC 不会被删**，要手工清。

## 跨集群网络

| 该写 | 别写 | 说明 |
|---|---|---|
| **ClusterMesh** | Cluster Mesh（带空格） | Cilium 的跨集群能力；pod↔pod 走它的 VXLAN |
| **Tailscale** | — | 只做**节点级 underlay**（各节点自己的 /32 + NodePort），不承载 pod↔pod |
| **TS** | — | ✅ 可作 Tailscale 简称（如 "TS `100.94.186.7`"），但首次出现用全称 |
| **underlay** | 底层网络 | 指 Tailscale 那一层 |

⚠️ `AdvertiseRoutes` 只该有本节点 /32（Pod CIDR 子网路由 2026-07-07 已移除）。
→ [tailscale-network.md](tailscale-network.md)

## 拼写正典（CI 强制）

| 正典 | 禁止 |
|---|---|
| `ZITADEL` | Zitadel · zitadel（指产品时） |
| `ArgoCD` | Argo CD |
| `ClusterMesh` | Cluster Mesh |
| `storage-106` | storage106（**文件名例外**：`decisions/storage106-as-homelab-worker.md` 已定，不重命名） |
| `控制面` / `control-plane` | **`master`**（指节点时）· 控制平面 · 主节点 |
| `K3s` | K3S |

☠️ **`master` 单独说一下**：2026-08-18 全仓把 79 处（74 行）指控制面节点的 `master` 改成了
`控制面`/`control-plane`。它是 K8s 弃用术语，而且在本仓库特别容易误读，同一个词还有
三个合法含义，都保留不动：

| 保留的 `master` | 为什么不能改 |
|---|---|
| `master key` | LiteLLM 与 ZITADEL 的机密名（Vault key 名、env 名） |
| git `master` 分支 | 上游仓库的分支名 |
| `--targets master,etcd,controlplane,node,policies` | **kube-bench 认的 target 名**。连解释它的那行注释也不能改，否则注释与实参脱节 |

## 强制方式

`scripts/check-terminology.py` 在 CI 跑（`docs-check.yml`），只查**机械可判、且判错就是事实错误**的四条：

| 规则 | 范围 | 查什么 |
|---|---|---|
| **T1** | 全仓 | 不存在的 context / 集群名（`homelab-k3s`、`k3s-oracle`…），曾让脚本默认打错集群 |
| **T2** | 全仓 | 上表的拼写正典 |
| **T3** | 仅 `reference/` + `runbooks/` | 把 homelab 说成单节点（已带日期/时态限定的句子放过） |
| **T4** | 全仓 | `master` 指控制面节点（上表三种合法含义自动放过） |

**`docs/plans/` 与 `docs/records/` 也在范围内**（2026-08-18 纳入，当天顺带改了 12 处 `master`
加 1 处 `控制平面`，共 12 行）。
它们按 R1 是写完即冻结的快照，但"叫什么名字"不是事实陈述：拉平命名不改写历史。

☠️ **T3 刻意只作用于 `reference/` 与 `runbooks/`**，因为它是唯一与年代绑定的规则：
2026-03 的 plan 里写"homelab 单节点"在当时是对的，改掉反而让那份历史文档变成假的。
**往这个检查加规则时先问一句：这条判的是「命名」还是「当时的事实」？** 前者可以全仓拉平，
后者只能管必须反映现状的目录。

它故意不管风格类变体（K3s vs K8s 的语义选择、App vs Application、`106` 简称）：
那些写成规则必然误报，误报多了整个检查就会被绕过，只能靠本文档 + review。

确有例外（比如逐字引用上游文档里的 "Argo CD"）就在那一行写
`terminology-ok: <理由>`，与 `check-public-ips.py` 的 `public-ip-ok` 同一约定，
必须带理由，不接受裸豁免。

⚠️ **机械改写术语时，检查通过 ≠ 改对了。** 检查只认得被禁的字面量，看不见语义损坏。
2026-08-18 那次全仓改写就撞了三种，且都是检查抓不到的：
`git pull origin master` 被改成 `origin control-plane`（R7 说命令必须可执行，这就是坏的）·
`master/虚拟 key`（LiteLLM 的 **master key**）被当成节点 ·
本文档与检查器自身的正则里那些作为反例存在的 `master` 字面量被一起改掉。
改完必须逐行看 diff，尤其是命令行、密钥名，和"列出反例"的文件。

```bash
python3 scripts/check-terminology.py        # 仓库根执行
```
