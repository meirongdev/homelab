# Homelab AI Assistant Instructions

This file provides essential context and guidelines for AI coding assistants working in this repository.

## Architecture & Big Picture
This is a 5-layer Infrastructure-as-Code (IaC) and GitOps homelab project:
1. **Proxmox VM** (`proxmox/`): Terraform provisions a single Ubuntu VM.
2. **Kubernetes** (`k8s/ansible/`): Ansible installs a single-node K3s cluster.
3. **Applications** (`k8s/helm/`): Helm and raw manifests define the workloads.
4. **External Access** (`cloudflare/`): Terraform manages Cloudflare Tunnels and DNS.
5. **GitOps** (`argocd/`): ArgoCD continuously syncs `k8s/helm/manifests/` to the cluster.

**Traffic Flow**: Internet → Cloudflare DNS → Cloudflare Tunnel (`cloudflared` pod) → Traefik (K8s Gateway API) → Services.
*Exception*: Kopia uses NodePort (31515) directly due to gRPC bidirectional streaming issues with Cloudflare Tunnel.

## Critical Workflows & Commands
We use `just` for most tasks and `make` for Proxmox Terraform.

- **Proxmox IaC**: `cd proxmox/terraform && make plan` / `make apply`
- **K3s Setup**: `cd k8s/ansible && just setup-k8s && just fetch-kubeconfig`
- **App Deployment (Manual)**: `cd k8s/helm && just deploy-all` (for observability stack)
- **GitOps Sync**: `cd k8s/helm && just argocd-sync` (bypasses 3-min poll)
- **Cloudflare IaC**: `cd cloudflare/terraform && just plan` / `just apply`

## Project-Specific Conventions
- **GitOps First**: Most application changes should be made by editing YAML in `k8s/helm/manifests/` and committing to Git. ArgoCD will auto-sync within 3 minutes.
- **Adding a New Service**:
  1. Create `manifests/<service>.yaml`
  2. Add HTTPRoute to `manifests/gateway.yaml`
  3. Add to `argocd/applications/personal-services.yaml` include list
  4. Add subdomain to `cloudflare/terraform/terraform.tfvars`
  5. Commit and push. Run `just apply` in `cloudflare/terraform/`.
- **Secrets Management**: HashiCorp Vault is the source of truth. External Secrets Operator (ESO) syncs Vault secrets to K8s Secrets. Do not commit secrets to Git.
- **Gateway API**: When writing `HTTPRoute` resources, always include explicit `group`/`kind` in `parentRefs` and `group`/`kind`/`weight` in `backendRefs` to prevent ArgoCD OutOfSync drift.
- **Homepage Updates**: ArgoCD syncs the ConfigMap, but `subPath` volume mounts require a pod restart. Run `just update-homepage` in `k8s/helm/` instead of deleting the ConfigMap.
- **Uptime Kuma**: Monitors are defined as code in `manifests/uptime-kuma.yaml` under the `MONITORS` list in the `uptime-kuma-provisioner` ConfigMap.

## Integration Points
- **Storage**: Persistent volumes use NFS (`nfs-client` StorageClass) at `192.168.50.106:/export`.
- **ArgoCD Image Updater**: Uses CRD model (`ImageUpdater` CR). Set `useAnnotations: true` and use strategy `newest-build`.
- **Kustomize**: Avoid using the global `namespace:` field in `kustomization.yaml` if resources span multiple namespaces, as it overrides JSON patches.
