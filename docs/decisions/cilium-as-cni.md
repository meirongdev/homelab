# CNI 选 Cilium（eBPF + VXLAN），从 Flannel 迁入

> 日期: 2026-03-06（决策与实施）· 2026-09-02 补写本 ADR
> 状态: ✅ 已实施，双集群统一
> 关联：[执行过程与停机步骤](../plans/networking/2026-03-06-cilium-mesh-installation.md)（当时的快照，路径与版本已变）·
> [reference/tailscale-network.md](../reference/tailscale-network.md)（当前网络模型的**唯一真相源**）·
> [gateway-controller-evaluation](gateway-controller-evaluation.md)（入口层，比本决策晚）

> ⚠️ **本文是 2026-09-02 补写的**。此前 CNI 选型的唯一记录是上面那份 plan，而按 R1，
> plan 是「写完即冻结的历史快照」，不该承担「为什么是这个方案」的长期职责 ——
> ARCHITECTURE 的决策表当时直接指向它，并注着「无独立 ADR」。本文只搬决策与取舍，
> 执行步骤仍在 plan 里，不复制。

## Context

2026-03 之前 homelab K3s 跑默认的 Flannel（VXLAN）+ kube-proxy（iptables）+ K3s 内置
kube-router 做 NetworkPolicy。三个当时成立的诉求：

- **可观测性**：没有任何手段回答「这个 pod 在跟谁说话」。排查跨集群问题只能靠 tcpdump。
- **NetworkPolicy 要能做到 L7**：内置实现只有 L3/L4，而[安全模型](../reference/security.md)
  第 9 层的规划是先做可见性、再逐 ns 灰度策略。
- **跨集群**：oracle-k3s 已经在跑，两边要能 pod↔pod。Flannel 侧只能靠 Tailscale 广播
  Service CIDR，把跨集群链路绑死在私有网段上。

换 CNI 是**破坏性变更**：要带新参数重装 K3s，再重新部署全部工作负载，当时估停机 30–60 分钟。

## Options

### 维持 Flannel + kube-router
零成本、零风险。但上面三个诉求一个都不解决，Hubble 那类可见性没有等价物。

### Calico
功能上够（L3/L4 策略 + 有商业支持），但要另装一套控制面；eBPF 数据面当时仍是可选项而非默认，
选它等于承担迁移成本却拿不到 eBPF 与 Hubble。

### Cilium（eBPF + VXLAN）← 采纳
一次迁移同时拿到 eBPF 数据面、Hubble 可观测、L3/L4/L7 策略，以及后来真正用上的 ClusterMesh。
VXLAN 而非原生路由：两个集群的节点不在同一个二层，且跨集群走 Tailscale underlay，
原生路由模式没有落地条件。

## Decision

双集群统一 Cilium，eBPF 数据面 + VXLAN 隧道，启用 Hubble。当时同批做的四个**保守选择**
（刻意缩小爆炸半径，让这次变更只换 CNI）：

1. **保留 Traefik 作 Ingress**：Cilium 自带 Gateway API，但当时 SSO 走 Traefik 的
   ForwardAuth Middleware，一起换工作量太大。
2. **保留 kube-proxy 与 K3s ServiceLB**：单节点下 Klipper 够用，不引入 L2/BGP。
3. **不广播 Service CIDR 进 tailnet**，只广播 Pod CIDR：跨集群真正需要的只有 pod 可达性
   与 NodePort。
4. **跨集群认证链路不绑 Service CIDR**：homelab 的 ForwardAuth 改走公网
   `oauth.meirong.dev`，减少对静态路由的运行时依赖。

## Consequences

- ✅ Hubble 成为第 9 层安全的现役能力（也是仅有的那一层：至今**没有自建
  CiliumNetworkPolicy**，集群级默认拒绝是刻意延后的，见 [security.md](../reference/security.md)）。
- ✅ ClusterMesh 后来真的用上了（2026-03-08 双集群 connected）。但它至今是**纯待命能力**：
  两集群 `service.cilium.io/global` Service 都是 0，见 ROADMAP 的已知问题。
- ⚠️ **上面第 1、3、4 条后来都被推翻了**，这正是补写 ADR 的价值 —— 保守选择是当次变更的
  作用域边界，不是永久结论：
  - Traefik 已被 Cilium Gateway API 取代（[gateway-controller-evaluation](gateway-controller-evaluation.md)）。
  - Pod CIDR 子网路由 2026-07-07 也移除了，Tailscale 只剩节点 /32；pod↔pod 改走
    ClusterMesh VXLAN（[tailscale-network.md](../reference/tailscale-network.md)）。
  - 入口层共享 SSO 整个撤掉，改为应用原生 OIDC（[app-native-oidc-sso](app-native-oidc-sso.md)）。
- ☠️ **代价：Cilium 成了单点复杂度来源**，且它的故障多数是静默的。已发生的三类：
  Gateway API CRD 版本不配套 → 控制器整个不初始化、旧路由照常 200
  （[复盘](../records/2026-08-11-gateway-api-crd-stall.md)）；`--reset-values` 冲掉跨集群
  CA 信任 → ClusterMesh 单向断；identity mark 撞 Tailscale fwmark → 1/256 的 pod 到
  `100.64/10` 全黑洞。三条的判据都在 tailscale-network.md。
- Cilium 是 **manual-helm**（`just deploy-cilium`），刻意不进 ArgoCD：CNI 挂了 GitOps 也就跟着挂，
  自管自己是鸡生蛋。版本 pin 在 [`versions.just`](../../versions.just)，两集群共享。

## 重新评估条件

CNI 本身不打算再换 —— 迁移成本高且当前没有未满足的诉求。以下变化只影响**配置**不影响选型：
节点数变化（L2/BGP 是否值得）、真正开始用跨集群 Service（ClusterMesh 从待命转生产）、
或决定做集群级默认拒绝（第 9 层从可见性推到管控）。
