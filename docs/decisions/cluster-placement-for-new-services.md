# 新服务落哪个集群：计算/带宽密集走 homelab，轻量无状态走 oracle-k3s

> 日期: 2026-08-10
> 状态: ✅ 已完成

## 上下文

双集群的默认落点原本是 **oracle-k3s**（"云上、不占家里那台热笔记本"）。这个默认在
2026-08-05 把 oracle 从 4 OCPU/24GB 缩到 **2 OCPU / 12GB** 之后就不再成立了。而且缩容是
**单向的**（ap-osaka-1 的 A1 Free Tier 没容量涨回去）。

两节点实测（2026-08-10）：

| | homelab `k8s-node` | oracle-k3s |
|---|---|---|
| 架构 | **amd64** | arm64 |
| CPU capacity / allocatable | 10 / 9600m | 2 / 1800m |
| CPU requests | 2035m（21%） | 1293m（71%） |
| 内存 allocatable | 11.4Gi | 8.7Gi |
| 内存 requests | 6294Mi（54%） | 7833Mi（88%） |
| `free -m` available | 6617 MB | 2615 MB |

> oracle 的 CPU requests 是 71%/1293m，不是文档里长期写着的 82%/1477m。2026-08-10 那轮
> KRR 分诊压下来的。判据永远是现场 `describe node`，不是文档里的快照数字。

结论很直接：**oracle 只剩约 0.5 核和 2.6GB 可用**，homelab 还有 7.5 核和 6.6GB。
再往 oracle 塞任何吃 CPU 的东西，抢的是 ZITADEL（SSO，`critical` 优先级）和 Loki/Tempo 的资源。

另外两条同向的事实：

- **架构**：homelab 是 amd64，不必每次先验证镜像有没有 `linux/arm64` 变体（这条在 oracle
  上是实打实的选型约束，很多上游镜像只发 amd64）。
- **出网路径不同**：homelab 走家宽上行 → Cloudflare Tunnel；oracle 走 OCI 的公网口。
  ⚠️ **两条链路的实际带宽都没有实测过**，"homelab 带宽更足"是运维者基于自家链路的判断，
  不是本文档量出来的数字。真要按带宽选型，先测再决定。

## 决策

新服务的落点按**资源画像**选，而不是按"云上优先"：

| 服务画像 | 落点 |
|---|---|
| 计算密集（持续吃 CPU：转码、索引、构建、模型推理、批处理） | **homelab** |
| 大流量公共服务（高并发/大带宽出网） | **homelab** |
| 需要 homelab 本地数据 / Vault / Prometheus 栈 / LAN 访问 | **homelab** |
| 只发 amd64 镜像 | **homelab** |
| 轻量无状态个人服务（requests 10–25m 级别） | **oracle-k3s**（仍是默认） |
| 身份/SSO、日志、追踪（既有归属） | **oracle-k3s** |
| 无状态周期 CronJob / 批处理（无 PVC、无宿主依赖、无节点语义） | **homelab 的 `k8s-worker-106`**（2026-08-14 起；见下「worker 的职责」） |

## 后果

### `k8s-worker-106` 的职责（2026-08-14 定）

（106 上的 VM 作为 homelab worker 的背景见 [storage106-as-homelab-worker](storage106-as-homelab-worker.md)。）

- **能放**：无状态、周期、节点无关的 CronJob / 批处理：它只有 ~`3254Mi` allocatable
  （2026-08-16 VM 3G→4G 前是 2311Mi；requests 40% / CPU 15%，Celeron 慢核），适合承接周期扫描/批处理这类「短、脉冲、可牺牲」负载，
  把控制面（5600H 笔记本）的周期 CPU/热峰值挪走。首个落点是 `monitoring/krr`（2026-08-14，无 PVC
  / 无 hostPath，只查集群内 Prometheus + K8s API + 推 Telegram）。
- **也能放常驻的无状态服务**（2026-08-16 扩大）：`cf-analytics-exporter`、`media/podcast`（读的
  只读 NFS 就在 106 本机，这一跳不出宿主机）、`sloth`、`external-dns`、trivy 的**扫描 Job**
  （`trivyOperator.scanJobNodeSelector`，周期 CPU 脉冲，分担收益最大）。
  ⚠️ trivy 的 **operator 本体不能一起搬**：chart 0.33.1 用同一个 `.Values.nodeSelector` 同时套
  operator 和内置 trivy-server，而 server 的 PVC 在控制面 → 一钉就把 server 变成永久 Pending。
- **媒体三件套已全部落 worker**（2026-08-16）：`podcast` / `navidrome` / `jellyfin`。共同理由是
  **数据本体就在 106 的 ZFS 上**，跑在同一台宿主机的 VM 里，几百 MB 的顺序读不再经 pve NAT 绕 LAN。
  jellyfin 实测峰值 380m/800Mi（初次扫库）、稳态 1m/332Mi。
  ☠️ **前提是不转码**：106 是 Celeron J4105（4 核 1.5GHz，VM 分到 2 核），软解转码是死路，
  QSV 硬解要给 VM 直通核显。哪天真需要转码，第一步是搬回控制面（5600H），不是在这台上调参数。
- **worker 的内存天花板已经用满**（2026-08-16）：VM 3G→4G 是靠把 106 的 ZFS ARC 从 2G 砍到 1G
  换来的（allocatable 2311Mi → **3254Mi**）。106 只有 8G 物理内存，`StorageNodeMemoryLow` 那条
  表达式的实测值已从 66% 掉到 16%（阈值 10%）。**再要内存只能加物理条**，别再从 ARC 里挤。
  改 VM 内存要关机重启（`balloon: 0` 无热插拔）→ 先 drain，且 local-path PVC 跟不走，
  navidrome/jellyfin 会中断到 VM 起来为止。
  绑定方式统一是 `nodeSelector: kubernetes.io/hostname: k8s-worker-106`。
  ⚠️ 逐个都要想清楚「worker 掉线时降级成什么」：external-dns 停 = 新子域名没记录（存量不受影响）、
  sloth 停 = SLO 规则不再重新生成（已生成的照常告警）、trivy 停 = 报告变旧。
  ⚠️ 别把入口和告警数据源放上来：cloudflared 已显式钉控制面（见其清单头注）；
  kube-state-metrics 是 `kube_node_*` 的来源，放在最可能掉线的节点上是相关性故障。
- ~~**放不了有状态负载**：`local-path` PVC 落 106 盘后不在 restic 白名单（H4），要放先加白名单。~~
  **2026-08-16 起可以放了**：worker 有了自己的夜备（02:00，`--host homelab-worker`，整目录扫）
  + 106 的整机周备 vzdump。但 PVC 本身**不跟随调度**：已有 PVC 的服务要搬，得按
  [runbooks/stateful-service-cross-cluster-migration.md](../runbooks/stateful-service-cross-cluster-migration.md)
  的节点内变体先搬数据，光加 `nodeSelector` 只会让 Pod 因卷节点亲和冲突永远 Pending。
- **放不了要直连 DGX 的**：worker 是 tagged 设备，netmap 里没有 DGX 这个 shared peer
  （实测 pod `100.97.87.120:8000` 超时）；而控制面的用户所有身份能到。像 jobs-sg 的 `enrich`
  这类直连 DGX 的负载必须留控制面（jobs-sg 另有共享 `jobs-sg-data` PVC，本就整体锁死控制面）。
- **放不了控制面/宿主依赖负载**：kube-bench 钉死 control-plane + 依赖控制面宿主 hostPath。

## 后果（原有）

- **homelab 的 limits 已经超卖**（CPU 122%、内存 152%），而它同时托着
  Prometheus/Grafana/Alertmanager/Vault。往这台机器放计算密集负载**必须写显式 CPU limit**，
  否则一个跑飞的 pod 会把监控栈一起拖下水（监控栈挂掉时正是最需要它的时候）。
- **thermal 是真实成本**：homelab 是 Ryzen 5600H 单节点笔记本，空闲 ~60–62°C 已接近物理散热
  上限。持续 CPU 负载会抬温、掉频，也会影响同机所有负载的延迟。细节见
  [homelab-host-power-thermal.md](../reference/homelab-host-power-thermal.md)。
- 这类服务不要挂 `priorityClassName: bulk`：公共服务被优先驱逐不是想要的行为。分档见
  [k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md)。
- homelab 上的 PVC 依然只有 `local-path`（无冗余），落地时照 H4 规则确认备份归属。
- homelab 的 HTTPRoute 一路由一文件（`k8s/helm/manifests/gateway/route-<service>.yaml`），
  且首次部署要查 `ResolvedRefs`：homelab 侧有路由/工作负载的同步排序竞态。
  流程见 skill `.claude/skills/add-service/SKILL.md`。
- 密钥路径随集群走：homelab 用 `secret/homelab/<service>`，oracle 用 `secret/oracle-k3s/<service>`。

## 推翻条件

- oracle-k3s 换到别的 region 或拿到更大的 shape（CPU requests 回落到 50% 以下），
  "云上优先"可以重新讨论。
- homelab 若因散热/功耗需要长期降载，把计算密集服务移回云上：届时按
  [stateful-service-cross-cluster-migration.md](../runbooks/stateful-service-cross-cluster-migration.md) 搬。
