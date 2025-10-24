# Homelab Setup

## Techstack

- **Terraform** for infrastructure as code
- **Ansible** for configuration management, setting up k8s cluster with MicroK8s
- **Helm** for managing Kubernetes applications
- **Prometheus, Loki, Tempo, Grafana** for Observability

## Project Structure

```
homelab/
├── proxmox_vm/          # Terraform configs for VM provisioning
│   └── terraform/
├── k8s/
│   ├── ansible/         # Kubernetes cluster setup with MicroK8s
│   │   ├── playbooks/
│   │   └── justfile
│   └── helm/            # Application deployment with Helm
│       ├── values/
│       ├── .env.example # Template for secrets (copy to .env)
│       └── justfile
└── README.md
```

## Quick Start

### 1. Provision VMs with Terraform

```bash
cd proxmox_vm/terraform
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

### Current Implementation (Phase 1)
- ✅ Secrets stored in local `.env` files (not committed to Git)
- ✅ Kubernetes Secrets used for in-cluster secret management
- ⚠️ `.env` files must be managed manually on each machine

### Future Enhancements (Phase 2 - Planned)
- 🔄 **HashiCorp Vault integration** for centralized secret management
- 🔄 **External Secrets Operator** to sync secrets from Vault to Kubernetes
- 🔄 **Automatic secret rotation** and audit logging
- 🔄 **Dynamic secrets** for database credentials

**Migration Path**: Current `.env` approach is designed to be easily replaceable with Vault without changing application configurations.

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

### Future: Migrating to Vault
See [`docs/vault-migration.md`](docs/vault-migration.md) for the planned migration guide.

## Persistent Storage

All observability services (Grafana, Prometheus, Loki, Tempo, Alertmanager) use NFS-backed PersistentVolumeClaims for data storage.  
Make sure your NFS server is available and properly configured before deploying the stack.

- StorageClass used: `nfs-client`
- Data is **not stored on local disks**; if NFS is unavailable, pods may fail to start or lose access to data.
