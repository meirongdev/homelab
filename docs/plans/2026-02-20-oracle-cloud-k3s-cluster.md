# Oracle Cloud Free Tier K3s Cluster Implementation Plan

**Date:** 2026-02-20
**Status:** Approved (Revised 2026-02-21)

## Goal

Bring the existing Oracle Cloud ARM VM under Terraform management and transform it into a high-performance K3s cluster. This "Import and Refactor" approach ensures we do not lose the "Always Free" ARM slot while maximizing its resources (4 OCPUs, 24GB RAM).

---

## Architecture

### OCI Infrastructure (Layer 1)

| Component | Specification | Free Tier Strategy |
|-----------|---------------|-------------------|
| **Compute Instance** | Ampere A1 (ARM) | **4 OCPUs, 24GB RAM** (Maxed) |
| **Boot Volume** | 200 GB (Balanced) | **100% of Free Quota** assigned to one VM |
| **Network** | VCN + Public Subnet | Standard Free Tier |
| **Security** | OCI Security List | Hardened: 22 (SSH), 6443 (API), 80/443 (Web) |

### Kubernetes Layer (Layer 2)

| Component | Detail |
|-----------|--------|
| **Distribution** | K3s (Single Node) |
| **Storage Class** | `local-path` (K3s built-in — no OCI CSI needed for single node) |
| **Ingress** | Traefik (integrated) + Cloudflare Tunnel |
| **Backup** | Kopia (future) |

---

## Implementation Phases

### Phase 0 — Discovery & OS Rebuild ✅

~~Instead of terminating the instance, we will use the OCI "Rebuild Instance" feature to reinstall a fresh OS while retaining the ARM capacity slot and Instance OCID.~~

**Status: Complete.** Instance has been rebuilt to **Ubuntu 24.04.4 LTS**.

### Phase 1 — Infrastructure via Terraform (OCI provider >= 8.0.0)

**Files:** `cloud/oracle/terraform/*.tf`
**Task runner:** `make` (consistent with `proxmox/terraform/`)

- **VCN/Subnet/IGW:** Import existing network resources.
- **Security List:** Define ingress rules for K3s (6443) and Web traffic (80/443).
- **Compute:** Define the `oci_core_instance` resource with the desired shape and metadata.
- **Cloud-Init:** Use `user_data` for OS updates and basic hardening (reference only — does not re-run on import).
- **State:** Local state file (gitignored). Consistent with `proxmox/terraform/` approach.

### Phase 2 — K3s Cluster Setup

**Files:** `cloud/oracle/ansible/`

- **Automated Install:** Ansible (consistent with `k8s/ansible/` pattern).
- **SSH user:** `ubuntu` (OCI default for Ubuntu images).
- **K3s flags:**
  - `--write-kubeconfig-mode 644`
  - `--disable servicelb` (Cloudflare Tunnel handles external access)
  - `--node-name oracle-k3s`
- **Kubeconfig:** Merge to local `~/.kube/config` with context name `oracle-k3s`.

### Phase 3 — GitOps Integration

- **ArgoCD:** Register oracle cluster as a destination in the existing homelab ArgoCD.
- **Cloudflare:** Add `oracle.meirong.dev` subdomain to `cloudflare/terraform/terraform.tfvars` and run `just apply`.

---

## Maximizing Resources

- **CPU/RAM:** Full `4 OCPUs` and `24GB RAM` in a single instance (no overhead from multiple VMs).
- **Storage:** Full `200GB` boot volume. Use K3s built-in `local-path` StorageClass — simple and sufficient for a single node. No OCI CSI driver required.
- **Networking:** Public IP + direct SSH/API access. Web traffic tunneled via Cloudflare.

---

## Next Steps

1. **Variable Collection:** Gather OCIDs for Instance, VCN, Subnet, IGW, Route Table, Security List from OCI Console.
2. **Fill tfvars:** Copy `terraform.tfvars.example` → `terraform.tfvars`, fill in all values.
3. **Terraform Import:** Run `make import <OCIDs>` to bring existing resources into state.
4. **Terraform Apply:** Run `make apply` to scale instance to 4 OCPUs / 24GB RAM if not already maxed.
5. **K3s Install:** Run Ansible from `cloud/oracle/ansible/`.
6. **Fetch Kubeconfig:** Merge oracle cluster context into local `~/.kube/config`.
