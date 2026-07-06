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

#### 3a. Register Oracle Cluster in Homelab ArgoCD (Method: Manual Cluster Secret)

**Step 1 — Create ArgoCD ServiceAccount on oracle cluster**

```bash
kubectl config use-context oracle-k3s

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF
```

**Step 2 — Extract token and CA cert**

```bash
TOKEN=$(kubectl get secret argocd-manager-token -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d)

CA_CERT=$(kubectl get secret argocd-manager-token -n kube-system \
  -o jsonpath='{.data.ca\.crt}')
```

**Step 3 — Create cluster Secret on homelab ArgoCD**

```bash
kubectl config use-context k3s-homelab

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: oracle-k3s-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: oracle-k3s
  server: https://152.69.195.151:6443
  config: |
    {
      "bearerToken": "${TOKEN}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${CA_CERT}"
      }
    }
EOF
```

**Step 4 — Update homelab AppProject to allow oracle cluster as destination**

Add to `argocd/projects/homelab.yaml` destinations:
```yaml
- server: https://152.69.195.151:6443
  namespace: "*"
```

Then apply: `kubectl apply -f argocd/projects/homelab.yaml`

**Token 丢失恢复：**
- 从 homelab 取回：`kubectl get secret oracle-k3s-cluster -n argocd -o jsonpath='{.data.config}' | base64 -d`
- 或在 oracle 上重建 token Secret：删除 `argocd-manager-token` 再重建，更新 homelab cluster Secret

#### 3b. Cloudflare DNS

- Add `oracle.meirong.dev` to `cloudflare/terraform/terraform.tfvars`
- Run `just apply` from `cloudflare/terraform/`

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
