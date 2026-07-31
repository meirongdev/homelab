# Homelab Setup

This project manages a home laboratory environment: infrastructure provisioning on Proxmox, Kubernetes cluster setup using K3s, application deployment via Helm, GitOps with ArgoCD, and secrets management with HashiCorp Vault + External Secrets Operator.

Network note: both clusters now use Cilium for the local data plane and Gateway API ingress, while inter-cluster connectivity still rides on Tailscale. After rebuilding either cluster, re-run `just connect-clustermesh <homelab-ts-ip>:32379 <oracle-ts-ip>:32379` from `k8s/helm/` or `cloud/oracle/` so ClusterMesh refreshes the remote config and CA bundle over the Tailscale NodePort path.

## Documentation Index

- **[Docs Portal](docs/README.md)**: start here — 分层说明与全部入口。
- **[Project Conventions & AI Guide](docs/AGENTS.md)**: Project context for AI assistants (Codex, Claude).
  - Full conventions: [docs/CONVENTIONS.md](docs/CONVENTIONS.md)
- **[Infrastructure (Proxmox/Terraform)](proxmox/README.md)**: VM provisioning and host preparation.
- **[Kubernetes (K3s/Ansible)](k8s/README.md)**: Cluster setup and node configuration.
- **[Applications (Helm/Manifests)](k8s/helm/README.md)**: Deploying the monitoring stack, databases, and personal services.
- **[External Access (Cloudflare/Terraform)](cloudflare/terraform/README.md)**: Tunnel and DNS management.
- **[GitOps (ArgoCD)](argocd/)**: Application manifests and AppProject definitions.
- **[Project Roadmap](docs/ROADMAP.md)**: Current status and future plans.

## Quick Start Summary

1. **Infrastructure**: `cd proxmox/terraform && just init && just apply`
2. **Kubernetes**: `cd k8s/ansible && just setup-k8s && just fetch-kubeconfig`
3. **Secrets**: `cd k8s/helm && just deploy-vault && just vault-init && just vault-unseal && just deploy-eso`
4. **GitOps**: `cd k8s/helm && just deploy-argocd` — ArgoCD then auto-deploys all managed apps from Git，包括 LGTM/otel/external-dns（改 `k8s/helm/values/` 或 `argocd/applications/` + `git push` 生效）
5. **External Access**: `cd cloudflare/terraform && just init && just apply`

---
For AI assistant context this project uses two files, both symlinked so each tool finds its own name:

| File | Symlinked from | Role |
|---|---|---|
| `docs/AGENTS.md` | `AGENTS.md`, `CLAUDE.md` | condensed always-on context (~5 KB); points to the file below for depth |
| `docs/CONVENTIONS.md` | `.gemini.md`, `.github/copilot-instructions.md` | full conventions + architecture + per-component gotchas (~60 KB) |

The split is deliberate: tools that auto-load a context file get the small one, so the long one
isn't pulled into every session. **Keep the two consistent when either changes.**
