# storage-106 的 VM 改为 homelab 集群的 worker（取代同日的「独立实验田」决策）

> 日期: 2026-08-13
> 状态: ✅ 已完成
>
> 本决策**取代** [storage106-experiment-vm](storage106-experiment-vm.md)（同日，几小时前）。
> 那份的结论是「独立小集群、不入 homelab」；本决策由运维者明确指示反转。

## Context

同一台 VM（`192.168.50.107`，2 vCPU / 3G / 29G，宿主 storage-106）在 2026-08-13 上午
按前一份决策装成了**独立单节点 k3s（k3s-exp）**。当天稍晚运维者指示改为
**加入 homelab 集群当 worker**。

前一份决策否决 worker 形态的理由是「入伙税」：DaemonSet + cilium-agent + k3s agent
约 1.1–1.5G，2G VM 只剩 0.5–0.9G 可用。**实测下来这笔账偏保守**（见下）。

## Decision

**VM 以 k3s agent 身份加入 homelab 集群，节点名 `k8s-worker-106`。**
`k3s-exp` 形态被拆除（两者互斥：同机不能既是 k3s server 又是别的集群的 agent；
拆除时它只有 coredns/local-path/metrics-server，13 小时、零数据）。

IaC 落点：
- `k8s/ansible/playbooks/setup-k3s-worker.yaml` + `just join-worker`
- `k8s/ansible/playbooks/setup-tailscale.yaml` 扩到 `k8s_cluster`，`just setup-tailscale-worker`
- `tailscale/terraform` 新增 `tailnet_key.homelab_worker`（旧的 `homelab` 是 `reusable=false`，已被控制面消费）
- `proxmox/ansible` 的 `exp-k3s` / `exp-kubeconfig` / `exp-tunnel` 三条配方退役

## 实测入伙税（2026-08-13，节点 Ready 后）

| | 前一份决策的估算（2G VM） | 本次实测（3G VM） |
|---|---|---|
| allocatable 内存 | — | **2311Mi** |
| 已 requests | 1.1–1.5G | **928Mi（40%）** |
| 已 requests CPU | — | 270m / 1800m（15%） |
| `free -m` available | 0.5–0.9G 可用 | **2130 MB** |

实际排上来的只有 4 个 DaemonSet pod：`cilium`、`cilium-envoy`、`node-exporter`、
`otel-collector-agent`（tetragon 也在）。**估算偏保守**——3G 的 VM 留给负载的
远不止 0.5–0.9G。这是本决策成立的主要数据支撑。

## ⚠️ 三条与控制面不同、错了会静默失效的约束

全部写进了 `setup-k3s-worker.yaml` 的文件头，这里只列索引：

1. **网络**：worker 在 `192.168.50.0/24`，控制面在 `10.10.10.0/24`（pve `vmbr0` 的第二
   地址段）。靠一条 netplan 静态路由经 pve 转发（实测 RTT 0.8ms）。
2. **ip rule**：worker 带 `--accept-routes` 会从 pve 学到 `10.10.10.0/24` 进 table 52，
   优先级高于 main → 控制面流量被劫进隧道。收敛器多一条
   `5240 to 10.10.10.0/24 lookup main`。☠️ **不能用 5250**，那被 tailscaled 自己占着。
3. **必须装 Tailscale**，但**不是为了连通**（LAN 路由已够）。两个真实理由：
   - `otel-collector-agent` 是 DaemonSet，exporter 写死 oracle 的 tailnet NodePort
     （`100.107.166.37:31080/31317`）。节点不在 tailnet 上 = 日志/追踪**静默断流**。
   - MTU：Cilium 按**每节点各自**的最低设备定 MTU。实测控制面的
     `cilium_vxlan`/`lxc*` 均 **1280**（来自 `tailscale0`）。worker 不装则最低是
     eth0=1500，两边 pod MTU 不一致，跨节点大包碎/丢。

## 验收（2026-08-13 实测）

- `kubectl get nodes` → `k8s-worker-106 Ready`，v1.34.5+k3s1，InternalIP 192.168.50.107
- worker 的 `cilium_vxlan` / `lxc_health` MTU = **1280**，与控制面一致
- `pgrep -x kube-proxy` 空、无 `KUBE-SERVICES` 链 —— agent 正确继承了 server 的
  `disable-kube-proxy`（⚠️ 该 flag 是 **server-only**，写进 agent config 会 fatal 拒启）
- 跨节点 Service：worker 上的 pod → 控制面上的 grafana / prometheus 均 **HTTP 200**
- 跨集群：Loki（oracle）近 15 分钟收到 **317 条** 来自 `k8s-worker-106` 的日志

## Consequences

- **106 与 prod 的解耦被主动放弃**。前一份决策把它列为不变量（源自 2026-07-11 NFS
  退役）；现在 106 上的 VM 下线 = prod 集群 node NotReady。这是本次接受的代价。
- 实验田没有了。要重开得另找落点。
- ~~新节点**未进备份白名单**（H4）：目前它上面只有 DaemonSet，无 PVC。~~
  **2026-08-16 已解决**：worker 有了自己的夜备 Job
  （`backup/overlays/homelab/worker-cronjob.yaml`，02:00，`--host homelab-worker`，
  整目录扫不筛 PVC 名）+ 106 上的整机周备 vzdump（`just vzdump-worker`）。
  当时查清的实况：worker 的 PVC 曾是**三重裸奔** —— restic 不覆盖、VM 盘在 `local-lvm`
  不在 `mrstorage` 故 sanoid 拍不到、106 的 `jobs.cfg` 一条 vzdump 都没有。
  ⚠️ CI 的 H4 仍只解析控制面那份白名单，新 PVC 照样要写进去才过 CI。
  细节见 [reference/storage.md](../reference/storage.md)。
- `k8s/cilium/values.yaml` **未改也不需要改**：加节点不涉及 values，Cilium
  DaemonSet 自动排布。（Cilium 仍是 manual-helm。）

## 顺带暴露的既存缺陷（未修）

k8s-node **缺** `to 10.10.10.0/24 lookup main` 的 ip rule（它有 5200/5260，唯独没有
自己那个网段）→ 回程被 table 52 送进 `tailscale0`，pve 发起的 TCP 全部非对称失败。
后果是 `k8s/ansible/inventory/hosts.yaml` 里给 k8s-node 写的 **ProxyCommand 访问路径
一直是坏的**（平时都走 Tailscale 所以没人撞上）。本次靠「token 由 justfile 经
Tailscale 取好再传进剧本」绕开。取证见
[records/2026-08-13-k3s-worker-join-106.md](../records/2026-08-13-k3s-worker-join-106.md)。

## 推翻条件

- 若要恢复实验田，别在这台 VM 上做——先决定 106 是否还要承担 prod 角色。
- 若 106 需要重新与 prod 解耦（例如它要做长时间维护），worker 必须先 drain + 退出集群。
