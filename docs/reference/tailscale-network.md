# Tailscale Cross-Cluster Networking

> Last updated: 2026-07-31
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

### `nfs-lan-route` ip-rule — permanent by design, do not remove

`k8s-node` and `pve` each carry an `ip rule` at priority **5260** forcing
`to 192.168.50.0/24` through `lookup main`. This is **not** leftover scaffolding
from the 2026-07-12 double-advertiser fix — it is structural and stays.

Because `pve` legitimately advertises `192.168.50.0/24` (it is 24/7, unlike a
laptop, so it is the right subnet router) and `k8s-node` needs `--accept-routes`
for kubectl to reach the K8s API, table 52 always holds a route for that LAN
segment. Non-destructive test on `k8s-node` 2026-07-19 (drop the rule → read the
route → restore immediately): without the rule, traffic to 192.168.50.x
immediately switches to `dev tailscale0` — an extra hop through the tunnel to
reach a host that is one LAN hop away. Keep the rule on **both** nodes.

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
`k8s/helm/manifests/bifrost/dgx-proxy.yaml` runs an nginx on homelab (which *can*
reach the Sparks) and publishes it as a Cilium **global Service**, so oracle pods
reach the DGX vLLM cross-cluster:

```
oracle pod → ClusterMesh VXLAN → dgx-proxy (homelab) → Tailscale → DGX vLLM
```

Verified 2026-08-07 end to end from an oracle pod: `/v1/models` → 200, a real
`/v1/chat/completions` → 2.7 s.

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
| `k8s/ansible/playbooks/setup-tailscale.yaml` | Homelab | 10.42/16 |
| `cloud/oracle/ansible/playbooks/setup-tailscale.yaml` | Oracle | 10.52/16 |

两个 playbook 是共享 role `tailscale/ansible/roles/tailscale_node` 的薄封装（2026-07-07 合并），
集群差异（up 参数、firewalld、UDP GRO、对端 CIDR）走 playbook vars；roles_path 见各自 ansible.cfg。

## Initial Setup

```bash
# 1. Import existing Tailscale ACL into Terraform state (required if tailnet already has a policy)
cd tailscale/terraform
export $(grep -v '^#' .env | xargs)
terraform import \
  -var="tailscale_oauth_client_id=$TAILSCALE_OAUTH_CLIENT_ID" \
  -var="tailscale_oauth_client_secret=$TAILSCALE_OAUTH_CLIENT_SECRET" \
  tailscale_acl.main acl

# 2. Generate pre-auth keys
just init
just apply

# 3. Reinstall Oracle K3s with non-default CIDRs (one-time, destructive)
cd cloud/oracle/ansible
just cleanup-k3s
just setup-k3s

# 4. Install Tailscale — Oracle node
just setup-tailscale $(cd ../../../tailscale/terraform && just oracle-authkey)

# 5. Install Tailscale — homelab node (must be on LAN, or use Oracle as jump host)
cd k8s/ansible
just setup-tailscale $(cd ../../tailscale/terraform && just homelab-authkey)
```

## Verification

```bash
# Both nodes visible in tailnet; the k8s-node line should say "direct", not "relay"
tailscale status

# Underlay routes in table 52 (NOT pod CIDRs — those are gone):
# homelab node must see node0's /32; oracle node must see pve's 10.10.10.0/24
ssh ubuntu@100.94.186.7    'ip route show table 52 | grep 10.0.0.26'
ssh ubuntu@152.69.195.151  'ip route show table 52 | grep 10.10.10.0/24'

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
   ssh -i ~/.ssh/vgio \
     -o ProxyCommand="ssh -i ~/.ssh/vgio -W %h:%p ubuntu@152.69.195.151" \
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
