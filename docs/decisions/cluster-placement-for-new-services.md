# 新服务落哪个集群：计算/带宽密集走 homelab，轻量无状态走 oracle-k3s

> 日期: 2026-08-10
> 状态: ✅ 已完成

## 上下文

双集群的默认落点原本是 **oracle-k3s**（"云上、不占家里那台热笔记本"）。这个默认在
2026-08-05 把 oracle 从 4 OCPU/24GB 缩到 **2 OCPU / 12GB** 之后就不再成立了——而且缩容是
**单向的**（ap-osaka-1 的 A1 Free Tier 没容量涨回去）。

两节点实测（2026-08-10）：

| | homelab `k8s-node` | oracle-k3s |
|---|---|---|
| 架构 | **amd64** | arm64 |
| CPU capacity / allocatable | 10 / **9600m** | 2 / **1800m** |
| CPU requests | 2035m（**21%**） | 1293m（**71%**） |
| 内存 allocatable | 11.4Gi | 8.7Gi |
| 内存 requests | 6294Mi（54%） | 7833Mi（**88%**） |
| `free -m` available | **6617 MB** | **2615 MB** |

> oracle 的 CPU requests 是 71%/1293m，不是文档里长期写着的 82%/1477m——2026-08-10 那轮
> KRR 分诊压下来的。判据永远是现场 `describe node`，不是文档里的快照数字。

结论很直接：**oracle 只剩约 0.5 核和 2.6GB 可用**，homelab 还有 **7.5 核和 6.6GB**。
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

## 后果

- **homelab 的 limits 已经超卖**（CPU 122%、内存 152%），而它同时托着
  Prometheus/Grafana/Alertmanager/Vault。往这台机器放计算密集负载**必须写显式 CPU limit**，
  否则一个跑飞的 pod 会把监控栈一起拖下水（监控栈挂掉时正是最需要它的时候）。
- **thermal 是真实成本**：homelab 是 Ryzen 5600H 单节点笔记本，空闲 ~60–62°C 已接近物理散热
  上限。持续 CPU 负载会抬温、掉频，也会影响同机所有负载的延迟。细节见
  [homelab-host-power-thermal.md](../reference/homelab-host-power-thermal.md)。
- 这类服务不要挂 `priorityClassName: bulk`——公共服务被优先驱逐不是想要的行为。分档见
  [k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md)。
- homelab 上的 PVC 依然只有 `local-path`（无冗余），落地时照 H4 规则确认备份归属。
- homelab 的 HTTPRoute 一路由一文件（`k8s/helm/manifests/gateway/route-<service>.yaml`），
  且首次部署要查 `ResolvedRefs`——homelab 侧有路由/工作负载的同步排序竞态。
  流程见 skill `.claude/skills/add-service/SKILL.md`。
- 密钥路径随集群走：homelab 用 `secret/homelab/<service>`，oracle 用 `secret/oracle-k3s/<service>`。

## 推翻条件

- oracle-k3s 换到别的 region 或拿到更大的 shape（CPU requests 回落到 50% 以下），
  "云上优先"可以重新讨论。
- homelab 若因散热/功耗需要长期降载，把计算密集服务移回云上——届时按
  [stateful-service-cross-cluster-migration.md](../runbooks/stateful-service-cross-cluster-migration.md) 搬。
