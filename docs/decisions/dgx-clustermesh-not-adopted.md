# DGX Spark 不接 ClusterMesh：节点 IP 平面跨不过 Tailscale 节点共享，改用 Endpoints 直连

> 日期: 2026-08-13
> 状态: ❌ 否决 ClusterMesh 对接：改用 Service + Endpoints 直连（重评条件见文末）
> 关联：[reference/tailscale-network.md](../reference/tailscale-network.md)（共享节点 / MTU / 跨集群 underlay 的**唯一真相源**）·
> [ROADMAP #5 DGX Spark 入编](../ROADMAP.md) · [cluster-placement-for-new-services](cluster-placement-for-new-services.md)
> 对端仓库：`~/projects/meirongdev/nv-dgx-spark`，其 `docs/k3s-migration-design-cn.md` §6 是本决策的提问方；
> **该文档 §6.1 对 homelab 的三条假设已被本文实测推翻**。

## Context

2026-08-13 两台 DGX Spark（GB10，各 128GB）从 systemd + docker 迁到**双节点 k3s + Cilium 1.19.6**
集群，跑 DeepSeek-V4-Flash 双节点 TP=2 推理。该集群从设计阶段就为「将来接 homelab」预留了接口
（`cluster.id` / Pod·Service CIDR / MTU，其设计文档称"装完不可改"），并在 §6.1 把 homelab 侧前提
写成**假设**、在 §9 列为待确认项。

本次评估把那些假设逐条对着实物核了一遍。结论是接口约定里**只有 CIDR 那一条成立**，
而真正的阻塞项是设计文档没有考虑到的一层：**那两台机器不在本 tailnet 里**。

### 实测到的三集群状态（2026-08-13）

| | homelab | oracle-k3s | dgx-spark |
|---|---|---|---|
| `cluster.id` | 1 | 2 | 1 ⚠️ 与 homelab 撞 |
| Pod CIDR | 10.42.0.0/16 | 10.52.0.0/16 | 10.44.0.0/16 ✅ 三方不重叠 |
| Service CIDR | 10.43.0.0/16 | — | 10.45.0.0/16 ✅ |
| **节点 IP（= VXLAN 隧道端点）** | 10.10.10.10 | 10.0.0.26 | 192.168.200.101/102 ⚠️ |
| Cilium（实测镜像 digest） | v1.20.0 | v1.20.0 | **v1.19.6** ⚠️ 差一个 minor |
| tailnet | `meirongdev@`（`taild162e5`） | 同左 | **`kaixinhuang3307@`（`tailf63175`）** ⚠️ 外部 |

### 设计文档 §6.1 的假设 vs 实物

| §6.1 假设 | 实际 |
|---|---|
| homelab 是 `cluster.id=2` | 是 1；`2` 早被 oracle-k3s 占用 |
| 两侧同一 minor 为佳 | homelab/oracle 已是 1.20.0，DGX 1.19.6 |
| 两侧节点 IP 经 Tailscale subnet route 互通 | 做不到，见阻塞项 1 |
| Pod/Service CIDR 不重叠 | ✅ 成立（当初刻意避开 k3s 默认值这步做对了） |

## Options

| 方案 | 结论 |
|---|---|
| **ClusterMesh 对接（设计文档 §6 原方案）** | ❌ 否决：阻塞项 1 不在我们控制范围内，见下 |
| DGX 重装 k3s，`--node-ip` 改到 Tailscale IP | ❌ 否决：主动推翻 DGX §4.1「控制面不依赖 Tailscale」的决定；在全程 DERP、74ms 的链路上 NotReady 抖动几乎必然 |
| 把两台 DGX 迁进本 tailnet，再两侧加 subnet router | ❌ 不由我们决定：需要 `kaixinhuang3307@` 账号配合；且收益仍不足（见 Consequences） |
| **homelab 侧建 Service + 手写 Endpoints 指向 DGX Tailscale IP** | ✅ 采纳：零 CNI 改动、零 `cluster.id` 迁移、零跨集群 CA 维护，DGX 侧一行不改 |

## Decision

**不接 ClusterMesh。** 三个阻塞项里两个便宜（`cluster.id`、Cilium 版本），
第一个是结构性的且不在本仓库能改的范围内。

### 阻塞项 1（结构性）：跨集群节点 IP 平面不存在，且补不出来

ClusterMesh 的 tunnel 模式把 pod→远端 pod 流量做 VXLAN 封装，
**发往 CiliumNode 对象里记录的那个节点 IP**。实测这些值双向都不可达：

```
$ kubectl --kubeconfig ~/.kube/dgx-spark.yaml get ciliumnodes \
    -o custom-columns='NAME:.metadata.name,ADDRESSES:.spec.addresses[*].ip'
spark-2435   192.168.200.102,10.44.0.184      # 背靠背直连网段，对外无路由
spark-ccf3   192.168.200.101,10.44.1.165

DGX     → ping 10.10.10.10      2 packets transmitted, 0 received, 100% loss
homelab → ping 192.168.200.101  2 packets transmitted, 0 received, 100% loss
```

设计文档 §6.2 的补救办法是两侧 Tailscale subnet router 互相通告。**这条路在这里是封死的**：
那两台机器属于 `kaixinhuang3307@gmail.com` 的 tailnet，经节点共享进入我们的 netmap
（机制与既有约束见 [tailscale-network.md](../reference/tailscale-network.md) 的
"Tagged devices cannot reach *shared* nodes" 一节）。
**节点共享只共享设备本身，不携带 subnet route 与 exit node**，所以 `pve` 的
`10.10.10.0/24` 到不了 DGX，DGX 通告 `192.168.200.0/24` 我们也收不到。

配套证据（都在 DGX 侧实测）：

```
tailscale debug prefs   → "RouteAll": false          # --accept-routes 没开
ip route get 10.10.10.10 → via 10.14.20.1 dev enP7s7  # 落到自己 LAN 默认网关，黑洞
TCP 100.94.186.7:32379   → 不通                       # homelab clustermesh NodePort
tailscale ping 100.94.186.7 → pong via DERP(sin) 64ms  # ← 通，但这不是放行证据
```

⚠️ **`tailscale ping` 通 ≠ 端口可达。** 它是路径层探测，不过 ACL 包过滤器。
判据要用真实 TCP 连接。跨 tailnet 的 ACL 还要两边各自改，
而 DGX 那侧的 tailnet 归外部账号管，不是 `tailscale/terraform` 能覆盖的。

### 阻塞项 2：`cluster.id` 撞车（便宜但必须动 DGX）

homelab=1、oracle=2，DGX 也是 1。ClusterMesh 要求全网唯一，撞 id 不是"性能差"而是
**身份空间重叠**。要改就改 DGX 到 `id: 3`：homelab 是三者中唯一同时挂着 Gateway、
跑有状态负载、且已与 oracle 建好跨集群 CA 互信的一侧
（那份互信被 `--reset-values` 冲掉过，静默失守约一个月，见 [ROADMAP](../ROADMAP.md) 的 ClusterMesh 待命说明）。

### 阻塞项 3：Cilium 差一个 minor

homelab/oracle v1.20.0 vs DGX v1.19.6。ClusterMesh 要求各集群同 minor，
差一个 minor 只在升级窗口内可容忍，不是稳态。`k8s/helm/justfile` 头部已记着上一次
版本劈叉的账（1.19.1 → 1.20.0 一次例行部署跟着 chart repo 走），别再制造第二次。

### 链路质量：全程 DERP 中继

```
homelab → DGX   via DERP(hkg)  74–82ms   direct connection not established
DGX → homelab   via DERP(sin)  64ms      direct connection not established
吞吐（20MB, ssh dd）           2.28 MB/s ≈ 18 Mbit/s
```

比 `nv-dgx-spark/docs/china-network-mirrors-cn.md` 记的 0.15 MB/s 好不少，但仍是
**第三方中继在中间的 WAN 级链路**，且两个方向走不同 DERP 节点（hkg / sin），路径非对称。
5 次 ping 后仍未打洞成功。ClusterMesh 会把 clustermesh-apiserver 的 etcd watch
**常驻**在这条链路上：那才是真正的风险，而不是数据面慢。

### 采纳的替代方案

设计文档 §6.3 说接 mesh 的目的只有两个，其中"观测融合"**今天已经在跑**
（homelab Prometheus 经 Tailscale 抓两台 DGX 的 node_exporter / smartctl_exporter）。
剩下"homelab 的 Pod 用集群内 DNS 名调 V4-Flash"用手写 Endpoints 即可：

```yaml
# homelab 侧；DGX 侧零改动
apiVersion: v1
kind: Service
metadata: { name: deepseek-v4-flash, namespace: <ns> }
spec:
  clusterIP: None
  ports: [{ port: 8000, targetPort: 8000 }]
---
apiVersion: v1
kind: Endpoints
metadata: { name: deepseek-v4-flash, namespace: <ns> }
subsets:
  - addresses: [{ ip: 100.97.87.120 }]     # V4-Flash head 的 Tailscale IP
    ports: [{ port: 8000 }]
```

⚠️ **只有 homelab 能这么做，oracle 不能**：oracle 的 `node0` 是 `tagged-devices`
（tailnet 所有，非用户所有），共享节点根本不在它的 netmap 里。
oracle 侧若要消费 DGX，仍需 homelab 上的代理（历史方案 `dgx-proxy` 已随旧 LLM 网关于
2026-08-08 退役），细节见 [tailscale-network.md](../reference/tailscale-network.md)。

## Consequences

- **不获得**跨集群 pod↔pod 可达与 Cilium global Service 语义。当前只需要调一个 HTTP
  端点，这不是损失。
- DGX 集群保持 `cluster.id=1` / `--node-ip 192.168.200.x` 不变，**其设计文档 §4.2 声称的
  "ClusterMesh-ready" 实际不成立**，接口约定里只有 CIDR 规划有长期价值。
- homelab↔oracle 的既有 ClusterMesh 不受影响，仍是[纯待命能力](../ROADMAP.md)。
  本决策**顺带削弱了保留它的理由**：第三个集群不会加入，global Service 计数仍为 0。
- ROADMAP #5「DGX Spark 入编」的网络部分到此有答案：**走 Tailscale + Endpoints，不走 mesh**。
  该项剩余内容（推理服务 IaC、dcgm 指标、双机 fallback、SLO）与本决策无关，继续开放。

## 顺带查出的两处 MTU 配置缺陷

评估过程中实测了两侧 MTU（`ip link show cilium_vxlan` 与 pod 侧 `lxc*`），
**两个集群都是 vxlan 1280 / pod veth 1280**，与 [tailscale-network.md 的 MTU 一节](../reference/tailscale-network.md)
描述一致（可用内层上限 1230，1231–1280 窗口 ICMP/UDP 静默丢弃、TCP 实践中无影响）。
那一节是**准确的**；但另外两处不是：

1. **DGX 的 `mtu: 1200` 是个拼错的键名，从未生效。** Cilium chart 的键是 `MTU`（全大写），
   `helm show values cilium/cilium --version 1.19.6 | grep '^MTU'` → `MTU: 0`。
   Helm 对未知键不报错，静默忽略：所以 DGX 设备停在自动探测的 1280。
   **这是运气**：真生效了就会复刻 2026-07-07 那次黑洞（显式 MTU 时 Cilium 不减隧道开销）。
2. **`k8s/cilium/values.yaml` 的注释说 "automatically gives pods 1280-50=1230"，与实测不符**
   （pod veth 实为 1280）。结论"不要显式设 MTU"没错，错的是对结果状态的描述。
   已按 R6 改成指向 reference/，不在 values 里维护第二份副本。

## 重新评估条件（满足其一再议）

- 两台 DGX **迁入本 tailnet**（不再是共享节点），且两侧各有 subnet router 通告节点网段；
- `tailscale ping` 显示 **direct**（非 DERP）且吞吐进入可用区间：当前 2.28 MB/s 不够；
- 出现真实的 **pod↔pod** 跨集群需求（不只是调一个 HTTP 端点），
  例如把 DGX 纳入统一的服务网格或需要 Cilium NetworkPolicy 跨集群生效。

三条里第一条是前置：不满足它，后两条无从谈起。

## 复现本文数据

```bash
# 三集群 cluster.id / CIDR / 节点 IP
kubectl --context k3s-homelab get ciliumnodes \
  -o custom-columns='NAME:.metadata.name,ADDRESSES:.spec.addresses[*].ip'
kubectl --kubeconfig ~/.kube/dgx-spark.yaml -n kube-system get ds cilium \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
helm --kubeconfig ~/.kube/dgx-spark.yaml get values cilium -n kube-system

# 节点 IP 平面（决定性证据）
ssh -i ~/.ssh/vgio ubuntu@100.94.186.7 'ping -c 2 -W 2 192.168.200.101'
ssh -i ~/.ssh/vgio admin@100.97.87.120 'ping -c 2 -W 2 10.10.10.10; tailscale debug prefs | grep RouteAll'

# 链路质量（从 homelab 侧打，Mac 的结果不代表 homelab 的路径）
ssh -i ~/.ssh/vgio ubuntu@100.94.186.7 'tailscale ping -c 5 100.97.87.120'
```
