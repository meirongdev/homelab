# Tailscale Cross-Cluster Networking

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
