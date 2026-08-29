# Proxmox — VM 预配与宿主运维

两台 Proxmox VE 宿主，各跑一台 K3s 节点的 VM：

| 宿主 | 地址 | 上面的 VM | 目录 |
|------|------|-----------|------|
| `pve`（Ryzen 5600H 笔记本） | `192.168.50.4` | homelab **控制面** `k8s-node`（10 vCPU / 13312MB，实值在 gitignored 的 `terraform.tfvars`，**不是 variables.tf 的默认值**） | `terraform/` |
| `storage-106`（Celeron J4105 NAS） | `192.168.50.106` | VMID 200 = homelab **worker** `k8s-worker-106`（2c/4G/30G，VM 名仍是 `k3s-exp`） | `terraform-storage/` |

⚠️ 106 不只是"备份机"：它同时是 worker 的宿主和媒体只读 NFS 的源，宕机会拿走一个节点 +
三个媒体服务。→ [docs/reference/storage.md](../docs/reference/storage.md)

## 目录

- **`terraform/`** — pve 上的 k8s-node VM。`just init/plan/apply`。
- **`terraform-storage/`** — 106 上的 worker VM（2026-08-15 起）。同样用 `just`。
  详见该目录 README；内存分配链在 `variables.tf` 的注释里。
- **`ansible/`** — 两台宿主的运维：cloud image 下载、省电/散热
  （`just power-optimize` / `console-screen-off`）、node_exporter + smartctl_exporter
  （`just node-exporter` / `node-exporter-storage`）、106 的 ZFS/NFS/sanoid
  （`storage-playbook.yaml`、`just storage-arc-limit`）、worker VM 周备
  （`just vzdump-worker`）。

## 相关文档

- 宿主功耗/散热/内存分配（唯一真相源）：[docs/reference/homelab-host-power-thermal.md](../docs/reference/homelab-host-power-thermal.md)
- 106 的角色与三重身份：[docs/reference/storage.md](../docs/reference/storage.md)
- worker 入编决策：[docs/decisions/storage106-as-homelab-worker.md](../docs/decisions/storage106-as-homelab-worker.md)
