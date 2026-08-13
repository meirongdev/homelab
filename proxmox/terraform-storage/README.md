# terraform-storage — storage-106 上的 VM

管 storage-106（Proxmox VE）上的虚机。目前只有一台（2c/3G/30G）。

⚠️ **它的角色 2026-08-13 变过一次**：先是「独立单节点 k3s 实验田（k3s-exp）」，
同日改为 **homelab 集群的 worker `k8s-worker-106`**。VM 的 terraform 定义没变
（名字仍是 `k3s-exp`，改名要 destroy/recreate，不值得），变的是里面装什么。
- 现行决策：[storage106-as-homelab-worker](../../docs/decisions/storage106-as-homelab-worker.md)
- 8G 内存三方分配的推导仍在被取代的那份：[storage106-experiment-vm](../../docs/decisions/storage106-experiment-vm.md)

## 用法

```bash
just init    # 首次：生成 tfvars 骨架 + terraform init（记得填 token）
just plan
just apply
```

完整流程（VM 建好后入编 homelab 集群）：

```bash
cd proxmox/terraform-storage && just plan && just apply
cd ../ansible && just storage-arc-limit    # 若 ARC 还没降到 2G（apply VM 前该先做）

# 以下在 k8s/ansible/ —— 原 proxmox/ansible 的 exp-k3s/exp-kubeconfig 已随实验田退役
cd ../../k8s/ansible
just setup-tailscale-worker "$(cd ../../tailscale/terraform && just homelab-worker-authkey)"
just join-worker
```

☠️ 两条必须按顺序、且**别在 `setup-tailscale-worker` 跑到一半中断它**：
`tailscale up` 之后、ip-rule 防护装上之前有个窗口，节点会把自己的 LAN 流量卷进隧道
从而 SSH 不可达（要从 tailnet 抢救）。取证见
[records/2026-08-13-k3s-worker-join-106.md](../../docs/records/2026-08-13-k3s-worker-join-106.md)。

## ⚠️ 两个坑

- **本机直连 PVE :8006 不通**（SSH 22 正常，`../terraform` README 里那个
  terraform "no route to host" 是同一件事）。`just plan/apply` 会自动起 SSH 隧道
  （`_tunnel`，10 分钟自动收），endpoint 默认即隧道地址，无需手工处理。
- **与 `../terraform`（pve 那个 root）刻意分离**：state 各管各的 API，
  任一台 PVE 失联不影响另一个 root 可操作。别合并。
