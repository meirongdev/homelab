# Tailscale Cross-Cluster Networking

## Overview

Two K3s clusters are connected via Tailscale subnet routing. Each cluster's K3s node acts as a subnet router, advertising its Pod and Service CIDRs into the shared tailnet. This lets pods in either cluster reach pods in the other cluster directly by IP, without any changes to applications.

**Status**: Active as of 2026-02-21. Both nodes connected, bidirectional pod routing verified.

## CIDR Allocation

| Cluster | Pod CIDR | Service CIDR | Node (LAN) IP | Tailscale IP |
|---------|----------|--------------|---------------|--------------|
| Homelab K3s | 10.42.0.0/16 | 10.43.0.0/16 | 10.10.10.10 | 100.107.254.112 |
| Oracle K3s | 10.52.0.0/16 | 10.53.0.0/16 | 10.0.0.26 | 100.107.166.37 |

Oracle K3s uses non-default CIDRs to avoid collision with homelab defaults.
Set in `/etc/rancher/k3s/config.yaml` via `cloud/oracle/ansible/playbooks/setup-k3s.yaml`.

## How It Works

### Packet path: homelab pod → Oracle pod

```
[Homelab Pod 10.42.x.x]
        │  (standard pod routing via cni0)
        ▼
[Homelab K3s Node 10.10.10.10]
        │  k8s-node is a Tailscale subnet router
        │  routing table 52: 10.52.0.0/16 dev tailscale0
        ▼
[Tailscale DERP/direct relay]  ~80ms RTT
        │
        ▼
[Oracle K3s Node 10.0.0.26]
        │  Oracle node receives packet via tailscale0
        │  firewalld trusted zone: tailscale0 + 10.42.0.0/16 allowed
        │  kernel routes: 10.52.0.0/24 dev cni0
        ▼
[Oracle Pod 10.52.x.x]
```

The reverse path (Oracle → homelab) is symmetric.

### Key mechanisms

- **Subnet routing**: `tailscale up --advertise-routes=<CIDRs>` tells the Tailscale control plane to route traffic for those CIDRs through this node.
- **Route acceptance**: `tailscale up --accept-routes` installs peer routes into kernel routing table 52 (`ip route show table 52`). These are separate from the main table.
- **Auto-approval**: The Tailscale ACL `autoApprovers` block in `tailscale/terraform/main.tf` automatically approves advertised routes from tagged nodes without manual admin approval.
- **Tailscale tags**: Both nodes use pre-auth keys with tags (`tag:homelab`, `tag:oracle`), which the ACL uses to grant subnet routing permissions.

## Tailscale Tags and ACL

| Tag | Node | Auto-approved routes |
|-----|------|---------------------|
| `tag:homelab` | k8s-node (homelab) | 10.42.0.0/16, 10.43.0.0/16 |
| `tag:oracle` | node0 (oracle) | 10.52.0.0/16, 10.53.0.0/16 |

ACL policy (`tailscale/terraform/main.tf`): `tag:homelab` and `tag:oracle` can reach any destination (`*:*`).

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
| `k8s/ansible/playbooks/setup-tailscale.yaml` | Homelab | 10.42/16, 10.43/16 |
| `cloud/oracle/ansible/playbooks/setup-tailscale.yaml` | Oracle | 10.52/16, 10.53/16 |

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
# Both nodes visible in tailnet
tailscale status

# Routes installed in table 52 (not main table)
ip route show table 52 | grep -E "10\.42|10\.43|10\.52|10\.53"

# Cross-cluster pod ping
ping 10.52.0.2   # from homelab: Oracle CoreDNS pod
ping 10.42.0.1   # from Oracle: homelab pod gateway

# Cross-cluster K3s API access
nc -z 100.107.166.37 6443   # homelab → Oracle K3s API
nc -z 100.107.254.112 6443  # Oracle → homelab K3s API

# Cross-cluster DNS query (homelab node querying Oracle CoreDNS)
nslookup kubernetes.default.svc.cluster.local 10.52.0.2
```

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
firewall-cmd --zone=trusted --add-source=10.43.0.0/16 --permanent
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
