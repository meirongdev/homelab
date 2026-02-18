# Homelab Setup

This project manages a home laboratory environment, including infrastructure provisioning on Proxmox, Kubernetes cluster setup using K3s, and application deployment via Helm.

## Documentation Index

- **[Project Conventions & AI Guide](docs/CONVENTIONS.md)**: System design, tech stack, and development rules.
- **[Infrastructure (Proxmox/Terraform)](proxmox/README.md)**: VM provisioning and host preparation.
- **[Kubernetes (K3s/Ansible)](k8s/README.md)**: Cluster setup and node configuration.
- **[Applications (Helm/Manifests)](k8s/helm/README.md)**: Deploying the monitoring stack, databases, and personal services.
- **[External Access (Cloudflare/Terraform)](cloudflare/terraform/README.md)**: Tunnel and DNS management.
- **[Project Roadmap](docs/architecture/TODO.md)**: Current status and future plans.

## Quick Start Summary

1. **Infrastructure**: `cd proxmox/terraform && just init && just apply`
2. **Kubernetes**: `cd k8s/ansible && just setup-k8s && just fetch-kubeconfig`
3. **Applications**: `cd k8s/helm && just init && just deploy-all`
4. **External Access**: `cd cloudflare/terraform && just init && just apply`

---
For AI assistant context, this project uses `docs/CONVENTIONS.md` (linked as `CLAUDE.md` and `GEMINI.md` in root).
