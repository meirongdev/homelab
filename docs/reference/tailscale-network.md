# Tailscale Cross-Cluster Networking

> Last updated: 2026-08-13
> Status: 生效事实
>
> Rewritten 2026-07-07 after the topology review. The original design (each K3s node
> advertises its Pod CIDR as a Tailscale subnet route) is GONE — cross-cluster pod
> traffic now rides **Cilium ClusterMesh VXLAN**, with Tailscale as the node-level
> underlay only.

## Overview

Three cooperating layers:

1. **Tailscale (underlay)** — node-to-node reachability. Every production east-west
   flow uses `节点 Tailscale IP + NodePort`: oracle→homelab Loki `:31080` /
   Prometheus `:31090` / Tempo `:31317` / Vault `:31952`; homelab→oracle ArgoCD
   `:6443`; ClusterMesh control plane `:32379` both ways.
2. **Cilium ClusterMesh (pod dataplane)** — pod↔pod across clusters is VXLAN
   (udp/8472) between the two node IPs, carried over Tailscale. Verified 2026-07-07:
   bidirectional, all inner packet sizes ≤1230 (= tailscale0 MTU 1280 − 50 VXLAN).
3. **Cloudflare Tunnel (north-south)** — per-cluster cloudflared → local Cilium
   Gateway. Tailscale is NOT in the HTTP request path.

**Status (2026-07-07)**: node0↔k8s-node is a **direct** WireGuard connection
(~75-87ms) after opening UDP 41641 on OCI + firewalld. Both k8s nodes advertise
almost nothing — see the underlay route table below.

## Underlay routes (who advertises what)

| Node | Advertises | Why |
|------|-----------|-----|
| `pve` (100.118.193.51) | `10.10.10.0/24`, `192.168.50.0/24` | LAN access for ops; **also carries oracle→homelab VXLAN outer packets** |
| `node0` (100.107.166.37) | `10.0.0.26/32` (its own VCN IP) | homelab→oracle VXLAN outer packets |
| `k8s-node` (100.94.186.7) | **nothing** | ⚠️ see the poisoning gotcha below |

Pod/Service CIDRs (10.42/10.43/10.52/10.53) are **not** advertised anymore.

⚠️ **Route-poisoning gotcha (cost us all homelab v4 egress on 2026-07-07)**:
`k8s-node` must NEVER advertise its own IP `10.10.10.10/32`. `pve` is a
subnet router that **transits** this segment's traffic (home router → pve →
10.10.10.0/24); with `--accept-routes` pve learns the /32 into routing table 52,
which outranks its main table, and hijacks ALL return traffic destined to the
node into the tailnet — every inbound v4 packet (TCP handshakes, DNS answers,
WireGuard disco replies) blackholes. Advertising node0's own /32 is safe only
because nothing in the tailnet transits traffic toward the OCI VCN.
Rule of thumb: **never advertise an IP that another tailnet subnet router is
responsible for delivering to you.**

### 5260 LAN-direct ip-rule — permanent by design, do not remove

`k8s-node` and `pve` each carry an `ip rule` at priority **5260** forcing
`to 192.168.50.0/24` through `lookup main`. This is **not** leftover scaffolding
from the 2026-07-12 double-advertiser fix — it is structural and stays.
（维护机制 2026-08-12 起变更：`k8s-node` 上由收敛器 `tailscale-ip-rules.timer`
每 5 分钟断言，历史单元 `nfs-lan-route.service` 已退役，见下方「守护自身失守」；
`pve` 上仍是同名手工单元——它不跑 systemd-networkd，无清扫问题。）

Because `pve` legitimately advertises `192.168.50.0/24` (it is 24/7, unlike a
laptop, so it is the right subnet router) and `k8s-node` needs `--accept-routes`
for kubectl to reach the K8s API, table 52 always holds a route for that LAN
segment. Non-destructive test on `k8s-node` 2026-07-19 (drop the rule → read the
route → restore immediately): without the rule, traffic to 192.168.50.x
immediately switches to `dev tailscale0` — an extra hop through the tunnel to
reach a host that is one LAN hop away. Keep the rule on **both** nodes.

### `tailscale-cgnat-route` ip-rule —— Cilium 身份标记撞上 Tailscale 的 fwmark

两台节点在优先级 **5200** 各有一条 `to 100.64.0.0/10 lookup 52`。它挡的是一个
Cilium 与 Tailscale 之间的位段冲突，2026-08-09 定位并修复。

#### 症状

**某一个 pod** 到整个 `100.64.0.0/10` 全部超时，同节点、同 namespace 的其它 pod 全部正常。
两个特征让它很容易被误判：

- 打一个**没人监听的端口**同样是超时，而不是 `connection refused`。看着像防火墙丢包，
  其实是路由把包送错了出口，压根没到对端。
- 删掉 pod 重建**不管用**（新 IP、新 endpoint，照样坏）。看着像应用或镜像的问题。

#### 原理

两个软件在同一个 `skb->mark` 字段上用了重叠的位段。

- **Cilium** 把 endpoint 的安全身份（identity）编码进 mark 的高位。
- **Tailscale** 用 `0x80000` 标记"这个包我已经处理过，别再送回 tailscale0"，并为此装了
  三条 ip rule（5210/5230/5250）。

那三条规则写的是 `fwmark 0x80000/0xff0000` —— 掩码只看 mark 的 **bit16-23**。而这一段
正好压在 Cilium 写身份的位置上，于是判据退化成一句话：

```
identity & 0xFF == 0x08   →   命中 Tailscale 的规则
```

命中之后包被送去 `lookup main`，绕过了排在后面的 `5270: from all lookup 52` ——
**table 52 才是 tailscale0 的路由表**。main 表里没有 `100.64/10`，包就落到默认路由，
于是一个 CGNAT 地址被从 `eth0` 扔给了 LAN 网关，出了网关就没了。没有人回 RST，
所以任何端口都表现为超时。

抓包并排看最直观（同一秒、同一目标）：

```
坏: lxcXXX In  10.42.0.142 > 100.107.166.37:31080  │  eth0       Out  10.10.10.10  > 100.107.166.37:31080
好: lxcYYY In  10.42.0.114 > 100.107.166.37:31080  │  tailscale0 Out  100.94.186.7 > 100.107.166.37:31080
```

#### 为什么它看起来像随机

**这是 1/256 的抽签**。identity 由 pod 的标签算出来，低字节恰好是 `0x08` 的那个中签。
改标签会重算 identity，所以**任何一次改标签都可能让一个一直正常的服务突然连不上跨集群**，
也可能让中签的服务自己好起来。中签与否跟这个服务本身没有半点关系。

实测的因果链（改标签 → 换 identity → 立刻换行为，来回各一次）：

| identity | `& 0xFF` | 结果 |
|---|---|---|
| 108040（`monitoring/alertmanager` 原身份） | 8 | 全 `100.64/10` 不可达 |
| 95821（临时加一个无关标签） | 77 | 立刻全通 |
| 108040（撤掉标签） | 8 | 立刻又断 |

当时全集群扫描，只有它一个真实负载的低字节是 `0x08`，也只有它坏。

#### ⚠️ 别往这些方向查

都验过是死路，按下面的顺序反而两三步就能定位：

1. `cilium-dbg endpoint list -o json` 取该 pod 的 identity，算 `identity & 0xFF`，
   是 8 就基本确诊。
2. 节点上 `tcpdump -ni any` 看出接口：坏的走 `eth0`，好的走 `tailscale0`。
3. `kubectl label pod <p> x=1` 改一次 identity，通了就是它。记得撤掉。

死路清单：重建 pod、`runAsUser`、容器镜像、netns（同 netns 的 ephemeral container 表现一致）、
NetworkPolicy/CNP/CCNP（两个集群都是空的）、ipcache 缺条目、ClusterMesh 健康度。

**尤其别去 grep Tailscale 的 netfilter 规则找"谁打的 mark"。** 本舰队两台节点都用
`--netfilter-mode=off`（见两个 `setup-tailscale.yaml` 的 `tailscale_up_extra_args`），
它**一条 netfilter 规则都不装**，但**照样装 ip rule** —— 这是最容易走岔的一步。
实测 nft、iptables-nft、iptables-legacy 三处含 `0x80000` 的规则均为 **0 条**。
答案不在 netfilter 里，在 Cilium。

> 补一句证据强度：mark 没有从包上直接读出来（节点没装 `conntrack` 命令，
> `/proc/net/nf_conntrack` 也不可读）。上面的结论由三件事共同钉死：规则的掩码语义、
> 全集群 identity 与故障的一一对应、以及 A/B/A 的因果实验。

#### 修法与安全性

在 **5200**（早于 5210）把 `100.64.0.0/10` 钉死到 table 52，对所有 pod 一次性免疫。
由收敛器 `tailscale-ip-rules.timer` 维护（2026-08-12 起；历史单元
`tailscale-cgnat-route.service` 已退役，原因见下节），两个 playbook 各一份：
`k8s/ansible/playbooks/setup-tailscale.yaml` 与
`cloud/oracle/ansible/playbooks/setup-tailscale.yaml`。形状与上面 5260 那条完全一致。

绕过 Tailscale 的防环规则之所以安全：本舰队 `netfilter-mode=off`，**没有任何东西会合法地
设置 `0x80000`**（就是上面那 0 条）。5210-5250 在这里不承担真实的防环职责，只会因位段
碰撞误伤。换句话说，这条规则挡掉的全是误判。

⚠️ **别改用"给中签的 pod 换个标签"** —— 那只躲开这一次抽签，下一个中签的 pod 照样断。

⚠️ **oracle 是预防性加的。** 定位当天扫它 52 个 endpoint，低字节 `0x08` 的只有保留身份 8，
没有真实负载中签，但它的规则集与 homelab 一模一样（同样 `netfilter-mode=off`、同样缺这条
保护规则），即同样暴露，只是运气好。中签的代价不小：oracle 的 otel remote-write 与 krr
都靠 `100.94.186.7` 打回 homelab。

#### 2026-08-12：守护自身失守 —— 现在由两道防线 + 指标看护

上面两条规则（5200/5260）曾以"开机 oneshot"systemd 单元维护，**2026-08-12 review
发现两台 k8s 节点上全部静默失守**：单元 `active (exited)`"看起来修过"，`ip rule`
里规则却没了；oracle 的 homepage 恰好中签（identity 138760，低字节 0x08），到
100.64/10 全超时。凶手是 **systemd-networkd**——`ManageForeignRoutingPolicyRules`
默认 `yes`，networkd (重)启动/重配时清扫一切非它管理的 ip rule；8-11 清晨
unattended-upgrades 重启两台节点的 networkd，规则同批被清。tailscaled 的四条
（5210-5270）有 netlink 监听自愈，自定义规则没有守护者。`pve` 用 ifupdown2 不跑
networkd，其手工 5260 幸存——这条差异是破案线索。A/B 实测（oracle）：默认配置重启
networkd → 5200 三秒内被清；装 drop-in 后重启 → 幸存。
完整取证链 → [records/2026-08-12-tailscale-iprule-guard-drift.md](../records/2026-08-12-tailscale-iprule-guard-drift.md)

现行架构（两个 setup-tailscale playbook 各一份，内容按节点差异化）：

| 防线 | 机制 | 覆盖 |
|---|---|---|
| 根因 | `/etc/systemd/networkd.conf.d/10-no-foreign-sweep.conf`（`ManageForeignRoutingPolicyRules=no` + `ManageForeignRoutes=no`） | networkd 不再清外来规则/路由（也保护 Cilium 与 table 52 的路由） |
| 兜底 | `assert-tailscale-ip-rules` 脚本 + `tailscale-ip-rules.timer` 每 5 分钟幂等断言（单次运行两遍断言夹 20s） | 任何删除者，失守窗口 ≤5 分钟自愈 |
| 可见性 | 脚本写 node-exporter textfile：`tailscale_iprule_present` / `tailscale_iprule_reasserts_total` | 5 条告警（缺失/拉锯/指标停更/逐集群 absent），见 `alerts/tailscale-iprule-alerts.yaml` |

⚠️ 实测两个反直觉结论，改这套机制前先读：**tailscaled 重启并不清这些规则**（清的是
networkd）；**`PartOf=tailscaled` 对已死的 oneshot 不触发**（restart 传播是空操作）——
所以单元里刻意没有 PartOf，timer 是唯一的重申机制。

## How It Works

### Packet path: homelab pod → oracle pod (and reverse)

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

Reverse path: node0's VXLAN outer targets `10.10.10.10`, which rides **pve's**
`10.10.10.0/24` route (WG → pve → vmbr0 → k8s-node; pve SNATs the outer to
10.10.10.1 — harmless, VXLAN is stateless). Slightly asymmetric, works fine.

### MTU — do NOT set it explicitly

Cilium auto-detects MTU (lowest device = tailscale0 = 1280). Max usable inner
packet cross-cluster = **1230** (1280 − 50 VXLAN). ICMP/UDP in the 1231–1280
window silently drop (BPF drop, no ICMP Frag-Needed); TCP is unaffected in
practice (verified with bulk transfers). **Never set an explicit `MTU:` in the
Cilium values**: for explicit values Cilium does NOT subtract tunnel overhead —
pods and the vxlan device get the same number and the top 50 bytes of the range
blackhole (bit us 2026-07-07 with MTU=1200 → inner >1150 dropped).

### Recursion guard (WireGuard-over-VXLAN-over-WireGuard)

tailscaled advertises ALL local addresses as candidate WG endpoints — including
Cilium's `cilium_host` IP (10.42.0.x / 10.52.0.x). Once the mesh works, the peer
can "reach" that address through the mesh itself and will happily select it as
the endpoint → WG rides VXLAN rides WG, with the real public path never winning.
Both nodes therefore DROP udp/41641 to/from the CNI ranges:

- k8s-node: `tailscale-no-cni-endpoint.service` (iptables, see `k8s/ansible/playbooks/setup-tailscale.yaml`)
- node0: firewalld direct rules (see `cloud/oracle/ansible/playbooks/setup-tailscale.yaml`)

### Direct connection requirements

- OCI security list + firewalld public zone must allow **udp/41641**
  (`cloud/oracle/terraform/main.tf`) — without it every path to node0 rides a
  DERP relay (observed: telemetry + mesh over relay "sin", GB/day).
- k8s-node cannot receive unsolicited inbound UDP (double NAT via pve + home
  router with no port-forward), so the direct connection is established by
  k8s-node's outbound probes to node0's public 41641. Good enough.

## Tailscale Tags and ACL

| Tag / owner | Node | Auto-approved routes |
|-------------|------|---------------------|
| `tag:oracle` + meirongdev@gmail.com | node0 | 10.0.0.26/32 |
| meirongdev@gmail.com (untagged!) | k8s-node | — (must not advertise) |
| meirongdev@gmail.com | pve | 10.10.10.0/24, 192.168.50.0/24 (console-approved) |

⚠️ `k8s-node` re-registered at some point WITHOUT `tag:homelab` (it shows as a
user device). Tag-based autoApprovers therefore don't match it — the ACL keeps
the user account in `autoApprovers` for node0's route instead.

ACL policy (`tailscale/terraform/main.tf`): members and both tags can reach any
destination (`*:*`).

### ☠️ Tagged devices cannot reach *shared* nodes — this is not an ACL problem

The two **DGX Spark** boxes (`100.97.87.120` = V4-Flash head, `100.67.164.92` = TP
worker) live in **someone else's tailnet** (`*.tailf63175.ts.net`, owner
`kaixinhuang3307@`) and enter ours via **Tailscale node sharing**.

**Node sharing is granted to a *person*, not to a tailnet.** Devices owned by
`meirongdev@` (k8s-node, both Macs, pve) get the shared peers in their netmap;
`node0` is `tagged-devices` — owned by the tailnet, not a user — and does not.

Measured twice (2026-08-01 open-notebook, 2026-08-07 calibre metadata):

```
oracle node0 → tailscale ping 100.97.87.120 → "no matching peer"
oracle node0 → tailscale status → 6 peers, 0 of them shared
homelab k8s-node → curl 100.97.87.120:8000/v1/models → 200
```

The ACL already allows `tag:oracle` to `*:*`, so **widening the ACL changes
nothing** — the peer isn't in oracle's netmap at all.

#### Sharing carries the device only — no subnet routes, hence no ClusterMesh

**Node sharing does not carry subnet routes or exit nodes in either direction.**
Consequences, measured 2026-08-13 after the Sparks formed their own k3s + Cilium
cluster:

- `pve`'s `10.10.10.0/24` is invisible to the Sparks → they cannot reach
  `10.10.10.10`, homelab's node IP (`ping` 100% loss; `ip route get` falls through
  to their own LAN gateway `10.14.20.1`; `tailscale debug prefs` → `"RouteAll": false`).
- The Sparks' k3s `--node-ip` is `192.168.200.101/102` (their back-to-back NCCL
  link) and we cannot receive a route for it → homelab cannot reach it either.
- Those two node IPs are exactly what Cilium ClusterMesh VXLAN-encapsulates
  **toward**, so the cross-cluster node plane cannot exist. Extending the mesh to
  the DGX cluster was evaluated and rejected —
  [dgx-clustermesh-not-adopted](../decisions/dgx-clustermesh-not-adopted.md)
  (also covers the `cluster.id` collision and the DERP-only 2.28 MB/s link).
- ⚠️ `tailscale ping` to a shared node succeeds **while real TCP to it fails**
  (verified against homelab's `:32379`): it is a path-layer probe and does not
  traverse the ACL packet filter. Never use it as evidence a port is reachable.

Consuming the DGX inference endpoint from homelab therefore uses a plain Service +
hand-written `Endpoints` pointing at the Spark's Tailscale IP — no CNI involvement.

⚠️ **Untagging `node0` is not a small fix.** Tailscale **OAuth clients can only
create tagged devices**, and node0 was authenticated with an OAuth-client preauth
key (`tags = ["tag:oracle"]` in `main.tf`). Making it user-owned requires
re-authenticating the node with a *user* key, which means:

- it drops off the tailnet during re-auth → **cross-cluster ClusterMesh underlay
  breaks**;
- user devices get a **180-day key expiry** (tagged devices never expire), which
  must then be disabled in the console — miss that and the node silently falls off
  the tailnet months later, with no obvious link back to this change.

The autoApprovers entry survives untagging (`"10.0.0.26/32"` lists both
`tag:oracle` **and** `meirongdev@gmail.com`), so that particular worry — raised in
the 2026-08-01 plan — is unfounded. Key expiry is the real hazard.

**Adopted workaround: proxy the capability instead of moving the node.**
`k8s/helm/manifests/bifrost/dgx-proxy.yaml` ran an nginx on homelab (which *can*
reach the Sparks) and published it as a Cilium **global Service**, so oracle pods
reached the DGX vLLM cross-cluster:

```
oracle pod → ClusterMesh VXLAN → dgx-proxy (homelab) → Tailscale → DGX vLLM
```

Verified 2026-08-07 end to end from an oracle pod: `/v1/models` → 200, a real
`/v1/chat/completions` → 2.7 s.

⚠️ **2026-08-08 retired with the `bifrost` ArgoCD App**（LLM 网关将由 Rust litellm 接替）。
本集群 global-Service 计数回到 0，ClusterMesh 回到纯备用能力；oracle 侧
`calibre-metadata-llm` 当前 suspend（其 `LLM_URL` 仍指向 `dgx-proxy.bifrost.svc`，
litellm 落地时一并改指向）。

⚠️ **A Cilium global Service needs a Service object in BOTH clusters.** Annotating
only the homelab side made `cilium-dbg status --all-clusters` report `1 services`
on oracle (so propagation worked), yet oracle pods got
`curl: (6) Could not resolve host`. DNS records and backend merging are separate
concerns: Cilium merges remote backends into a *local* Service, but the
`*.svc.cluster.local` record still comes from the local cluster's CoreDNS reading
the local Service object. The oracle half is a backend-less shadow Service —
`cloud/oracle/manifests/bifrost/dgx-proxy-service.yaml`.

## Cluster DNS on the homelab node (related, bit us 2026-07-07)

The 10.10.10.0/24 segment cannot reach ANY public resolver on port 53 — only the
ISP's IPv6 resolvers (eth0 RA/DHCPv6) work, and pods have no IPv6. Design:
`pods → CoreDNS → 10.10.10.10:53 (systemd-resolved DNSStubListenerExtra) → ISP v6`.
Managed by `k8s/ansible/playbooks/fix-dns-fallback.yaml`. Public resolvers in
`/etc/rancher/k3s/resolv.conf` caused 16 hours of cloudflared CrashLoopBackOff.

## File Map

### Terraform (`tailscale/terraform/`)

| File | Purpose |
|------|---------|
| `provider.tf` | Tailscale provider, OAuth authentication |
| `main.tf` | ACL + pre-auth key resources |
| `variables.tf` | OAuth Client ID/Secret variables |
| `outputs.tf` | Sensitive pre-auth key outputs |
| `justfile` | `init` / `plan` / `apply` / `homelab-authkey` / `oracle-authkey` |
| `.env.example` | Environment variable template |

### Ansible playbooks

| File | Node | Advertised routes |
|------|------|------------------|
| `k8s/ansible/playbooks/setup-tailscale.yaml` | Homelab | **无**（`""`；2026-07-07 起 pod CIDR 与自身 IP 都不广播） |
| `cloud/oracle/ansible/playbooks/setup-tailscale.yaml` | Oracle | `10.0.0.26/32`（自身 VCN IP，作 VXLAN 外层目的；Pod CIDR 不广播） |

两个 playbook 是共享 role `tailscale/ansible/roles/tailscale_node` 的薄封装（2026-07-07 合并），
集群差异（up 参数、firewalld、UDP GRO、对端 CIDR）走 playbook vars；roles_path 见各自 ansible.cfg。

## Initial Setup（一次性，已完成）

tailnet 已建好，日常不需要重跑。重建任一集群时走
[runbooks/oracle-k3s-rebuild.md](../runbooks/oracle-k3s-rebuild.md)
与 [runbooks/homelab-rebuild-ubuntu-24-04.md](../runbooks/homelab-rebuild-ubuntu-24-04.md)
（`just setup-tailscale`）；预授权密钥轮换见下文「Pre-auth Key Renewal」；
ACL 的首次 terraform import 见下方 Troubleshooting #1。

## Verification

```bash
# Both nodes visible in tailnet; the k8s-node line should say "direct", not "relay"
tailscale status

# Underlay routes in table 52 (NOT pod CIDRs — those are gone):
# homelab node must see node0's /32; oracle node must see pve's 10.10.10.0/24
ssh ubuntu@100.94.186.7    'ip route show table 52 | grep 10.0.0.26'
ssh ubuntu@100.107.166.37  'ip route show table 52 | grep 10.10.10.0/24'

# ClusterMesh dataplane: pod→pod both directions, incl. max-size inner packet.
# Get LIVE CoreDNS pod IPs first — hardcoded IPs go stale on pod restart and a dead
# target shows up as Cilium "Stale or unroutable IP" drops (bit us 2026-07-07).
HL=$(kubectl --context k3s-homelab get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')
OR=$(kubectl --context oracle-k3s  get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')
kubectl --context k3s-homelab run t1 --rm -i --restart=Never --image=busybox:1.36 -- ping -c3 -s 1202 $OR
kubectl --context oracle-k3s  run t2 --rm -i --restart=Never --image=busybox:1.36 -- ping -c3 -s 1202 $HL

# Node-IP + NodePort production paths
nc -z 100.107.166.37 6443    # homelab → oracle K3s API (ArgoCD)
nc -z 100.94.186.7  31090    # oracle → homelab Prometheus remote-write
```

## ClusterMesh Reconnect After Rebuild

If either cluster is rebuilt or Cilium is reinstalled, rerun the ClusterMesh connect step so both clusters exchange fresh remote configs and CA bundles.

Use the Tailscale NodePort endpoints, not the private LAN IPs:

```bash
cd k8s/helm
just connect-clustermesh 100.94.186.7:32379 100.107.166.37:32379
```

Why this is required:

- each rebuilt cluster mints a new local Cilium CA
- stale `cilium-clustermesh` remote config can leave `kvstoremesh` disconnected even when node-level ClusterMesh still shows connected
- `--allow-mismatching-ca` is required in this environment so the remote CA is appended to the trust bundle instead of being rejected

Healthy output must show both:

- `All 1 nodes are connected to all clusters`
- `All 1 KVStoreMesh replicas are connected to all clusters`

### 两个 secret，别把正常的当成配错了（2026-08-05 踩过）

KVStoreMesh 下 remote endpoint **不在** `cilium-clustermesh` 里。两者分工：

| secret | 谁读 | 内容 | 正常值 |
|---|---|---|---|
| `cilium-clustermesh` | **cilium-agent** | 连**本集群自己**的缓存 | `https://clustermesh-apiserver.kube-system.svc:2379` |
| `cilium-kvstoremesh` | **kvstoremesh 容器** | 连**对端** | `https://<peer>.mesh.cilium.io:32379` |

⚠️ `cilium-clustermesh` 里那个 `...kube-system.svc:2379` 是**设计如此，不是配错**——
agent 只读本地缓存，跨集群那一跳由 kvstoremesh 负责。2026-08-05 排障时我按"endpoint
写成了集群内 DNS 名"去下结论，是错的，白绕一圈。

`<peer>.mesh.cilium.io` 靠 **`clustermesh-apiserver` Deployment 的 `hostAliases`** 解析
（**不是** cilium DaemonSet 的 —— 查错对象也会得出错误结论）：

```bash
kubectl --context k3s-homelab -n kube-system get deploy clustermesh-apiserver \
  -o jsonpath='{.spec.template.spec.hostAliases}'
#   期望 [{"hostnames":["oracle-k3s.mesh.cilium.io"],"ip":"100.107.166.37"}]
```

### 正确的诊断姿势

`cilium-dbg status` 的摘要行只给 `N/1 remote clusters ready`，不够。要 `--all-clusters`：

```bash
kubectl --context oracle-k3s exec -n kube-system ds/cilium -c cilium-agent -- \
  cilium-dbg status --all-clusters | sed -n '/ClusterMesh/,/^[A-Z]/p'
```

判据：

- `remote configuration: expected=true, retrieved=true` ← **retrieved 才是真连上**。
  `retrieved=false` 且 `etcd: 1/1 connected` = agent 连上了本地缓存，但缓存里没有对端
  数据，即 **kvstoremesh 那一跳断了**。
- `synchronization status: nodes/endpoints/identities/services` 应全 `true`
- endpoints/identities 计数应非 0（2026-08-05 修复后：oracle 见 homelab 33 endpoints /
  33 identities，homelab 见 oracle 48 / 86）

⚠️ **别用 pod 的 `startTime` 推断"断了多久"**。DaemonSet pod 在节点重启后对象不变、
`startTime` 不变，只有容器重启。`(last: never)` 只覆盖**当前容器进程**的生命周期，
要配 `state.running.startedAt` 一起看：

```bash
kubectl --context k3s-homelab -n kube-system get pods -l k8s-app=cilium -o \
  jsonpath='{range .items[*]}{range .status.containerStatuses[?(@.name=="cilium-agent")]}{.state.running.startedAt}{" restarts="}{.restartCount}{"\n"}{end}{end}'
```

### peer 配置在哪（两侧都已固化，2026-08-05 补齐 oracle）

| 集群 | values 文件 | 部署入口 |
|---|---|---|
| homelab | [`k8s/cilium/values.yaml`](../../k8s/cilium/values.yaml) | `cd k8s/helm && just deploy-cilium`（`ctx := "k3s-homelab"`） |
| oracle | [`cloud/oracle/values/cilium-values.yaml`](../../cloud/oracle/values/cilium-values.yaml) | `cd cloud/oracle && just deploy-cilium` |

`clustermesh.config.clusters[].ips` 是真源——它同时生成 `cilium-kvstoremesh` secret 的
endpoint 与 clustermesh-apiserver 的 `hostAliases`。**两个 `deploy-cilium` 都带
`--reset-values`**，所以缺了这段就等于跑一次删一次。
oracle 那段**直到 2026-08-05 才补上**（此前只存在于 live helm release 的 stored values）。

⚠️ 仍然必须跑 `just connect-clustermesh` 的唯一场景是**任一集群重建**：那会重新自签
Cilium CA，两侧要重新交换证书（`--allow-mismatching-ca`）。上面那段只保住 endpoint，
保不住互信。

### 真实故障模式：up-but-stuck，且不自愈

2026-08-05 那次断开**与配置无关**——helm release 历史证明 peer 条目自 oracle `cilium.v11`
（2026-03-15）/ homelab `cilium.v10`（2026-04-27）起一直正确。真正的故障是
**clustermesh-apiserver 活着但卡住**，Cilium 不会自己恢复。修它的其实是
`cilium clustermesh connect` 顺带触发的 helm upgrade **重建了 pod**（新 pod
`restarts=0`），配置一字未改。

所以排障顺序应该是：

```bash
# 1) 先看 helm release 历史，确认配置到底有没有变过（别从当前状态倒推根因）
kubectl --context <ctx> -n kube-system get secret -l owner=helm,name=cilium -o name
#    取最后几个版本，解 .data.release（base64 两次 + gunzip）看 config.clustermesh.config.clusters
# 2) 配置没变 → 就是卡死，重建 pod 即可，不必动配置
kubectl --context <ctx> -n kube-system rollout restart deploy/clustermesh-apiserver
```

现在有告警兜底（`ClusterMeshRemoteClusterNotReady` 等 5 条，见
[observability-alerting-slo.md](observability-alerting-slo.md)），不会再静默。
**没有做自愈**：两集群 global Service 数量都是 0，纯待命能力不值得加探针。

## Pre-auth Key Renewal

Keys expire after 90 days. After expiry:

```bash
cd tailscale/terraform
just apply   # generates new keys, existing nodes stay connected

# Re-run on each node only if the node was deregistered
cd k8s/ansible
just setup-tailscale $(cd ../../tailscale/terraform && just homelab-authkey)

cd cloud/oracle/ansible
just setup-tailscale $(cd ../../../tailscale/terraform && just oracle-authkey)
```

---

## Troubleshooting: Issues Encountered

### 1. Terraform: "existing policy file" error on first apply

**Symptom**: `terraform apply` fails with:
```
Failed to set policy file: You seem to be trying to overwrite a non-default policy file
(got error "precondition failed, invalid old hash (412)")
```

**Cause**: The Tailscale tailnet already has a custom ACL policy. Terraform treats it as a new resource and can't overwrite it without first importing.

**Fix**: Import the existing policy before applying:
```bash
export $(grep -v '^#' .env | xargs)
terraform import \
  -var="tailscale_oauth_client_id=$TAILSCALE_OAUTH_CLIENT_ID" \
  -var="tailscale_oauth_client_secret=$TAILSCALE_OAUTH_CLIENT_SECRET" \
  tailscale_acl.main acl
terraform apply ...
```

---

### 2. `tailscale up` hangs — node already registered

**Symptom**: `tailscale up --authkey=...` hangs indefinitely with no output, then `tailscale status` shows:
```
# Health check:
#   - You are logged out. The last login error was:
#     register request: http 400: node nodekey:... already exists
```

**Cause**: The node's key is still registered in the Tailscale control plane from a previous installation. A new auth key cannot override an existing live node key.

**Fix**: Clear the node's local state so it registers as a new device:
```bash
systemctl stop tailscaled
rm -rf /var/lib/tailscale
systemctl start tailscaled
sleep 2
tailscale up --advertise-routes=... --accept-routes --authkey=<key>
```

The Ansible playbook supports this via the `tailscale_force_reregister` variable:
```bash
just setup-tailscale <authkey> -e tailscale_force_reregister=true
```

---

### 3. `--accept-routes` not applied after interrupted `tailscale up`

**Symptom**: `tailscale status` shows the peer's subnet routes in `AllowedIPs`, but `ip route show table 52` is missing those routes. Cross-cluster packets from this node fail to route.

**Cause**: `tailscale up` was killed before completing. The node registered but the `--accept-routes` flag was never applied persistently.

**Fix**: Run `tailscale set` separately:
```bash
tailscale set --accept-routes
# Verify routes appear in table 52
ip route show table 52
```

---

### 4. Oracle firewalld blocks forwarded Tailscale traffic

**Symptom**: Packets from homelab pods (`10.42.x.x`) to Oracle pods (`10.52.x.x`) return `Packet filtered` (ICMP type 3 code 13: administratively prohibited). Oracle → homelab direction works fine.

**Cause**: Oracle's `firewalld` uses `nftables` backend. Its default FORWARD chain ends with `reject with icmpx admin-prohibited` for any traffic not explicitly allowed by an active zone. Traffic arriving on `tailscale0` destined for `cni0` (the pod network bridge) matched no zone rule.

The iptables FORWARD chain has `policy ACCEPT` and `ACCEPT` rules, but `firewalld`'s nftables chain runs at a higher priority and rejects first.

**Fix**: Add the Tailscale interface and homelab CIDRs to the `trusted` zone:
```bash
firewall-cmd --zone=trusted --add-interface=tailscale0 --permanent
firewall-cmd --zone=trusted --add-source=10.42.0.0/16 --permanent
firewall-cmd --reload
```

This is now codified in `cloud/oracle/ansible/playbooks/setup-tailscale.yaml`.

**Diagnosis tip**: Check for `reject with icmpx admin-prohibited` in the nftables ruleset:
```bash
nft list ruleset | grep -A2 "filter_FORWARD_POLICIES"
```

---

### 5. Tailscale routes are in table 52, not the main routing table

**Symptom**: `ip route show` shows no entries for `10.52.0.0/16`, causing confusion that routing isn't working.

**Explanation**: Tailscale installs accepted peer routes into a separate kernel routing table (number 52), not the main table. An `ip rule` entry (`5270: from all lookup 52`) ensures all packets eventually consult table 52.

```bash
# Correct way to check Tailscale routes
ip route show table 52

# ip rule shows the lookup order
ip rule list
```

---

### 6. Accessing homelab K8s node when not on LAN

**Symptom**: SSH to `10.10.10.10` times out when working remotely.

**Explanation**: `10.10.10.10` is a private IP on the homelab LAN. It is not directly reachable from outside without a VPN or tunnel.

**Workarounds** (in order of preference):

1. **Via Oracle as jump host** (Oracle can reach homelab via Tailscale pve route):
   ```bash
   # 还在 tailnet 上 —— 用 Tailscale 地址，不需要公网 IP
   ssh -i ~/.ssh/vgio \
     -o ProxyCommand="ssh -i ~/.ssh/vgio -W %h:%p ubuntu@100.107.166.37" \
     root@10.10.10.10
   ```

   tailnet 整个不可用时才需要 Oracle 的**公网** IP。它不在本仓库里
   （CI: `scripts/check-public-ips.py`），现取不落盘 —— `terraform output` 读本地
   state，离线可用；新克隆没有 state 时去 OCI 控制台看实例的 Public IP：
   ```bash
   ORACLE_PUB=$(cd cloud/oracle/terraform && terraform output -raw instance_public_ip)
   ssh -i ~/.ssh/vgio \
     -o ProxyCommand="ssh -i ~/.ssh/vgio -W %h:%p ubuntu@$ORACLE_PUB" \
     root@10.10.10.10
   ```

2. **Via Proxmox QEMU agent** (Proxmox at `192.168.50.4` is LAN-accessible and can exec inside VMs):
   ```bash
   ssh -i ~/.ssh/vgio root@192.168.50.4 \
     "qm guest exec 100 --timeout 15 -- <command>"
   ```
   VM ID for `k8s-node` is `100`.

3. **Via Proxmox Tailscale IP** (`pve` is in the tailnet at `100.118.193.51`):
   The `pve` node advertises `10.10.10.0/24` and `192.168.50.0/24` via Tailscale. Once the Mac accepts those routes (`tailscale up --accept-routes`), `10.10.10.10` may be directly reachable from the Mac as well.
