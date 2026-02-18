# Setup K3s Cluster

## Prerequisites

- Based on [Proxmox VM Setup](../proxmox/README.md) (infrastructure must be provisioned first)


## Functionality

### Install K3s on the single node

Run the Ansible playbook to install K3s on the provisioned VM:

```bash
cd ansible
just setup-k8s
```
If any issues, try to clean up and re-run:

```bash
just cleanup-k8s
just setup-k8s
```


