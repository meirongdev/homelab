# Homelab Setup

This project manages a home laboratory environment: infrastructure provisioning on Proxmox, Kubernetes cluster setup using K3s, application deployment via Helm, GitOps with ArgoCD, and secrets management with HashiCorp Vault + External Secrets Operator.

Network note: homelab now uses Cilium as the local CNI/data plane, while inter-cluster connectivity still rides on Tailscale. To keep the architecture simpler and more GitOps-friendly, homelab SSO no longer depends on oracle-k3s Service CIDR reachability; it calls the public `oauth.meirong.dev` endpoint instead. Cross-cluster Tailscale routing is also narrowed to Pod CIDRs only.

## Documentation Index

- **[Project Conventions & AI Guide](docs/CONVENTIONS.md)**: System design, tech stack, and development rules.
- **[Infrastructure (Proxmox/Terraform)](proxmox/README.md)**: VM provisioning and host preparation.
- **[Kubernetes (K3s/Ansible)](k8s/README.md)**: Cluster setup and node configuration.
- **[Applications (Helm/Manifests)](k8s/helm/README.md)**: Deploying the monitoring stack, databases, and personal services.
- **[External Access (Cloudflare/Terraform)](cloudflare/terraform/README.md)**: Tunnel and DNS management.
- **[GitOps (ArgoCD)](argocd/)**: Application manifests and AppProject definitions.
- **[Project Roadmap](docs/architecture/TODO.md)**: Current status and future plans.

## Quick Start Summary

1. **Infrastructure**: `cd proxmox/terraform && make init && make apply`
2. **Kubernetes**: `cd k8s/ansible && just setup-k8s && just fetch-kubeconfig`
3. **Observability stack**: `cd k8s/helm && just init && just deploy-all`
4. **Secrets**: `cd k8s/helm && just deploy-vault && just vault-init && just vault-unseal && just deploy-eso`
5. **GitOps**: `cd k8s/helm && just deploy-argocd` — ArgoCD then auto-deploys all managed apps from Git
6. **External Access**: `cd cloudflare/terraform && just init && just apply`

---
For AI assistant context, this project uses `docs/CONVENTIONS.md` (linked as `CLAUDE.md` and `GEMINI.md` in root).
