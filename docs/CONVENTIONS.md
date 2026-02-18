# Homelab Development Conventions & Context

This file provides guidance for AI assistants (Claude, Gemini) and developers working in this repository.
It is symlinked as `CLAUDE.md` and `GEMINI.md` in the project root for automatic AI context loading.

## Project Overview

A four-layer Homelab infrastructure-as-code setup:
1. **Proxmox VM** (`proxmox/`) — VM provisioning on Proxmox VE.
2. **Kubernetes Cluster** (`k8s/ansible/`) — Single-node K3s cluster.
3. **Applications** (`k8s/helm/`) — Helm charts and K8s manifests for observability, databases, and personal services.
4. **External Access** (`cloudflare/`) — Cloudflare Tunnel and DNS management via Terraform.

## Project Structure

```
homelab/
├── proxmox/
│   ├── terraform/      # IaC to provision the Ubuntu VM on Proxmox VE
│   └── ansible/        # Downloads cloud images
├── k8s/
│   ├── ansible/        # K3s installation and node configuration
│   └── helm/
│       ├── values/     # Helm release configurations (one file per chart)
│       └── manifests/  # Raw K8s YAML (Calibre-Web, Homepage, Vault, Gateway, etc.)
├── cloudflare/
│   └── terraform/      # Cloudflare Tunnel ingress rules + DNS records
└── docs/
    └── CONVENTIONS.md  # This file (symlinked as CLAUDE.md and GEMINI.md)
```

## Key Commands (Context-Dependent)

### Infrastructure (Proxmox)
Run from `proxmox/terraform/`:
```bash
make init    # terraform init
make plan    # terraform plan
make apply   # terraform apply
```

### Kubernetes Setup (K3s)
Run from `k8s/ansible/`:
```bash
just setup-k8s        # Install K3s single-node cluster
just fetch-kubeconfig # Sync kubeconfig to ~/.kube/config
just cleanup-k8s      # Uninstall K3s
```

### Application Deployment
Run from `k8s/helm/`:
```bash
just init                 # Initialize .env from .env.example
just deploy-all           # Deploy full observability stack (LGTM)
just setup-nfs-provisioner # Install NFS storage provisioner
just setup-postgres       # Deploy PostgreSQL
just deploy-homepage      # Update/deploy Homepage dashboard
just status               # Check monitoring namespace state
```

### External Access (Cloudflare)
Run from `cloudflare/terraform/`:
```bash
just init    # terraform init
just plan    # Preview DNS/Tunnel changes
just apply   # Apply DNS/Tunnel changes
```

## Architecture Details

### Networking & Ingress
- All external traffic flows: `Internet → Cloudflare DNS → Cloudflare Tunnel → Traefik (K8s) → Services`
- **Cloudflare Tunnel**: `cloudflared` pod in `cloudflare` namespace forwards to `traefik.kube-system.svc:80`
- **Traefik**: Configured via K8s Gateway API (`HTTPRoute` resources in `manifests/gateway.yaml`)
- **K8s Node**: `10.10.10.10` | **Proxmox**: `192.168.50.3`

### Storage
- Persistent volumes use NFS (`nfs-client` StorageClass) at `192.168.50.106:/export`

### Secrets Management
- **HashiCorp Vault**: Primary source of truth for all app secrets (running in `vault` namespace)
- **External Secrets Operator (ESO)**: Syncs Vault secrets → K8s Secrets automatically
- Local `.env` files: Used for initial bootstrap tokens only (gitignored)

### Observability
- LGTM stack (Loki, Grafana, Tempo, Prometheus/Mimir) in `monitoring` namespace
- Grafana accessible at `grafana.meirong.dev`

### Services
| Service | Namespace | URL |
|---------|-----------|-----|
| Homepage | `homepage` | `home.meirong.dev` |
| Calibre-Web | `personal-services` | `book.meirong.dev` |
| Grafana | `monitoring` | `grafana.meirong.dev` |
| HashiCorp Vault | `vault` | `vault.meirong.dev` |
| PostgreSQL | `database` | Internal only |

## Conventions

- **Task Runners**: Use `just` for Ansible, Helm, and Cloudflare Terraform; `make` for Proxmox Terraform.
- **Commits**: Conventional Commits format (`feat:`, `fix:`, `chore:`).
- **Helm Config**: Prefer `values/*.yaml` files; avoid inline `--set` flags.
- **New Subdomains**: Add to `cloudflare/terraform/terraform.tfvars` **and** `k8s/helm/manifests/gateway.yaml`.
- **Chinese Comments**: Permitted and used in `justfile` for clarity.
- **SSH**: User `root`, Key `~/.ssh/vgio`.
