# Setup K3s Cluster

homelab 集群的安装与节点管理（Ansible）。集群自 2026-08-13 起是**双节点**：
control-plane `k8s-node`（pve 上的 VM）+ worker `k8s-worker-106`（storage-106 上的 VM）。

## Prerequisites

- 控制面节点的 VM 由 [Proxmox VM Setup](../proxmox/README.md) 预配（`proxmox/terraform`）；
  worker 的 VM 由 `proxmox/terraform-storage` 预配。
- Cilium values 在 `cilium/`（**manual-helm，不走 ArgoCD**），应用部署在 `helm/`。

## Functionality

### 装控制面

```bash
cd ansible
just setup-k8s          # 在 LAN 内（经 pve 跳板）
just setup-k8s-remote   # 不在 LAN 时，走 Tailscale
```

出问题就清干净重来：

```bash
just cleanup-k8s
just setup-k8s
```

### 加 worker

```bash
cd ansible
just join-worker        # playbooks/setup-k3s-worker.yaml
```

⚠️ **动 worker 前先读 `playbooks/setup-k3s-worker.yaml` 的文件头三条约束**：它与控制面
**不在同一网段**（LAN `192.168.50.0/24` vs pve 内的 `10.10.10.0/24`），并且多一条 ip rule。
取舍见 [decisions/storage106-as-homelab-worker.md](../docs/decisions/storage106-as-homelab-worker.md)。

### 其它

```bash
just fetch-kubeconfig   # 取 kubeconfig（context 名 k3s-homelab）
just fix-dns            # 节点 DNS 回退（playbooks/fix-dns-fallback.yaml）
just update-firewall
just install-node-exporter
```
