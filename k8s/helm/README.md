# Homelab Setup

## Techstack

- **Terraform** for infrastructure (Proxmox VMs) and external access (Cloudflare)
- **Ansible** for configuration management and K3s cluster setup
- **Helm** for managing Kubernetes applications
- **HashiCorp Vault** for centralized secret management
- **External Secrets Operator (ESO)** for syncing secrets to Kubernetes
- **Prometheus, Loki, Tempo, Grafana** (LGTM Stack) for observability
- **Cloudflare Tunnel** for secure, outbound-only external access
- **K8s Gateway API (Traefik)** for unified ingress routing

## Project Structure

```
homelab/
├── proxmox/          # Infrastructure provisioning on Proxmox
│   ├── terraform/
│   └── ansible/
├── k8s/
│   ├── ansible/      # K3s cluster setup and node config
│   └── helm/         # Application deployment
│       ├── values/
│       ├── manifests/
│       └── justfile
├── cloudflare/       # External access management
│   └── terraform/
└── README.md
```

## Quick Start

### 1. Provision VMs with Terraform

```bash
cd proxmox/terraform
just plan
just apply
```

### 2. Setup Kubernetes Cluster with Ansible

```bash
cd k8s/ansible
just setup-k8s
just fetch-kubeconfig
```

### 3. Deploy Observability Stack with Helm

```bash
cd k8s/helm
just init              # Create .env from template
vim .env               # Set your passwords
just deploy-all
```

## Security Best Practices

### Current Implementation (Phase 2)
- ✅ **HashiCorp Vault** for centralized, encrypted secret management.
- ✅ **External Secrets Operator (ESO)** to sync secrets from Vault to Kubernetes.
- ✅ **Raft Integrated Storage** for persistent, single-node high availability.
- ✅ Secrets are injected via standard Kubernetes Secrets, requiring no app code changes.
- ⚠️ Vault must be **unsealed** manually after pod restarts (via `just vault-unseal`).

## Vault & Secrets Management

We use HashiCorp Vault (KV v2) to manage credentials. Secrets are synced to Kubernetes using the External Secrets Operator.

### Initial Access & Authentication
Vault credentials and unseal keys are saved locally in `k8s/helm/vault-keys.json`.
**⚠️ Never commit `vault-keys.json` to Git.**

```bash
# Display UI access info and Root Token
just vault-ui
```

### Vault CLI Usage (Inside Pod)

To manage secrets via the command line, you can exec into the Vault pod:

```bash
# 1. Enter the pod
kubectl exec -ti vault-0 -n vault -- sh

# 2. Login with Root Token (from vault-keys.json)
export VAULT_TOKEN="hvs.xxxxxx"

# 3. List secrets
vault kv list secret/homelab

# 4. View a secret
vault kv get secret/homelab/cloudflare

# 5. Add/Update a secret
vault kv put secret/homelab/grafana admin-password="your-new-password"
```

### Unsealing Vault
If the Vault pod restarts, it enters a "Sealed" state and ESO will fail to sync secrets.
```bash
# Unseal Vault using the keys in vault-keys.json
just vault-unseal
```

## Accessing Services

```bash
# Grafana
cd k8s/helm
just grafana
# Open: http://localhost:3000
# Username: admin
# Password: (from your .env file)

# Prometheus
just prometheus
# Open: http://localhost:9090
```

## Secrets Management

### Current Approach
```bash
# Copy template and set your secrets
cp k8s/helm/.env.example k8s/helm/.env
vim k8s/helm/.env
```

### ⚠️ Important Security Notes
- **Never commit `.env` files to Git**
- Store backup of `.env` in a secure password manager
- Use strong, unique passwords (min 16 characters)
- Rotate passwords periodically

### Syncing to Kubernetes (ESO)
To make a Vault secret available to an application, create an `ExternalSecret` manifest in `k8s/helm/manifests/`.

Example `ExternalSecret` (`v1`):
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-app-secret
  namespace: my-namespace
spec:
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: k8s-secret-target-name
  data:
  - secretKey: my-key-name
    remoteRef:
      key: secret/homelab/my-secret-path
      property: password
```

## Persistent Storage

All observability services (Grafana, Prometheus, Loki, Tempo, Alertmanager) use NFS-backed PersistentVolumeClaims for data storage.  
Make sure your NFS server is available and properly configured before deploying the stack.

- StorageClass used: `nfs-client`
- Data is **not stored on local disks**; if NFS is unavailable, pods may fail to start or lose access to data.
