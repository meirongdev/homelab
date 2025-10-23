# Setup MicroK8s Cluster

## Prerequisites

- Based on [proxmox vm setup](../proxmox_vm/README.md)


## Functionality

### Install MicroK8s on all nodes

Run the Ansible playbook to install MicroK8s on all nodes:

```bash
cd ansible
just setup-k8s
```
If any issues, try to clean up and re-run:

```bash
just cleanup-k8s
just setup-k8s
```


