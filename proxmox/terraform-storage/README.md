# terraform-storage — storage-106 上的 VM

管 storage-106（Proxmox VE）上的虚机。目前只有一台：**k3s-exp 实验田**
（2c/3G/30G，独立单节点 k3s，不入 homelab 集群）。
为什么存在、8G 内存怎么分：[docs/decisions/storage106-experiment-vm.md](../../docs/decisions/storage106-experiment-vm.md)。

## 用法

```bash
just init    # 首次：生成 tfvars 骨架 + terraform init（记得填 token）
just plan
just apply
```

完整流程（VM 建好后装 k3s）：

```bash
cd proxmox/terraform-storage && just plan && just apply
cd ../ansible && just storage-arc-limit   # 若 ARC 还没降到 2G（apply VM 前该先做）
just exp-k3s                              # VM 内装 k3s
just exp-kubeconfig                       # 取 kubeconfig 到 ~/.kube/k3s-exp.yaml
```

## ⚠️ 两个坑

- **本机直连 PVE :8006 不通**（SSH 22 正常，`../terraform` README 里那个
  terraform "no route to host" 是同一件事）。`just plan/apply` 会自动起 SSH 隧道
  （`_tunnel`，10 分钟自动收），endpoint 默认即隧道地址，无需手工处理。
- **与 `../terraform`（pve 那个 root）刻意分离**：state 各管各的 API，
  任一台 PVE 失联不影响另一个 root 可操作。别合并。
