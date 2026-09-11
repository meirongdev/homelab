# terraform — pve 上的控制面 VM

管 `pve`（Ryzen 5600H 笔记本，Proxmox VE）上的虚机。目前只有一台：**VMID 100 `k8s-node`**，
homelab 集群的控制面（10 vCPU / 13312MB / 120G，真值就是 `variables.tf` 的默认值，带推导注释）。

- 宿主功耗/散热/内存分配链（唯一真相源）：[docs/reference/homelab-host-power-thermal.md](../../docs/reference/homelab-host-power-thermal.md)
- 重启窗口与重启后验证：[docs/runbooks/proxmox-host-upgrade.md](../../docs/runbooks/proxmox-host-upgrade.md)
- 106 上的 worker VM 在 [../terraform-storage](../terraform-storage/README.md)，两个 root 写法同构。

## 用法

```bash
cd proxmox/terraform
just init    # 首次：生成 tfvars 骨架 + terraform init（填 root 密码与公钥）
just plan    # 自动起 SSH 隧道（本机直连 :8006 不通）
just apply
```

☠️ `terraform plan` 出现 `-/+`（replace）就停：VM 盘上有 homelab 全部 local-path PVC。
VM 已设 `protection = true`，PVE API 会拒绝删 VM/删盘，`just destroy` 也会被挡。

## ⚠️ 四个坑

- **改动分两类**：description/tags/protection/ostype/tablet 立即生效；cores/memory/磁盘选项
  （discard/ssd/iothread）/scsihw/vga **pending 到下次 VM 重启**，`qm pending 100` 可查。
  provider 的 `reboot_after_update` 已显式关掉，否则它会为 pending 改动当场重启控制面。
- **本机直连 PVE :8006 不通**（SSH 22 正常）：`just plan/apply` 自动起隧道（`_tunnel`，
  端口 18007，15 分钟自动收），endpoint 默认即隧道地址。
- **认证还是 root 密码**：106 root 已是专属 API token，这边的三步迁移写在 `provider.tf` 注释里，
  涉及新建凭据，留给人做。
- **cloud image 不由本 root 下载**：`disk.file_id` 指向 `local:iso/...`，由
  `proxmox/ansible` 的 `just download-cloud-image` 事先放好（106 root 用的是 download_file 资源）。
- ☠️ **provider 0.85.1 送不出既有盘的 discard/ssd/iothread 改动**：apply 报成功、下次 plan 同样的 diff 又回来。
  这几项要在宿主上用 `qm set <vmid> --scsi0 "<整串>"` 手动写进 pending（命令模板在 `main.tf` 注释里），
  写完 plan 才会 No changes。
