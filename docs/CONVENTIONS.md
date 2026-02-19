# Homelab Development Conventions & Context

This file provides guidance for AI assistants (Claude, Gemini) and developers working in this repository.
It is symlinked as `CLAUDE.md` and `GEMINI.md` in the project root for automatic AI context loading.

## Project Overview

A five-layer Homelab infrastructure-as-code setup:
1. **Proxmox VM** (`proxmox/`) — VM provisioning on Proxmox VE.
2. **Kubernetes Cluster** (`k8s/ansible/`) — Single-node K3s cluster.
3. **Applications** (`k8s/helm/`) — Helm charts and K8s manifests for observability, databases, and personal services.
4. **External Access** (`cloudflare/`) — Cloudflare Tunnel and DNS management via Terraform.
5. **GitOps** (`argocd/`) — ArgoCD continuously syncs `k8s/helm/manifests/` from Git to the cluster.

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
├── argocd/
│   ├── install/        # ArgoCD install patches (TLS disable)
│   ├── projects/       # AppProject definitions (RBAC)
│   └── applications/   # ArgoCD Application manifests (one per logical group)
├── cloudflare/
│   └── terraform/      # Cloudflare Tunnel ingress rules + DNS records
└── docs/
    ├── CONVENTIONS.md  # This file (symlinked as CLAUDE.md and GEMINI.md)
    ├── architecture/   # Architecture notes and TODO
    └── plans/          # Implementation plan records
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
just init                  # Initialize .env from .env.example
just deploy-all            # Deploy full observability stack (LGTM)
just setup-nfs-provisioner # Install NFS storage provisioner
just setup-postgres        # Deploy PostgreSQL
just deploy-homepage       # First-time deploy Homepage dashboard
just update-homepage       # Update Homepage config + restart pod (apply + rollout restart)
just status                # Check monitoring namespace state
```

### ArgoCD GitOps
Run from `k8s/helm/`:
```bash
just deploy-argocd      # Install ArgoCD + register all Applications (idempotent)
just deploy-argocd-dns  # Apply Cloudflare DNS for argocd.meirong.dev
just argocd-password    # Print initial admin password
just argocd-sync        # Trigger immediate full sync (bypasses 3-min poll)
just argocd-status      # Show all Application sync/health status
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

### GitOps (ArgoCD)
- ArgoCD runs in the `argocd` namespace, UI at `argocd.meirong.dev`
- **Sync poll interval**: 3 minutes (auto-syncs after every `git push`)
- **Managed by ArgoCD** (auto-sync + selfHeal):
  - `personal-services` App → `manifests/{calibre-web,stirling-pdf,squoosh,homepage}.yaml`
  - `it-tools` App → `manifests/it-tools/` (Kustomize; managed separately to support Image Updater write-back)
  - `argocd-image-updater` App → Helm chart `argo/argocd-image-updater` v1.1.0, values from `values/argocd-image-updater.yaml`
  - `gateway` App → `manifests/{gateway.yaml,traefik-config.yaml}`
  - `cloudflare` App → `manifests/cloudflare-tunnel.yaml`
  - `vault-eso` App → `manifests/{vault-eso-config,*-external-secret}.yaml`
- **NOT managed by ArgoCD** (manual `just` commands):
  - HashiCorp Vault — requires manual init/unseal
  - External Secrets Operator — depends on Vault
  - kube-prometheus-stack / Loki / Tempo — Helm releases
  - PostgreSQL — stateful, avoid auto-prune
  - NFS Provisioner — infrastructure layer
  - Cloudflare Terraform — non-K8s resources

### Storage
- Persistent volumes use NFS (`nfs-client` StorageClass) at `192.168.50.106:/export`
- PVCs for stateful services (e.g. Calibre-Web) carry `argocd.argoproj.io/sync-options: Prune=false` to prevent accidental deletion

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
| IT-Tools | `personal-services` | `tool.meirong.dev` |
| Stirling-PDF | `personal-services` | `pdf.meirong.dev` |
| Squoosh | `personal-services` | `squoosh.meirong.dev` |
| Grafana | `monitoring` | `grafana.meirong.dev` |
| HashiCorp Vault | `vault` | `vault.meirong.dev` |
| ArgoCD | `argocd` | `argocd.meirong.dev` |
| PostgreSQL | `database` | Internal only |

## Conventions

- **Task Runners**: Use `just` for Ansible, Helm, and Cloudflare Terraform; `make` for Proxmox Terraform.
- **Commits**: Conventional Commits format (`feat:`, `fix:`, `chore:`).
- **Helm Config**: Prefer `values/*.yaml` files; avoid inline `--set` flags.
- **New Services (GitOps flow)**:
  1. Create `manifests/<service>.yaml`
  2. Add HTTPRoute + optional ReferenceGrant to `manifests/gateway.yaml`
  3. Add filename to `argocd/applications/personal-services.yaml` include list
  4. Add subdomain to `cloudflare/terraform/terraform.tfvars`
  5. `git push` → ArgoCD auto-deploys within 3 minutes
  6. `cd cloudflare/terraform && just apply` for DNS
  - **Exception**: services needing ArgoCD Image Updater (e.g. `it-tools`) get their own Kustomize Application (`manifests/<service>/`) and `argocd/applications/<service>.yaml` instead of joining `personal-services`
- **Homepage config updates**: ArgoCD auto-syncs the ConfigMap on `git push`, but `subPath` volume mounts require a pod restart to reload — run `just update-homepage` (does `apply` + `rollout restart` in one step). Do NOT use `kubectl delete configmap` as ArgoCD will conflict.
- **HTTPRoute template**: Always include explicit `group`/`kind` in `parentRefs` and `group`/`kind`/`weight` in `backendRefs` to prevent ArgoCD OutOfSync drift caused by Gateway controller defaults.
- **ArgoCD Image Updater** (v1.1.0): Uses CRD model — create an `ImageUpdater` CR (not just annotations). Set `useAnnotations: true` in the CR to read image config from Application annotations. Use strategy `newest-build` (not `latest`, deprecated). After changing Application annotations in Git, re-run `kubectl apply -f argocd/applications/<app>.yaml` — ArgoCD does not manage Application objects themselves.
- **Kustomize namespace caveat**: The global `namespace:` field in `kustomization.yaml` runs as a transformer after JSON patches, overriding them. Declare namespace explicitly in each manifest instead when resources span multiple namespaces.
- **Chinese Comments**: Permitted and used in `justfile` for clarity.
- **SSH**: User `root`, Key `~/.ssh/vgio`.
