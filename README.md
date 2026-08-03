# Homelab Setup

This project manages a home laboratory environment: infrastructure provisioning on Proxmox, Kubernetes cluster setup using K3s, application deployment via Helm, GitOps with ArgoCD, and secrets management with HashiCorp Vault + External Secrets Operator.

Network note: both clusters now use Cilium for the local data plane and Gateway API ingress, while inter-cluster connectivity still rides on Tailscale. After rebuilding either cluster, re-run `just connect-clustermesh <homelab-ts-ip>:32379 <oracle-ts-ip>:32379` from `k8s/helm/` or `cloud/oracle/` so ClusterMesh refreshes the remote config and CA bundle over the Tailscale NodePort path.

## Documentation Index

- **[Docs Portal](docs/README.md)**: start here — 分层说明与全部入口。
- **[Project Conventions & AI Guide](docs/AGENTS.md)**: 唯一的 AI 助手上下文文件（命令、约定、硬约束）；各组件细节在 [docs/reference/](docs/reference/README.md)。
- **[New machine bootstrap](docs/guides/dev-machine-bootstrap.md)**: 换机器后把本机配到能 clone/改/验这个 repo。
- **[Project Roadmap](docs/ROADMAP.md)**: Current status and future plans.

每个顶层目录都有自己的 README，说明它管什么、怎么跑：

| 目录 | 管什么 |
|---|---|
| [proxmox/](proxmox/README.md) | Proxmox VM 预配与宿主机准备 |
| [k8s/](k8s/README.md) | K3s 集群安装与节点配置（应用部署见 [k8s/helm/](k8s/helm/README.md)） |
| [cloud/](cloud/README.md) | 云厂商基础设施（目前只有 [Oracle Cloud](cloud/oracle/README.md)） |
| [argocd/](argocd/README.md) | GitOps 控制面：Application / AppProject（**控制面在 oracle-k3s**） |
| [cloudflare/](cloudflare/README.md) | 对外接入：DNS + Tunnel + WAF |
| [tailscale/](tailscale/README.md) | 跨集群网络：ACL + 预授权密钥 |
| [zitadel/](zitadel/README.md) | 身份 / SSO（`auth.meirong.dev`） |
| [backup/](backup/README.md) | restic 夜备（双集群 → 106） |
| [macbook/](macbook/README.md) | 远程无头 M2 MacBook 的 Ansible 配置 |
| [images/](images/README.md) | 自建容器镜像（Dockerfile 源） |

## Quick Start Summary

1. **Infrastructure**: `cd proxmox/terraform && just init && just apply`
2. **Kubernetes**: `cd k8s/ansible && just setup-k8s && just fetch-kubeconfig`
3. **Secrets**: `cd k8s/helm && just deploy-vault && just vault-init && just vault-unseal && just deploy-eso`
4. **GitOps**: `cd k8s/helm && just deploy-argocd`（装控制面到 **oracle-k3s**）然后
   `just deploy-argocd-apps`（注册 Application，**是单独一步**）— 之后 ArgoCD 自动部署
   Git 里全部纳管应用，包括 LGTM/otel/external-dns（改 `k8s/helm/values/` 或
   `argocd/applications/` + `git push` 生效）
5. **External Access**: `cd cloudflare/terraform && just init && just apply`

---
For AI assistant context this project uses **one file**, symlinked so each tool finds its own name:

| File | Symlinked from | Role |
|---|---|---|
| `docs/AGENTS.md` | `AGENTS.md`, `CLAUDE.md`, `.gemini.md`, `.github/copilot-instructions.md` | 唯一常驻上下文（~9 KB）：命令、约定、硬约束 + 按域指向 `docs/reference/` |

2026-08-03 起收敛为单文件（此前的长版 CONVENTIONS 文件已按 R1 拆进 `docs/reference/`
各域文档并删除）：常驻上下文保持精简，组件级细节按需读 reference——**长内容不要往
AGENTS.md 里搬**。
