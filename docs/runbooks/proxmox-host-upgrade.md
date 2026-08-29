# Proxmox 宿主升级（内核 + PVE 本体）

> Last updated: 2026-08-29
> Status: SOP —— `pve` 已于 2026-08-29 按本文执行完毕，`storage-106` 待做（见 §8）。
> 触发条件：要升 `pve` / `storage-106` 的内核或 PVE 本体；或发现这两台**长期收不到任何
> Proxmox 更新**（`apt list --upgradable` 里一条 `proxmox-*` 都没有）。
> ⛔ **不适用于两台 k8s 节点** —— `k8s-node` / `k8s-worker-106` 是普通 Ubuntu，
> unattended-upgrades 会自动装新内核，只差重启，流程完全不同（见 §7）。
> 成功判定：`pveversion` 是新版本 · `uname -r` 是 `proxmox-default-kernel` 当前指向的系列
> （2026-08-29 实测为 `7.0.x-*-pve`）·
> `zfs version` 的 userland 与 kmod **同版本** · `zpool status mrstorage` ONLINE（仅 106）·
> `qm list` 里 VM 自己起来了 · 从 `k8s-node` 能挂上 106 的 NFS。
> 回滚：见 §6（GRUB 一次性回旧内核 / 删仓库文件）。
> ☠️ **唯一不可回滚的动作是 `zpool upgrade`，本流程任何一步都不需要它 —— 别跑**。

## 1. 根因：这两台宿主根本没有 Proxmox 软件源

不是没人升，是 apt 里**没有任何 Proxmox 仓库**：

| 宿主 | `/etc/apt/sources.list.d/` 实况 |
|------|--------------------------------|
| `pve` | `pve-enterprise.sources.bak` + `ceph.sources.bak` —— 都被改名**禁用**，没有替代源 |
| `storage-106` | 只有 `debian.sources` + `tailscale.list`，Proxmox 源**从来没配过** |

两台都 `pvesubscription get` → `status: notfound`，所以正解是配 **`pve-no-subscription`**，
而不是把 enterprise 打开（无订阅时它 401，等于没配）。

后果是两台一起冻住，而 Debian 那半边一直在更新：

| | 现装 | `pve-no-subscription` 里有 |
|---|------|--------------------------|
| 内核 | `proxmox-kernel-6.14` 6.14.8-2 | `proxmox-kernel-7.0`（由 `proxmox-default-kernel` 定为默认）· 6.17 与 6.14 系列同时在架 |
| PVE | `pve-manager` 9.0.3 | `pve-manager` 9.2.x |
| ZFS | 2.3.3-pve1 | 2.4.x-pve1 |

> 版本号会继续走，**别照抄上表的具体小版本**，执行时用 §4.2 现取。

两台都是**独立节点**（无 corosync 集群）、根文件系统 `ext4` on LVM、**不是 ZFS-on-root**，
因此没有 `proxmox-boot-tool`（`/etc/kernel/proxmox-boot-uuids` 不存在），
引导走普通 GRUB —— 这决定了 §6 的回滚方式。

## 2. ☠️ 顺序反了会装上 `zfs-dkms`

**先配 Proxmox 源，再跑任何 `apt upgrade`。** 反过来会踩这个：

Debian `trixie-security` 现在提供 ZFS **2.3.9-0+deb13u1**，比 Proxmox 的
**2.3.3-pve1** 版本号高。在**没有 Proxmox 源竞争**的当下，apt 会认为它就该升 ——
2026-08-29 在两台上分别 `apt-get -s full-upgrade` 实测：

```
# storage-106
30 upgraded, 3 newly installed, 0 to remove
Inst dkms (3.2.2-1~deb13u1 Debian:13.6/stable [all])
Inst zfs-dkms (2.3.9-0+deb13u1 Debian-Security:13/stable-security [all])
Inst zfs-initramfs [2.3.3-pve1] (2.3.9-0+deb13u1 ...)
Inst zfsutils-linux [2.3.3-pve1] (2.3.9-0+deb13u1 ...)

# pve
35 upgraded, 11 newly installed, 0 to remove   ← 同样含 dkms + zfs-dkms
```

两个问题叠在一起：

1. **`zfs-dkms` 会在本机现编一份 `zfs.ko`**，与 `proxmox-kernel-*` **自带**的那份打架。
   Proxmox 的 ZFS 模块是随内核包发的，宿主上装 DKMS 版本属于配置错误。
2. **userland 与 kmod 版本劈叉**：用户态换成 2.3.9、模块还是内核里的 2.3.3。

在 `storage-106` 上这台机器承载 `mrstorage`（10.9T，含 `mrstorage/restic` 备份仓库
与全部 NFS 导出），不值得拿它试。

**配好 Proxmox 源后这个问题自动消失** —— Proxmox 提供的 2.4.x-pve1 高于 Debian 的
2.3.9，apt 自然选 Proxmox 的，userland 与 kmod 一起走。

### 可选加固：永久禁止 `zfs-dkms`

宿主上**任何情况下都不该有** `zfs-dkms`，钉死它没有维护成本：

```bash
# 在宿主上（root）
cat > /etc/apt/preferences.d/99-no-zfs-dkms <<'EOF'
# Proxmox 的 ZFS 模块随 proxmox-kernel-* 分发，宿主永不使用 DKMS 版本。
Package: zfs-dkms
Pin: release *
Pin-Priority: -1
EOF
apt-cache policy zfs-dkms | head -3   # 应显示 Candidate: (none)
```

## 3. 停机面与维护窗口

| 动作 | 直接影响 |
|------|---------|
| 重启 `pve` | VM 100 `k8s-node` 下线 = **homelab 控制面** + Prometheus/Grafana/Alertmanager + `cloudflared`（公网入口）全断 |
| 重启 `storage-106` | VM 200 `k3s-exp`（= 节点 `k8s-worker-106`）下线 **+** 5 个只读媒体 NFS **+** restic 备份目标 **+** `pve` 的 `backups` 存储（它是 106 的 NFS 导出）一起没 |

两台 VM 都是 `onboot: 1`，宿主起来后**会自动拉起**，不需要手工 `qm start`。

**避开这些窗口**（restic + vzdump）：

| 时间 | 任务 |
|------|------|
| 每天 02:00 | restic `homelab-worker` |
| 每天 03:00 | restic `homelab`（控制面）|
| 每天 03:30 | restic `oracle` |
| 周日 03:30 | `pve` vzdump `weekly-vm100` → 存到 **106 的 NFS** |
| 周日 05:00 | `106` vzdump `vzdump-worker106` |

**建议顺序：`pve` 先，`storage-106` 后**，两台之间留出一台完全恢复的时间。理由是
`pve` 的备份存储挂在 106 上；先动 106 会让 `pve` 侧留下 stale NFS 挂载，多一个变量。

## 4. 执行步骤（每台各跑一遍）

以下命令都在**宿主本机**以 root 执行。登录方式：

```bash
ssh -i ~/.ssh/vgio root@192.168.50.4        # pve
ssh -i ~/.ssh/vgio mr@100.110.27.111        # storage-106（然后 sudo -i）
```

### 4.1 先存一份现状，出事好比对

```bash
uname -r; pveversion; zfs version
dpkg -l | grep -E 'proxmox-kernel|zfs' > /root/pre-upgrade-pkgs.txt
qm list > /root/pre-upgrade-vms.txt
zpool status > /root/pre-upgrade-zpool.txt 2>/dev/null   # 仅 106
```

### 4.2 配 `pve-no-subscription` 源

keyring 两台都已存在（`/usr/share/keyrings/proxmox-archive-keyring.gpg`），只需加文件：

```bash
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt-get update
apt list --upgradable 2>/dev/null | grep -E 'proxmox|pve-|zfs'
```

> `pve` 上那两个 `.bak` **不要**改回来 —— 无订阅时 enterprise 源只会让 `apt-get update` 报 401。

### 4.3 先看它到底要做什么（关键一步，别跳）

```bash
apt-get -s full-upgrade | grep -E '^Inst (zfs|dkms|proxmox-kernel|pve-)|newly installed'
```

**放行判据**（三条都要满足，否则停下来查）：

- 出现 `Inst proxmox-kernel-<新系列> ...` 与 `Inst proxmox-default-kernel ...`
  ☠️ **别把系列号写死在判据里** —— 2026-08-29 首次执行时就已经是 7.0 而非 6.17
- ZFS 各包的来源是 **Proxmox**（版本号带 `-pve1`），**不是** `Debian-Security`。
  ⚠️ 2.3.x → 2.4.x 会做 **soname 迁移**，正常形态长这样，不要误判为异常：
  `Remv libzfs6linux` + `Inst libzfs7linux (2.4.4-pve1)`。
  ☠️ 但 **`libzpool6linux` 是个例外**：它被标成 manual、且旧版 `zfsutils-linux` 对它有依赖记录，
  apt 不会顺手删，反而会把它从 **Debian-Security 升到 2.3.9**。它在升级后没有任何消费者
  （新 `zfsutils-linux 2.4.4-pve1` 只依赖 `libzpool7linux`），**升级后定点删掉**即可，
  别用 `apt autoremove`（会连旧内核一起带走）：

  ```bash
  dpkg -s zfsutils-linux | grep ^Depends   # 确认只依赖 libzpool7linux
  apt-get -s remove libzpool6linux         # 确认只删它一个、无级联
  apt-get remove libzpool6linux
  ```
- **没有** `Inst zfs-dkms`

### 4.4 升级

```bash
apt-get full-upgrade
```

⚠️ 这不只是内核 —— `pve-manager` 会从 9.0.3 升到 9.2.x，**PVE 本体也在升**。
在 Proxmox 上这两者不可分割（不支持只挑内核升），要有心理准备。
过程中若提示配置文件冲突，`/etc/` 下的本地改动一律**保留现有版本**（默认选项 `N`），
事后再逐个比对。

☠️ **升级后不要跑 `apt autoremove`** —— 它会把旧的 `proxmox-kernel-6.14` 一并清掉，
而那正是 §6 回滚要引导的内核。等新内核**稳定跑过几天**再清理：

```bash
dpkg -l | grep proxmox-kernel      # 确认新旧系列并存后再谈清理
```

### 4.5 重启并验证

```bash
reboot
```

回来后：

```bash
uname -r                       # 7.0.x-*-pve（以 proxmox-default-kernel 为准）
pveversion                     # 9.2.x
systemctl --failed             # 应为空
qm list                        # VM 自动起来了（onboot: 1）
zfs version                    # userland 与 kmod 必须同版本
zpool status mrstorage         # 仅 106：ONLINE，无 DEGRADED/错误计数
exportfs -s | head             # 仅 106：导出还在
```

⚠️ **重启窗口内 oracle 侧会出现预期内的瞬时 Degraded**：Vault 跑在 homelab，
`pve` 一停，oracle 那些跨集群读 Vault 的 ExternalSecret 就会失败，ArgoCD 把对应 App
标成 `Degraded`。刷新间隔短的（如 `argocd-oidc`，1m）先中招，长的（1h）可能压根没赶上。
**不要立刻去修** —— Vault 回来后它自己会好（2026-08-29 实测约 10s 内全部回 Healthy）。
判据：`kubectl --context oracle-k3s get externalsecrets -A` 全部 `SecretSynced`，
且 `kubectl --context k3s-homelab -n vault exec vault-0 -- vault status` 显示 `Sealed false`。

集群侧（在**笔记本**上）：

```bash
kubectl --context k3s-homelab get nodes
kubectl --context k3s-homelab get pods -A --no-headers \
  | awk '$4!="Completed"{split($3,a,"/"); if(a[1]!=a[2]) print}'   # 应为空
```

升 `storage-106` 后还要确认媒体服务能读到数据（NFS 挂载是否恢复）：

```bash
kubectl --context k3s-homelab -n media exec deploy/jellyfin -- ls /media >/dev/null && echo NFS-OK
```

## 5. `storage-106` 的额外注意

- ☠️ **不要跑 `zpool upgrade`**。ZFS 2.3.3 → 2.4.x 只换用户态与模块，**池的 feature flags
  不会自动升**，旧内核照样能导入 —— 这正是 §6 回滚成立的前提。一旦 `zpool upgrade`，
  池就再也无法被旧版本导入，**回滚路径当场消失**，而本流程完全不需要它。
- 升级前确认根文件系统余量（实测 60G 可用，够）：`df -h /`。
- 106 **没有独立 `/boot` 分区**（与 `/` 同一个 `pve-root`），不必担心 `/boot` 撑满。

## 6. 回滚

**内核** —— 一次性回旧内核，不改默认引导项。前提是 `proxmox-kernel-6.14` 还在
（升级本身不会删它，但 `apt autoremove` 会，见 §4.4）：

```bash
# 先确认菜单项标题（两台都是普通 GRUB，子菜单叫 'Advanced options for Proxmox VE GNU/Linux'）
grep -E "^\s*menuentry '.*6\.14" /boot/grub/grub.cfg | head

grub-reboot "Advanced options for Proxmox VE GNU/Linux>Proxmox VE GNU/Linux, with Linux 6.14.8-2-pve"
reboot
```

确认旧内核可用后若要长期留在旧内核，改 `/etc/default/grub` 的 `GRUB_DEFAULT`
再 `update-grub`；两台当前都是 `GRUB_DEFAULT=0` / `GRUB_TIMEOUT=5`（有 5 秒可进菜单）。

**仓库**：删掉 §4.2 建的文件再 `apt-get update` 即回到升级前的源配置。

```bash
rm /etc/apt/sources.list.d/pve-no-subscription.sources && apt-get update
```

**软件包**：`apt` 层面没有干净的整体降级路径。若 PVE 9.2.x 本身出问题，
按 [`backup-recovery.md`](backup-recovery.md) 从 vzdump/restic 恢复受影响的 VM，
宿主本身按 [`homelab-rebuild-ubuntu-24-04.md`](homelab-rebuild-ubuntu-24-04.md) 的思路重建。
—— 这也是为什么 §3 要求两台**分开做**、中间留恢复时间。

## 7. 对照：两台 k8s 节点的内核（不走本文）

`k8s-node` / `k8s-worker-106` 是普通 Ubuntu 24.04，`unattended-upgrades` 已开，
**新内核自动装好**，`apt` 侧无事可做，只差重启：

```bash
# 有没有欠一次重启
cat /var/run/reboot-required

# worker：先腾空再重启
kubectl --context k3s-homelab drain k8s-worker-106 --ignore-daemonsets --delete-emptydir-data
# …重启…
kubectl --context k3s-homelab uncordon k8s-worker-106

# 控制面：双节点集群 drain 无处可去（且 vault PDB maxUnavailable=0），直接重启
```

⚠️ **`k8s-node` 重启会让 `protect-kernel-defaults` 真正生效**，届时
`/etc/sysctl.d/31-k8s-protect-kernel.conf` 里那四个值必须已落盘，否则 kubelet 拒绝启动。
判据与逐层状态见 [`security-hardening.md`](security-hardening.md) 与
[`reference/security.md`](../reference/security.md)。

## 8. 执行记录

| 日期 | 宿主 | 从 → 到 | 备注 |
|------|------|---------|------|
| 2026-08-29 | `pve` | 内核 6.14.8-2 → **7.0.14-14-pve** · PVE 9.0.3 → **9.2.11** · ZFS 2.3.3 → **2.4.4-pve1** | 顺利。120 升级 / 21 新装 / 1 移除。宿主重启 46s，homelab 总停机约 3 分钟（VM 先 `qm shutdown`，宿主起来后 `onboot:1` 自动拉起，集群 145s 内 69 pod 全绿）。踩到 `libzpool6linux` 孤儿（见 §4.3）与 oracle 侧瞬时 Degraded（见 §4.5），均已在文中固化 |
| — | `storage-106` | — | 未执行 |

> 执行后回填本表；若过程中出了状况，复盘写进 [`records/`](../records/README.md) 并链回这里。
