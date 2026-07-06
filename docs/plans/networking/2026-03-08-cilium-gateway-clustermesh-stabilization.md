# 2026-03-08 Cilium Gateway / ClusterMesh Stabilization

## Summary

This change set finishes the repository-side cleanup for the new ingress architecture and documents the operational recovery path for homelab.

Current target architecture:

- Cilium is the in-cluster CNI on both clusters.
- Cilium Gateway API is the only intended HTTP ingress controller.
- Cloudflare Tunnel forwards directly to the local `cilium-gateway-<gateway>.kube-system.svc:80` Service.
- Tailscale remains the inter-cluster underlay for Pod CIDR routing and operational access.
- ClusterMesh control-plane prerequisites stay enabled in Cilium values, but mesh connect is deferred until homelab is back on a stable Ubuntu 24.04 LTS kernel baseline.

## Why This Was Needed

The repo had already largely moved to the Cilium Gateway model, but a few current files still described or invoked the retired Traefik path. At the same time, homelab was unstable after enabling Cilium kube-proxy replacement and Gateway API on a development kernel (`6.19.0-6-generic`).

The practical result was a split-brain state:

- architecture docs said Cilium Gateway was current
- some helper commands still tried to apply `manifests/traefik-config.yaml`
- some operator docs still told users to run Proxmox Terraform through `make`
- homelab needed a documented recovery path before Gateway could be re-enabled safely

## Repository Changes

### 1. Current command surface aligned to Cilium Gateway

Updated `k8s/helm/justfile`:

- `deploy-gateway` now applies only `manifests/gateway.yaml`
- removed the stale Traefik restart path
- `delete-gateway` no longer deletes `manifests/traefik-config.yaml`
- ArgoCD install comment now reflects the real HTTP ingress path (`Cloudflare Tunnel -> Gateway`)

### 2. Current operator documentation aligned to `just`

Updated:

- `README.md`
- `.github/copilot-instructions.md`
- `docs/CONVENTIONS.md`
- `proxmox/terraform/README.md`

These now consistently document `proxmox/terraform/justfile` as the active workflow instead of `make`.

### 3. Recovery documentation added

Added:

- `docs/runbooks/homelab-rebuild-ubuntu-24-04.md`
- `docs/runbooks/README.md` entry

This runbook captures the shortest path to:

1. download the Ubuntu 24.04 LTS cloud image
2. recreate the Proxmox VM
3. reinstall K3s
4. reapply Cilium in conservative mode
5. defer Gateway/KPR re-enable until the node is stable

### 4. Architecture roadmap updated

Updated `docs/architecture/TODO.md` to reflect:

- Gateway standardization is already complete at the repo architecture level
- the remaining work is homelab rebuild, homelab Gateway restoration, and ClusterMesh connect validation

### 5. Observability wording corrected

Updated `docs/architecture/observability-multicluster.md` so the Cloudflare dashboard description no longer implies active Traefik router metrics.

## Runtime Status At Time Of Update

### oracle-k3s

- node is `Ready`
- Cilium Gateway Service exists
- oracle remains the known-good reference cluster for the new Cilium ingress model

### homelab

- rebuilt onto Ubuntu 24.04.4 LTS and validated on kernel `6.8.0-101-generic`
- Cilium was re-upgraded with:
  - `kubeProxyReplacement: true`
  - `gatewayAPI.enabled: true`
- `GatewayClass/cilium` now exists and `Gateway/kube-system/homelab-gateway` reaches `Accepted=True`, `Programmed=True`
- `service/cilium-gateway-homelab-gateway` is now created on homelab
- post-reboot recovery still needs hardening:
  - direct workstation access to `10.10.10.10:22/6443` can flap after VM resets
  - image pulls can transiently fail during restart storms
  - Vault / ESO dependent apps remain sensitive until Vault is fully ready again

### Additional hardening after live recovery

- homelab Ansible no longer enables `ufw`; the node now treats host firewalling as disabled-by-default because Cilium owns the datapath
- homelab provisioning now installs `qemu-guest-agent` and enables the Proxmox VM agent so guest inspection remains possible during future incidents

## Decision

Adopt the following staged path as the production baseline:

1. Keep oracle on full Cilium Gateway
2. Keep homelab on Ubuntu 24.04 LTS with Cilium Gateway enabled
3. Harden homelab reboot recovery path (guest agent, no UFW, Vault readiness)
4. Validate homelab services after control-plane restarts, not just clean boots
5. Only then execute ClusterMesh connect and failover validation

## Files Changed

- `.github/copilot-instructions.md`
- `README.md`
- `argocd/install/argocd-cm-patch.yaml`
- `docs/CONVENTIONS.md`
- `docs/architecture/TODO.md`
- `docs/architecture/observability-multicluster.md`
- `docs/runbooks/README.md`
- `docs/runbooks/homelab-rebuild-ubuntu-24-04.md`
- `k8s/helm/justfile`
- `k8s/helm/values/cilium-values.yaml`
- `proxmox/ansible/justfile`
- `proxmox/ansible/playbooks/download-cloud-image.yaml`
- `proxmox/terraform/README.md`
- `proxmox/terraform/terraform.tfvars`

## Follow-up

After homelab recovery, update this record with:

- service validation result
- date of ClusterMesh connect
