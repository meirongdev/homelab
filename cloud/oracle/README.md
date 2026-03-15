# Oracle K3s Cluster

Single-node K3s cluster running on Oracle Cloud (Ampere A1, ARM64), now using Cilium as CNI.

## Directory Structure

```
cloud/oracle/
├── ansible/              # Node provisioning (K3s install, Tailscale, firewalld)
│   ├── playbooks/
│   │   ├── setup-k3s.yaml
│   │   ├── setup-tailscale.yaml
│   │   └── fetch-kubeconfig.yaml
│   └── inventory/
│       └── hosts.yaml
├── cloudflare/           # Cloudflare tunnel terraform (independent from homelab)
│   ├── main.tf
│   ├── variables.tf
│   ├── provider.tf
│   └── justfile
├── manifests/            # K8s manifests for oracle-k3s workloads
│   ├── kustomization.yaml
│   ├── base/             # Cluster-level infra (gateway, cloudflare-tunnel, vault-store)
│   │   ├── vault-store.yaml
│   │   ├── cloudflare-tunnel.yaml
│   │   └── gateway.yaml
│   ├── homepage/         # Homepage dashboard
│   ├── monitoring/       # OTel collector + exporters
│   ├── personal-services/ # IT-Tools / Stirling-PDF / Squoosh / Timeslot
│   ├── rss-system/       # RSS pipeline (Miniflux + RSSHub + KaraKeep + Redpanda Connect)
│       ├── namespace.yaml
│       ├── secrets.yaml
│       ├── miniflux.yaml
│       ├── rsshub.yaml
│       ├── karakeep.yaml
│       └── redpanda-connect.yaml
├── values/               # Helm values (for example Cilium)
├── terraform/            # Oracle Cloud infra (VCN, compute, etc.)
├── justfile              # Top-level commands for full cluster management
└── README.md             # This file
```

## Architecture

```
Internet → Cloudflare DNS (*.meirong.dev)
         → Cloudflare Tunnel (oracle-k3s, HTTP/2)
         → cloudflared pod (cloudflare namespace)
         → Cilium Gateway API (kube-system)
         → HTTPRoute → Services
```

### Multi-Cluster Communication

```
oracle-k3s pods → Tailscale (100.107.166.37)
                → k8s-node (100.94.186.7:31333)
                → Vault (k3s-homelab)
```

Both clusters share HashiCorp Vault via Tailscale. Each cluster has its own:
- Cloudflare tunnel (independent ingress)
- External Secrets Operator
- ClusterSecretStore (pointing to Vault via Tailscale IP)
- Cilium VXLAN overlay with non-overlapping Pod CIDRs

## Quick Start (from scratch)

```bash
# 1. Provision the Oracle Cloud VM (if not done)
cd terraform && make apply

# 2. Setup K3s + Tailscale on the node
cd .. && just setup-node
just fetch-kubeconfig
just setup-tailscale <authkey>

# 3. Bootstrap the full cluster
just bootstrap
```

`just bootstrap` now performs these steps in order:

1. Install Cilium
2. Install External Secrets Operator
3. Create the Vault token secret
4. Apply all manifests
5. Deploy the Cloudflare tunnel connector

## Day-to-Day Operations

```bash
just status          # Show all cluster resources
just status-rss      # Show rss-system pods/services
just status-monitoring # Show OTel collector status
just cilium-status   # Show Cilium health
just deploy-manifests # Re-apply all manifests
just deploy-timeslot # Install Timeslot via Helm and patch chart bugs
just logs miniflux   # Show recent miniflux logs
```

`just deploy-cilium` is intentionally state-resetting: it uses `helm upgrade --install --reset-values`, deletes the Hubble TLS secrets first, and waits for `hubble-relay` to become healthy. This prevents stale manual Helm values or old Hubble certificates from surviving a partial rebuild and breaking Relay TLS.

## Adding a New Subdomain

1. Add ingress rule in `cloudflare/terraform.tfvars`
2. Add HTTPRoute in `manifests/base/gateway.yaml`
3. Run `just deploy-cloudflare-tunnel`

## Network Notes

- **firewalld**: Oracle Cloud Ubuntu uses firewalld with nftables. Oracle local pod/service CIDRs
  (`10.52.0.0/16`, `10.53.0.0/16`) and interfaces (`cni0`, `cilium_vxlan`) must be in
  the trusted zone. Cross-cluster Tailscale routing is intentionally narrower: only homelab pod CIDR
  (`10.42.0.0/16`) is trusted/advertised, while homelab service reachability should prefer public URLs,
  NodePort, or the node Tailscale IP.
- **CoreDNS**: Patched to forward to `8.8.8.8` instead of `/etc/resolv.conf`
  (which points to Oracle's unreachable `169.254.169.254` metadata DNS).
- **Cloudflared**: Oracle Cloud blocks outbound UDP/QUIC in practice for this node, so the in-cluster connector is pinned to `--protocol http2`.
- **ClusterMesh**: the Cilium values already set `cluster.name`, `cluster.id`, and deploy `clustermesh-apiserver` on NodePort `32379`, but after rebuilding either cluster you must re-run `just connect-clustermesh <homelab-ts-ip>:32379 <oracle-ts-ip>:32379` so the cross-cluster config and CA bundle are refreshed. In this environment the reconnect must allow mismatching cluster CAs because each rebuilt cluster mints a new local Cilium CA.
