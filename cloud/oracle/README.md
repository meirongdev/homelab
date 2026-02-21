# Oracle K3s Cluster

Single-node K3s cluster running on Oracle Cloud (Ampere A1, ARM64).

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
│   └── rss-system/       # RSS pipeline (Miniflux + RSSHub + n8n)
│       ├── namespace.yaml
│       ├── secrets.yaml
│       ├── miniflux.yaml
│       ├── rsshub.yaml
│       └── n8n.yaml
├── terraform/            # Oracle Cloud infra (VCN, compute, etc.)
├── justfile              # Top-level commands for full cluster management
└── README.md             # This file
```

## Architecture

```
Internet → Cloudflare DNS (rss.meirong.dev)
         → Cloudflare Tunnel (oracle-k3s)
         → cloudflared pod (cloudflare namespace)
         → Traefik (kube-system, Gateway API)
         → HTTPRoute → miniflux service (rss-system)
```

### Multi-Cluster Communication

```
oracle-k3s pods → Tailscale (100.107.166.37)
                → k8s-node (100.107.254.112:31144)
                → Vault (k3s-homelab)
```

Both clusters share HashiCorp Vault via Tailscale. Each cluster has its own:
- Cloudflare tunnel (independent ingress)
- External Secrets Operator
- ClusterSecretStore (pointing to Vault via Tailscale IP)

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

## Day-to-Day Operations

```bash
just status          # Show all cluster resources
just status-rss      # Show rss-system pods/services
just deploy-manifests # Re-apply all manifests
just logs miniflux   # View miniflux logs
just logs n8n        # View n8n logs
```

## Adding a New Subdomain

1. Add ingress rule in `cloudflare/terraform.tfvars`
2. Add HTTPRoute in `manifests/base/gateway.yaml`
3. Run `just deploy-cloudflare-tunnel`

## Network Notes

- **firewalld**: Oracle Cloud Ubuntu uses firewalld with nftables. Pod/service CIDRs
  (`10.52.0.0/16`, `10.53.0.0/16`) and interfaces (`cni0`, `flannel.1`) must be in
  the trusted zone. This is handled by `ansible/playbooks/setup-k3s.yaml`.
- **CoreDNS**: Patched to forward to `8.8.8.8` instead of `/etc/resolv.conf`
  (which points to Oracle's unreachable `169.254.169.254` metadata DNS).
