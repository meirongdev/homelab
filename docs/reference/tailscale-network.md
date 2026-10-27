# Tailscale Cross-Cluster Networking

> Last updated: 2026-10-28
> Status: 生效事实

## 速览

- **模型**：Tailscale 只做节点级 underlay（各节点 /32 + NodePort）；pod↔pod 走
  Cilium ClusterMesh VXLAN（各节点通告 Pod CIDR 的旧设计 2026-07-07 已移除）。
- **通告**：只有 pve 通告 LAN 两段；k8s-node / k8s-worker-106 不通告；Pod/Service CIDR 一律不通告。
- **三张 ip rule（5200 / 5240 / 5260）是结构性的，别删**；优先级别取 5250（tailscaled 占用）。
- **两个致命坑**：k8s-node 别通告自己 /32（路由投毒）· `tailscale up` 到收敛器装上之间有致命窗口。
- **ClusterMesh**：up-but-stuck 且不自愈，重建 pod 即可；`retrieved=true` 才是真判据。

## 三层分工

1. **Tailscale（underlay）**：节点间可达。生产东西向一律走 `节点 TS IP + NodePort`：oracle→homelab
   Loki `:31080` / Prometheus `:31090` / Tempo `:31317` / Vault `:31952`；homelab→oracle ArgoCD `:6443`；
   ClusterMesh 控制面 `:32379` 双向。
2. **ClusterMesh（pod 数据面）**：跨集群 pod↔pod 是两节点 IP 之间的 VXLAN（udp/8472），外层包走 Tailscale。
3. **Cloudflare Tunnel（南北向）**：各集群 cloudflared → 本集群 Cilium Gateway，不经 Tailscale。

node0↔k8s-node 应是 **direct** WireGuard（约 75–87ms），不是 DERP 中继，条件见「直连条件」。

## Underlay 路由：谁通告什么

| 节点 | 通告 | 理由 |
|------|------|------|
| `pve` (100.118.193.51) | `10.10.10.0/24`, `192.168.50.0/24` | 运维访问 LAN；**也承载 oracle→homelab 的 VXLAN 外层包** |
| `node0` (100.107.166.37) | `10.0.0.26/32`（自己的 VCN IP） | 承载 homelab→oracle 的 VXLAN 外层包 |
| `k8s-node` (100.94.186.7) | **无** | 见下方路由投毒 |
| `k8s-worker-106` (100.74.162.97) | **无** | 同上，且它就在 `192.168.50.0/24` 上，pve 正是该段的 subnet router（[ADR](../decisions/storage106-as-homelab-worker.md)） |

Pod/Service CIDR（10.42/10.43/10.52/10.53）不通告。

☠️ **路由投毒：别通告一个本该由别的 tailnet subnet router 送达给你的 IP。** `k8s-node` 绝不能通告
`10.10.10.10/32`：pve 转发该段流量（家用路由 → pve → 10.10.10.0/24），带 `--accept-routes` 会把这条 /32
学进 table 52，table 52 排在它的 main 表前面，于是发往该节点的全部 v4 回程（TCP 握手、DNS 应答、
WireGuard disco）被劫进 tailnet 黑洞，homelab 整条 v4 出网断掉。node0 通告自己的 /32 安全，只因 tailnet
里没有谁转发去往 OCI VCN 的流量。

## ip rule：5200 / 5240 / 5260（结构性，别删）

带 `--accept-routes` 的节点会把 pve 通告的两段装进 table 52，而 tailscaled 的 `5270: from all lookup 52`
排在 main 前面，本该走 LAN 的流量默认进了隧道。pve 常开，是这两段合适的 subnet router；k8s-node 又需要
`--accept-routes`（kubectl 到 K8s API）。所以只能靠更早的 ip rule 把流量钉回来：

| 优先级 | 规则 | 在哪 | 缺了会怎样 |
|---|---|---|---|
| 5200 | `to 100.64.0.0/10 lookup 52` | k8s-node · k8s-worker-106 · oracle | identity 低字节为 `0x08` 的 pod 到整个 `100.64/10` 黑洞（见下节） |
| 5240 | `to 10.10.10.0/24 lookup main` | k8s-node · k8s-worker-106 | 控制面网段被劫进隧道（见下） |
| 5260 | `to 192.168.50.0/24 lookup main` | k8s-node · k8s-worker-106 · pve | 到一跳之遥的 LAN 主机（106 的 restic/vzdump）绕进隧道；worker 连自己网段都会被卷进去 |

k3s 节点上由收敛器 `tailscale-ip-rules.timer` 断言（见「守护」）：homelab 清单是
[`k8s/ansible/playbooks/setup-tailscale.yaml`](../../k8s/ansible/playbooks/setup-tailscale.yaml) 的
`tailscale_assert_rules`（控制面与 worker 同一份），oracle 写死在
[`cloud/oracle/ansible/playbooks/setup-tailscale.yaml`](../../cloud/oracle/ansible/playbooks/setup-tailscale.yaml)
的断言脚本里。pve 的 5260 是手工单元 `nfs-lan-route.service`（无 pve playbook；ifupdown2、不跑 networkd，
不受下文的清扫影响）。

判据（在 k8s-node / k8s-worker-106 上）：

```bash
ip rule list | grep -E '^52[0-9][0-9]:'  # 5200/5240/5260 + tailscaled 的 5210/5230/5250/5270
ip route get 10.10.10.1                   # 不能是 dev tailscale0 table 52
ip route get 192.168.50.106               # 同上
```

**5240 两个节点都要**，死法不同（[records/2026-08-13-k3s-worker-join-106.md](../records/2026-08-13-k3s-worker-join-106.md) §4）：

- worker：控制面在 `10.10.10.0/24`（pve `vmbr0` 的第二地址段），worker 经 pve 转发直连（0.8ms）。缺 5240 时
  k3s agent 与 cilium-agent（`k8sServiceHost: 10.10.10.10`）的流量被劫进隧道，存活挂在 tailnet 上。
- 控制面：自己就在该段，缺 5240 时 pve 发起到 `10.10.10.10` 的 TCP 全部非对称失败（SYN 走 vmbr0 进、SYN-ACK
  走隧道出），inventory 里 k8s-node 经 pve 的 ProxyCommand 随之不通。

☠️ **优先级不能取 5250**：tailscaled 占着 5210 / 5230 / 5250 / 5270，空位只有 **5200 / 5220 / 5240 / 5260**，
且必须 < 5270 才抢得到 `from all lookup 52`。5250 会撞上它的 `fwmark 0x80000/0xff0000 unreachable`。

☠️ **给新节点跑 `setup-tailscale` 有个致命窗口**：`tailscale up` 成功到收敛器装上之间，节点自己的 LAN
流量已被卷进隧道，你正在用的 SSH 当场断。别在窗口内中断剧本；断了就从 tailnet 地址进去补规则
（[经过](../records/2026-08-13-k3s-worker-join-106.md) §1）。

### 5200：Cilium 身份标记撞上 Tailscale 的 fwmark

**症状**：**某一个** pod 到整个 `100.64.0.0/10` 全部超时，同节点其它 pod 正常；没人监听的端口也是超时
而非 `connection refused`；重建 pod 不管用。

**机制**：Cilium 把 endpoint identity 编进 `skb->mark` 高位；Tailscale 的三条防环 ip rule（5210/5230/5250）
匹配 `fwmark 0x80000/0xff0000`，掩码只看 bit16-23，正好压在身份位上：

```
identity & 0xFF == 0x08   →   命中 Tailscale 的规则
```

命中后走 `lookup main`，绕过 `5270: from all lookup 52`（tailscale0 的路由表）；main 没有 `100.64/10`，
CGNAT 包按默认路由从 `eth0` 扔给 LAN 网关，没人回 RST。

⚠️ **1/256 的抽签**：identity 由 pod 标签算出，改标签就重抽。任何一次改标签都可能让一直正常的服务突然
连不上跨集群，也可能让中签的自己好起来。

**定位**：

```bash
# 1) 取 identity，算 identity & 0xFF，是 8 就基本确诊（用 pod 所在节点上的 cilium pod）
kubectl --context <ctx> -n kube-system exec <该节点的 cilium pod> -c cilium-agent -- \
  cilium-dbg endpoint list -o json
# 2) 在该节点上看出接口：坏的走 eth0，好的走 tailscale0
tcpdump -ni any host <100.x 目标>
# 3) 改一次 identity，通了就是它；记得撤掉（x-）
kubectl --context <ctx> -n <ns> label pod <p> x=1
```

☠️ **别去 grep Tailscale 的 netfilter 规则找「谁打的 mark」**：本舰队用 `--netfilter-mode=off`（见两个
`setup-tailscale.yaml` 的 `tailscale_up_extra_args`），它一条 netfilter 规则都不装，但照样装 ip rule。

**修法**：5200（早于 5210）把 `100.64.0.0/10` 钉死到 table 52，对所有 pod 一次性免疫。安全：
`netfilter-mode=off` 下没有任何东西会合法设置 `0x80000`，5210–5250 在这里只会误伤。⚠️ 别改用「给中签的
pod 换标签」，下一个中签的照样断。oracle 同样暴露，中签会切断 otel remote-write 与 krr 打回
`100.94.186.7` 的路径。A/B/A 实验与死路清单：[records/2026-08-09-cilium-identity-fwmark-collision.md](../records/2026-08-09-cilium-identity-fwmark-collision.md)。

### 守护：两道防线 + 指标

开机 oneshot 守不住：systemd-networkd 的 `ManageForeignRoutingPolicyRules` 默认 `yes`，(重)启动/重配时
清扫一切非它管理的 ip rule（unattended-upgrades 重启 networkd 就会触发）；tailscaled 自己的四条有 netlink
监听自愈，自定义规则没有（[records/2026-08-12-tailscale-iprule-guard-drift.md](../records/2026-08-12-tailscale-iprule-guard-drift.md)）。

| 防线 | 机制 | 覆盖 |
|---|---|---|
| 根因 | `/etc/systemd/networkd.conf.d/10-no-foreign-sweep.conf`（`ManageForeignRoutingPolicyRules=no` + `ManageForeignRoutes=no`） | networkd 不再清外来规则/路由（也保护 Cilium 与 table 52 的路由） |
| 兜底 | `assert-tailscale-ip-rules` + `tailscale-ip-rules.timer` 每 5 分钟幂等断言（单次两遍夹 20s） | 任何删除者，失守 ≤5 分钟自愈 |
| 可见性 | node-exporter textfile：`tailscale_iprule_present` / `tailscale_iprule_reasserts_total` | 告警 `k8s/helm/manifests/monitoring/alerts/tailscale-iprule-alerts.yaml` |

- ⚠️ tailscaled 重启**不清**这些规则；`PartOf=tailscaled` 对已死的 oneshot 不触发，所以单元刻意没有
  PartOf，timer 是唯一的重申机制。
- ☠️ 断言行必须逐行展开成真实换行，Jinja `join('\n')` 会塌成一行、规则补不回而「看起来在位」；
  `tailscale_iprule_rules_expected` 对账防的就是这个（[records/2026-08-13-iprule-guard-render-bug.md](../records/2026-08-13-iprule-guard-render-bug.md)）。

## 数据路径

```
[Homelab Pod 10.42.x.x]  (veth, MTU 1280)
        │ Cilium BPF: dst belongs to remote cluster (ClusterMesh endpoint sync)
        ▼
[VXLAN encap]  outer: 10.10.10.10 → 10.0.0.26, udp/8472, ≤1280 bytes
        │ table 52: 10.0.0.26 dev tailscale0  (node0's self-advertised /32)
        ▼
[WireGuard, direct]  ~75ms
        ▼
[node0]  firewalld: tailscale0 trusted, 8472/udp open → VXLAN decap → pod
```

反向：node0 的外层目的 `10.10.10.10` 走 **pve** 的 `10.10.10.0/24` 路由（WG → pve → vmbr0 → k8s-node；
pve 把外层 SNAT 成 10.10.10.1，VXLAN 无状态，无害）。

### MTU — do NOT set it explicitly

Cilium 自动探测 MTU（最低设备 tailscale0 = 1280），跨集群可用内层包上限 **1230**（1280 − 50 VXLAN）。
1231–1280 的 ICMP/UDP 静默丢弃（BPF drop，不回 Frag-Needed）；TCP 实践中不受影响。**Cilium values 里
永远别写显式 `MTU:`**：显式值不扣隧道开销，pod 与 vxlan 设备拿到同一个数，顶部 50 字节黑洞（MTU=1200
时内层 >1150 全丢）。

### 递归防护

tailscaled 把本机所有地址都列为 WG 候选 endpoint，包括 `cilium_host`（10.42.0.x / 10.52.0.x）。mesh 通了
以后对端能经 mesh 本身「到达」它并选它当 endpoint，WG-over-VXLAN-over-WG，公网路径永远赢不了。两侧都用
`tailscale-no-cni-endpoint.service`（iptables）丢弃到/从 CNI 网段的 udp/41641，两个 `setup-tailscale.yaml`
各一份，CIDR 互为镜像。

☠️ **node0 上 firewalld direct 规则必须为 0 条。**只要有一条，firewalld 2.x 每次 start/stop/reload 都
flush 全部 iptables 表，连 Cilium 的 masquerade 链一起清，pod 出站断到 Cilium 重装为止；needrestart 例行
升 libssl/python/libc 后就会重启 firewalld。`just oracle verify-node` 断言该数为 0
（[records/2026-10-01-oracle-firewalld-flushes-cilium-iptables.md](../records/2026-10-01-oracle-firewalld-flushes-cilium-iptables.md)）。

### 直连条件

- OCI security list 与 firewalld public zone 都要放行 **udp/41641**（`cloud/oracle/terraform/main.tf`），
  否则到 node0 的所有路径都走 DERP 中继（遥测 + mesh 每天 GB 级）。
- k8s-node 收不到主动入站 UDP（pve + 家用路由双层 NAT，无端口转发），直连靠它主动向 node0 公网 41641
  发起，够用。

## Tailscale Tags and ACL

| Tag / owner | 节点 | 自动批准的路由 |
|-------------|------|---------------|
| `tag:oracle` + meirongdev@gmail.com | node0 | 10.0.0.26/32 |
| meirongdev@gmail.com（**无 tag**） | k8s-node | 无（不许通告） |
| meirongdev@gmail.com | pve | 10.10.10.0/24, 192.168.50.0/24（控制台手工批准） |

⚠️ `k8s-node` 某次重注册时没带 `tag:homelab`，是用户设备，按 tag 的 autoApprovers 匹配不到它，所以 ACL
在 node0 那条路由的 autoApprovers 里保留了用户账号。ACL（`tailscale/terraform/main.tf`）：成员与两个 tag
都能访问 `*:*`。

### ☠️ Tagged devices cannot reach *shared* nodes

不是 ACL 问题。两台 **DGX Spark**（`100.97.87.120` 推理主机；`100.67.164.92` 第二台，跑 `fndgx` vLLM 栈；
两台的 k3s 已于 2026-09-20 移除）属于别人的 tailnet（`*.tailf63175.ts.net`，owner `k***@`），经
**节点共享**进入我们的 netmap。共享授予的是**人**不是 tailnet：`meirongdev@` 名下的设备（k8s-node、两台 Mac、
pve）看得到；node0 是 `tagged-devices`（归 tailnet 不归用户），netmap 里根本没有它们，所以放宽 ACL 没用
（`tag:oracle` 早就是 `*:*`）。判据：

```
oracle node0     → tailscale ping 100.97.87.120        → "no matching peer"
oracle node0     → tailscale status                    → 没有任何 shared peer
homelab k8s-node → curl 100.97.87.120:8888/v1/models   → 200
```

- **共享只带设备本身，双向都不带 subnet route 与 exit node**：Sparks 到不了 `10.10.10.10`（pve 的路由对它们
  不可见），它们的 `192.168.200.101/102`（两机背靠背 NCCL 链路）我们也收不到。ClusterMesh VXLAN 的封装目标
  正是双方节点 IP，所以 DGX 接不进 mesh：[dgx-clustermesh-not-adopted](../decisions/dgx-clustermesh-not-adopted.md)
  （另含 `cluster.id` 冲突与 DERP-only 2.28 MB/s 链路）。
- ⚠️ 对共享节点 `tailscale ping` 成功时真实 TCP 可能照样失败（对 homelab `:32379` 验证过）：它是路径层探测，
  不经 ACL 包过滤，别拿它当端口可达的证据。
- homelab 消费 DGX 用普通 Service + 手写 `Endpoints` 指向 Spark 的 Tailscale IP，不涉及 CNI。
- ⚠️ **把 node0 去 tag 不是小改动**：OAuth client 只能创建 tagged 设备，node0 用的是 `tags = ["tag:oracle"]`
  的预授权 key。改用户设备要用户 key 重认证，期间掉出 tailnet（ClusterMesh underlay 断）；用户设备有
  **180 天 key 过期**，必须到控制台关掉，漏了就是几个月后静默掉线。autoApprovers 不受影响
  （`10.0.0.26/32` 同时列了 `tag:oracle` 与用户账号），真正的风险是 key 过期。
- **采用的绕法是代理能力，不搬节点**：oracle 要用 DGX 只能经 homelab 上的代理。原跨集群 global Service
  `dgx-proxy` 已于 2026-08-08 随旧 LLM 网关退役，接替者是 homelab 的 LiteLLM（[litellm-gateway.md](litellm-gateway.md)），
  两集群 global Service 计数为 0。oracle 侧 `calibre-metadata-llm` 的接法与现状以
  `cloud/oracle/manifests/calibre-metadata/metadata-llm.yaml` 文件头为准。
- ⚠️ **Cilium global Service 要两个集群都有 Service 对象**：只注解一侧时对端 `cilium-dbg status --all-clusters`
  能看到 `1 services`，pod 却 `Could not resolve host`。backend 合并进的是本地 Service，`*.svc.cluster.local`
  记录来自本集群 CoreDNS，所以对端要有同名、无 backend 的影子 Service。

## homelab 节点的集群 DNS（相关）

10.10.10.0/24 段到任何公网解析器的 53 端口都不通，只有 ISP 的 IPv6 解析器（eth0 RA/DHCPv6）可用，而 pod
没有 IPv6。设计：`pods → CoreDNS → 10.10.10.10:53（systemd-resolved DNSStubListenerExtra）→ ISP v6`，由
`k8s/ansible/playbooks/fix-dns-fallback.yaml` 管理。⚠️ 别往 `/etc/rancher/k3s/resolv.conf` 写公网解析器，
cloudflared 会 CrashLoopBackOff。

## 文件

- `tailscale/terraform/`：ACL + 预授权密钥（`main.tf`），OAuth client 凭据放 `.env`（模板 `.env.example`），
  配方看 `just --list`。
- 两个 `setup-tailscale.yaml` 都是共享 role `tailscale/ansible/roles/tailscale_node` 的薄封装，集群差异
  （up 参数、firewalld、UDP GRO、对端 CIDR）走 playbook vars。
- tailnet 已建好；重建集群走 [runbooks/oracle-k3s-rebuild.md](../runbooks/oracle-k3s-rebuild.md) 与
  [runbooks/homelab-rebuild-ubuntu-24-04.md](../runbooks/homelab-rebuild-ubuntu-24-04.md)（`just setup-tailscale`）。

## Verification

```bash
# 任一 tailnet 设备上：k8s-node 那一行应是 direct，不是 relay
tailscale status

# table 52 里只有 underlay 路由：homelab 节点应见 node0 的 /32，oracle 节点应见 pve 的 10.10.10.0/24
ssh ubuntu@100.94.186.7    'ip route show table 52 | grep 10.0.0.26'
ssh ubuntu@100.107.166.37  'ip route show table 52 | grep 10.10.10.0/24'

# ClusterMesh 数据面：pod→pod 双向，含最大内层包。CoreDNS pod IP 要现取，写死的会随
# pod 重建失效，表现为 Cilium "Stale or unroutable IP" drop
HL=$(kubectl --context k3s-homelab get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')
OR=$(kubectl --context oracle-k3s  get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')
kubectl --context k3s-homelab run t1 --rm -i --restart=Never --image=busybox:1.36 -- ping -c3 -s 1202 $OR
kubectl --context oracle-k3s  run t2 --rm -i --restart=Never --image=busybox:1.36 -- ping -c3 -s 1202 $HL

# 节点 IP + NodePort 的生产路径（在对应的源节点上跑）
nc -z 100.107.166.37 6443    # homelab → oracle K3s API (ArgoCD)
nc -z 100.94.186.7  31090    # oracle → homelab Prometheus remote-write
```

## ClusterMesh Reconnect After Rebuild

任一集群重建，或任一侧跑完 `deploy-cilium`（哪怕只改了 resources）之后，都要重跑 connect，用 Tailscale NodePort 端点，不用 LAN 私网 IP：

```bash
cd k8s/helm
just connect-clustermesh 100.94.186.7:32379 100.107.166.37:32379
```

原因：重建的集群会自签新 Cilium CA；残留的 `cilium-clustermesh` remote config 可能让 `kvstoremesh` 断着而
节点级 ClusterMesh 仍显示 connected；本环境必须 `--allow-mismatching-ca`，把对端 CA 追加进信任 bundle 而不是
拒掉。健康输出必须同时有 `All 1 nodes are connected to all clusters` 与
`All 1 KVStoreMesh replicas are connected to all clusters`。

### 两个 secret，别把正常的当成配错了

| secret | 谁读 | 内容 | 正常值 |
|---|---|---|---|
| `cilium-clustermesh` | cilium-agent | 连本集群自己的缓存 | `https://clustermesh-apiserver.kube-system.svc:2379` |
| `cilium-kvstoremesh` | kvstoremesh 容器 | 连对端 | `https://<peer>.mesh.cilium.io:32379` |

⚠️ 前者指向集群内 DNS 名是**设计如此**：KVStoreMesh 下 agent 只读本地缓存，跨集群那一跳由 kvstoremesh 负责。
`<peer>.mesh.cilium.io` 靠 **`clustermesh-apiserver` Deployment 的 `hostAliases`** 解析（不是 cilium DaemonSet 的）：

```bash
kubectl --context k3s-homelab -n kube-system get deploy clustermesh-apiserver \
  -o jsonpath='{.spec.template.spec.hostAliases}'
#   期望 [{"hostnames":["oracle-k3s.mesh.cilium.io"],"ip":"100.107.166.37"}]
```

### 正确的诊断姿势

摘要行的 `N/1 remote clusters ready` 不够，要 `--all-clusters`：

```bash
kubectl --context oracle-k3s exec -n kube-system ds/cilium -c cilium-agent -- \
  cilium-dbg status --all-clusters | sed -n '/ClusterMesh/,/^[A-Z]/p'
```

- `remote configuration: expected=true, retrieved=true`：**retrieved 才是真连上**。`retrieved=false` 且
  `etcd: 1/1 connected` = agent 连上了本地缓存而缓存里没有对端数据，即 **kvstoremesh 那一跳断了**。
- `synchronization status` 的 nodes/endpoints/identities/services 应全 `true`，endpoints/identities 计数非 0。
- ⚠️ **别用 pod 的 `startTime` 推断「断了多久」**：节点重启后 DaemonSet pod 对象不变、只有容器重启，
  `(last: never)` 只覆盖当前容器进程，要看 `state.running.startedAt`：

```bash
kubectl --context k3s-homelab -n kube-system get pods -l k8s-app=cilium -o \
  jsonpath='{range .items[*]}{range .status.containerStatuses[?(@.name=="cilium-agent")]}{.state.running.startedAt}{" restarts="}{.restartCount}{"\n"}{end}{end}'
```

### peer 配置在哪

| 集群 | values 文件 | 部署入口 |
|---|---|---|
| homelab | [`k8s/cilium/values.yaml`](../../k8s/cilium/values.yaml) | `cd k8s/helm && just deploy-cilium`（`ctx := "k3s-homelab"`） |
| oracle | [`cloud/oracle/values/cilium.yaml`](../../cloud/oracle/values/cilium.yaml) | `cd cloud/oracle && just deploy-cilium` |

`clustermesh.config.clusters[].ips` 是真源，同时生成 `cilium-kvstoremesh` 的 endpoint 与 clustermesh-apiserver
的 `hostAliases`。**两个 `deploy-cilium` 都带 `--reset-values`**，缺了这段就是跑一次删一次。

☠️ **任一侧跑完 `deploy-cilium` 都要接着跑一次 `just connect-clustermesh`**，不只是集群重建：`--reset-values` 会冲掉
connect 交换来的跨集群 CA 信任（证书不入库，values 保不住），上面那段只保住 endpoint。断开时
`cilium-dbg troubleshoot clustermesh` 六项全 ✅，真判据是 `cilium status` 的 `remote configuration: retrieved=false`
与对端 etcd 容器日志 `tls: bad certificate`（2026-08-10 实测，见 `cloud/oracle/values/cilium.yaml` 同位注释）。

### 真实故障模式：up-but-stuck，且不自愈

clustermesh-apiserver 可能活着但卡住，配置一字未变，Cilium 不会自己恢复：

```bash
# 1) 先看 helm release 历史，确认配置到底有没有变过（别从当前状态倒推根因）
kubectl --context <ctx> -n kube-system get secret -l owner=helm,name=cilium -o name
#    取最后几个版本，解 .data.release（base64 两次 + gunzip）看 config.clustermesh.config.clusters
# 2) 配置没变 → 就是卡死，重建 pod 即可，不必动配置
kubectl --context <ctx> -n kube-system rollout restart deploy/clustermesh-apiserver
```

告警兜底：`ClusterMeshRemoteClusterNotReady` 等 5 条（[observability-alerting-slo.md](observability-alerting-slo.md)）。
**没有做自愈**：两集群 global Service 都是 0，纯待命能力不值得加探针。经过：
[records/2026-08-05-clustermesh-up-but-stuck.md](../records/2026-08-05-clustermesh-up-but-stuck.md)。

## Pre-auth Key Renewal

密钥 90 天过期。过期后：

```bash
cd tailscale/terraform
just apply   # 生成新密钥，已在线的节点不受影响

# 只有节点被注销时才需要在节点上重跑
cd k8s/ansible
just setup-tailscale $(cd ../../tailscale/terraform && just homelab-authkey)

cd cloud/oracle/ansible
just setup-tailscale $(cd ../../../tailscale/terraform && just oracle-authkey)
```

## Troubleshooting

1. **terraform 首次 apply 报 `invalid old hash (412)`**（`overwrite a non-default policy file`）：tailnet 已有
   自定义 ACL，先 import 再 apply：
   ```bash
   cd tailscale/terraform && export $(grep -v '^#' .env | xargs)
   terraform import -var="tailscale_oauth_client_id=$TAILSCALE_OAUTH_CLIENT_ID" \
     -var="tailscale_oauth_client_secret=$TAILSCALE_OAUTH_CLIENT_SECRET" tailscale_acl.main acl
   ```
2. **`tailscale up --authkey=...` 无输出挂住**，`tailscale status` 报 `node nodekey:... already exists`：旧 key
   还注册在控制面上，新 auth key 盖不掉。清本地状态当新设备注册：
   `just setup-tailscale <authkey> -e tailscale_force_reregister=true`，等价于节点上
   `systemctl stop tailscaled && rm -rf /var/lib/tailscale && systemctl start tailscaled` 后重跑 `tailscale up`。
3. **`tailscale up` 被中断，`--accept-routes` 没生效**（`AllowedIPs` 有对端路由，`ip route show table 52` 没有）：
   在该节点上 `tailscale set --accept-routes`。
4. **oracle 返回 `Packet filtered`（ICMP 3/13 admin-prohibited）**：firewalld 的 nftables FORWARD 链对不属于
   任何活动 zone 的流量 `reject with icmpx admin-prohibited`，且先于 iptables FORWARD 的 `ACCEPT`。`tailscale0`
   须在 trusted zone（role 变量 `tailscale_firewalld_trusted`，oracle 开启）；node0 上用
   `nft list ruleset | grep -A2 "filter_FORWARD_POLICIES"` 确认。
5. **`ip route show` 看不到 Tailscale 路由**：正常，它们在 table 52，看 `ip route show table 52` 与 `ip rule list`。
6. **不在 LAN 时 SSH `10.10.10.10` 超时**（homelab 私网地址），按优先级：
   - 经 oracle 跳板（oracle 经 pve 的 Tailscale 路由到得了 homelab）：
     ```bash
     ssh -i ~/.ssh/vgio -o ProxyCommand="ssh -i ~/.ssh/vgio -W %h:%p ubuntu@100.107.166.37" root@10.10.10.10
     ```
     tailnet 整个不可用时才换成 oracle 公网 IP。它不进仓库（`scripts/check-public-ips.py`），现取不落盘；
     新克隆没有 terraform state 时去 OCI 控制台看：
     ```bash
     ORACLE_PUB=$(cd cloud/oracle/terraform && terraform output -raw instance_public_ip)
     ssh -i ~/.ssh/vgio -o ProxyCommand="ssh -i ~/.ssh/vgio -W %h:%p ubuntu@$ORACLE_PUB" root@10.10.10.10
     ```
   - 经 Proxmox QEMU agent（pve `192.168.50.4` 在 LAN 上，`k8s-node` 的 VM ID 是 `100`）：
     `ssh -i ~/.ssh/vgio root@192.168.50.4 "qm guest exec 100 --timeout 15 -- <command>"`
   - 经 pve 的 Tailscale 路由（`100.118.193.51` 通告两段 LAN）：Mac 接受路由
     （`tailscale up --accept-routes`）后 `10.10.10.10` 也可能直接可达。
