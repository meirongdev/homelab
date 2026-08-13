# storage-106 上的 k3s-exp 实验田：独立小集群，不是 homelab worker

> 日期: 2026-08-13
> 状态: ❌ 已被取代（同日）→ [storage106-as-homelab-worker](storage106-as-homelab-worker.md)
>
> ⚠️ **本文不代表现状。** 同日运维者指示反转：那台 VM 已拆掉 k3s-exp、以
> `k8s-worker-106` 身份加入 homelab 集群。下面「否决入集群 worker」的账**估算偏保守**
> ——实测 3G VM 入伙后 requests 只占 928Mi/2311Mi(40%)、available 仍有 2130MB，
> 远好于本文估的「只剩 0.5–0.9G」。保留本文是为了那笔账的推导过程和 8G 内存三方分配，
> 结论以取代者为准。

## Context

需要一块实验田分担 homelab k3s 的"折腾压力"——实验性负载（试镜像、试 chart、
试配置）目前只能上 prod 集群，试错的爆炸半径落在 prod 上。最初的提案是
**在 106 上开 2c2g VM 加入 homelab 集群当 worker**。

106 现状（2026-08-13 实测）：Celeron J4105（4 核 1.5GHz，全舰队最慢核）、
8G 内存（available 仅 1.5G，ZFS ARC 顶着 4G 上限）、白天 load ~0.3 纯空转；
自 2026-07-11 起角色是纯冷备份目标（restic 夜备 + vzdump 周备），
[storage-106-host-specs 早有结论](cluster-placement-for-new-services.md)：
不适合当算力节点（内存受限 + 存储爆炸半径）。

## Decision

**开 2c/3G 的独立 VM（k3s-exp），里面跑独立单节点 k3s，不加入 homelab 集群。**
配套把 ZFS ARC 上限 4G→2G 腾内存。

否决"入集群 worker"的账（都是实测/可推的数字）：

| | 2G worker 入集群 | 3G 独立集群（本决策）|
|---|---|---|
| 入伙税 | cilium-agent(~430Mi)+envoy+k3s agent+otel/tetragon DS ≈ **1.1-1.5G** | k3s 默认栈（flannel，禁 traefik/servicelb）≈ **0.7-1G** |
| 实验可用 | ~0.5-0.9G | **~2G** |
| 爆炸半径 | 实验 OOM/CrashLoop 打 prod 告警；node NotReady 惊动全链 | 归零——挂了没人被叫醒，destroy/apply 重建 |
| 106 与 prod 的耦合 | worker 下线=prod 事件，**推翻 2026-07-11 的解耦决策** | VM 非 prod，解耦不变量完好 |
| 有状态负载 | 反正来不了（PVC 全是 local-path，钉死在 k8s-node）| 不适用 |

8G 的分配：ARC 2G（106 只是备份**目标**——写入是顺序 pack 文件，ARC 主要服务
夜间 prune/check 元数据，池子 1.2T/10.9T 用 2G 足够；且原 4G 是 2026-07-06 为
NFS 读缓存定的尺寸，NFS 五天后就退役了）+ PVE 宿主 ~2.1G + VM 3G + 余量 ~0.5G
（另有 7.7G 零使用的 swap 兜底）。代价：夜间备份窗口慢一点，可接受。

## 边界（守住这些，解耦才成立）

- **不** join homelab 集群、**不**注册进 ArgoCD、**不**接 `*.meirong.dev` 入口链；
- **不**进备份白名单（实验数据 = 可丢，重建即新生）；
- VM 磁盘在 local-lvm（boot SSD），**不**碰 mrstorage 备份池；
- 访问走 LAN 直连（`~/.kube/k3s-exp.yaml`），出问题影响面止于实验本身。
  ⚠️ 工作机（macOS）未授权"本地网络"时 kubectl 直连会报 `no route to host`——
  那是 TCC 不是网络，用 `just exp-tunnel` 走 loopback 即可，
  详见 [records/2026-08-13-macos-local-network-tcc.md](../records/2026-08-13-macos-local-network-tcc.md)。

## Consequences

- IaC 落点：VM = `proxmox/terraform-storage/`（独立 root + state；两台 PVE 的
  API 从工作机都存在 :8006 不通的路径怪象，root 分离保证任一台失联不锁另一个，
  justfile 内置 SSH 隧道）；ARC/k3s = `proxmox/ansible`（`storage-arc-limit` /
  `exp-k3s` / `exp-kubeconfig` 三个配方）。
- k3s 版本与 prod 同（v1.34.5+k3s1），实验结论可平移；但网络栈是 flannel 不是
  Cilium——**涉及 CNI/Gateway API 行为的实验结论不可直接平移**，这类还得在
  prod 集群灰度。
- 106 的监控（node-exporter/smartctl）覆盖宿主，VM 内部无监控接入——刻意的，
  实验田不值得占中枢 Prometheus 的 series 预算。
- amd64 补位：oracle 是 arm64，只有 x86 镜像的东西可以先在这儿试。
