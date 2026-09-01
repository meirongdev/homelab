# oracle 三个月的"宿主层硬重置"其实是内核 AppArmor 空指针——证据一直在 hypervisor 侧

> 日期: 2026-09-01
> 影响: oracle-k3s 自 2026-06-22 起**每 1–4 天硬重启一次**（累计 30+ 次，每次全集群
>       pod 中断 6~10 分钟）。此前 [2026-08-14 复盘](2026-08-14-oracle-reboot-loop-and-blind-dead-mans-switch.md)
>       判定为「宿主层硬重置、客场证据已用尽、根因修不了」，因此 **2.5 个月没有再查**。
> 根因: 内核 AppArmor 的 AF_UNIX 中介 bug —— `unix_fs_perm()` 在
>       `mnt_idmap(path->mnt)` 处**不检查 `path->mnt` 是否为空**就解引用。
>       而 `kernel.panic_on_oops` 是 Ubuntu oracle 内核的**编译期默认 1**，
>       oops 立刻升级成 panic → 10 秒后硬重启，journald 来不及落盘。
>       **不是宿主层的问题**：OCI 侧查证该实例有史以来只有 2 条维护事件，最后一条在 3 月。
> 结果: 设 `kernel.panic_on_oops=0` 止血（已入 ansible）；更正 2026-08-14 复盘与
>       `NodeRebootLoop` 告警描述里被证伪的排障指引。**根因未修，上游无补丁**。
> 触发: 排查一条无关的 Telegram 告警时，顺手发现 oracle 刚重启过。

## 一句话根因

**客场看不见证据，不等于证据不存在**——它在 hypervisor 的串口缓冲区里，
一条 `oci compute console-history` 就能拿到，而我们从没去拿过。

## 上一份复盘错在哪

2026-08-14 的推理链本身没有毛病，每一步都实测过：

```
last -x reboot                  → 无 shutdown 记录
journalctl -b -1 -n 25          → 末行是正常业务日志，戛然而止
journalctl -b -1 | grep panic   → 无
ls /var/crash/                  → 空
journalctl -b 0 | head          → 每次都从 EDK II 固件冷启动
```

从这五条推出「宿主层硬重置」是合理的。**错在把「客场查不到」等价于「根因在宿主层」。**

真实情况是：`panic_on_oops=1` 让内核在 oops 后**立刻**panic，
`kernel.panic=10` 十秒后重启——journald 根本没有机会把这几十行落盘。
所以「日志戛然而止 + 无 panic 记录」不是宿主层重置的证据，
**它恰恰是 guest 内核 panic 的典型形态**。两种情况在客场长得一模一样。

> **教训一**：`journalctl` 里没有 panic，只能证明 panic 没被写下来。
> 判断「有没有发生」和「有没有被记录」是两件事，而这台机器上后者恒为否。

## 取证：OCI 侧的两步

上一份复盘的结论行写着「根因要去 OCI 控制台查该实例的 Work Requests / 维护事件」。
这条指引方向对，但**只做了一半就停了**——真正有料的是 console history，不是维护事件。

本仓库 `cloud/oracle/terraform/terraform.tfvars` 里就有可用的 OCI API 凭据
（`user_ocid` / `fingerprint` / `private_key_path` / `tenancy_ocid` / `compartment_ocid`），
不必装 oci CLI，用 SDK 临时跑即可：

```bash
# 在 repo 根目录；uv 不会永久安装任何东西
uv run --with oci python - <<'PY'
import oci, re
tf = open("cloud/oracle/terraform/terraform.tfvars").read()
g = lambda k: re.search(rf'^\s*{k}\s*=\s*"([^"]+)"', tf, re.M).group(1)
cfg = {"user": g("user_ocid"), "fingerprint": g("fingerprint"),
       "key_file": g("private_key_path"), "tenancy": g("tenancy_ocid"),
       "region": g("region")}
compute = oci.core.ComputeClient(cfg)
inst = [i for i in compute.list_instances(compartment_id=g("compartment_ocid")).data
        if i.lifecycle_state != "TERMINATED"][0]

# ① 维护事件：证明 OCI 有没有动过这台机
for e in compute.list_instance_maintenance_events(
        compartment_id=g("compartment_ocid"), instance_id=inst.id).data:
    print(e.time_created, e.maintenance_category, e.instance_action, e.lifecycle_state)

# ② 串口控制台历史：panic 栈在这里
h = compute.capture_console_history(
    oci.core.models.CaptureConsoleHistoryDetails(instance_id=inst.id)).data
print("history id:", h.id)   # 轮询 get_console_history(h.id) 到 SUCCEEDED
PY
```

拿到后 `get_console_history_content(h.id, length=1024*1024)` 取回内容
（返回 bytes，记得 `.decode()`）。

### ① 维护事件洗清了 OCI

该实例 2021-11 创建至今**只有两条**：

| 时间 | 类别 / 动作 | 说明 |
|---|---|---|
| 2025-04-03 | MANDATORY EVACUATION / REBOOT_MIGRATION | 窗口 2025-04-19 ~ 05-03 |
| 2026-03-08 | MANDATORY FIRMWARE_UPDATE / STOP | 正好解释 2026-03-09 那次重启 |

Work Requests 为空。**最后一条维护事件在 3 月，而重启风暴 6 月 22 日才开始。**

### ② 控制台历史里有 10 次 panic

1MB 缓冲区覆盖 10 个 boot（6.17.0-1019 ×3 + -1020 ×7），签名 **10/10 完全一致**：

```
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000018
FSC = 0x06: level 2 translation fault
Internal error: Oops: 0000000096000006 [#1]  SMP
CPU: 0 UID: 0 PID: 13352 Comm: libuv-worker Not tainted 6.17.0-1020-oracle #20-Ubuntu
pc : unix_fs_perm+0xd0/0x130
lr : aa_unix_file_perm+0x510/0x690
x0 : 0000000000000000
Call trace:
 unix_fs_perm+0xd0/0x130 (P)
 aa_unix_file_perm+0x510/0x690
 aa_sock_file_perm+0xb4/0x150
 aa_file_perm+0x420/0x460
 common_file_perm+0x6c/0x1c8
 apparmor_file_permission+0x30/0x60
 security_file_permission+0x50/0xb0
 rw_verify_area+0x64/0x1e8
 vfs_read+0x9c/0x358
 ksys_read+0x114/0x138
Code: aa0203f7 f9401838 f9400080 f9401701 (f9400c00)
Kernel panic - not syncing: Oops: Fatal exception
```

崩溃进程**每次都是 `libuv-worker`**（Node.js 线程池线程）。

> ⚠️ 同一份日志里还有 `watchdog: BUG: soft lockup - CPU#1 stuck for 23s! [cilium-agent]`。
> 那是**后果不是原因**——内核已标 `Tainted: G D`（D=DIE），CPU0 死了之后
> CPU1 卡在 `smp_call_function_many_cond` 等一个永远不会来的 IPI。
> 别被它带偏去查 Cilium。

## 定位到具体那一行

故障地址 `0x18` 与故障指令 `f9400c00`（= `ldr x0, [x0, #24]`，x0 为 0）指向
`struct vfsmount` 的第 24 字节。上游 `security/apparmor/af_unix.c`：

```c
static int unix_fs_perm(const char *op, u32 mask, const struct cred *subj_cred,
                        struct aa_label *label, const struct path *path)
{
        if (unconfined(label) || !label_mediates(label, AA_CLASS_FILE))
                return 0;
        mask &= NET_FS_PERMS;
        if (path->dentry) {                     /* ← 只守了 dentry */
                struct inode *inode = path->dentry->d_inode;
                vfsuid_t vfsuid = i_uid_into_vfsuid(mnt_idmap(path->mnt), inode);
                                                /*  ↑ path->mnt 无保护 */
```

`struct vfsmount` 的布局：`mnt_root`(0) · `mnt_sb`(8) · `mnt_flags`(16) ·
**`mnt_idmap`(24 = 0x18)**。即 `path->mnt` 为 NULL 时，`mnt_idmap()` 读它的
第 24 字节——**与实测故障地址逐位吻合**。

触发条件：一个 `path.dentry` 非空、但 `path.mnt` 为空的 AF_UNIX 套接字，
被一个**受 AppArmor 约束的**进程 `read()`。容器全部跑在 containerd 默认的
`cri-containerd.apparmor.d`（enforce）下，所以条件常备。

## 为什么换内核逃不掉

AF_UNIX 中介是 Linux 6.17 里 AppArmor 的头号新特性（把 Ubuntu 多年自带的
SAUCE 补丁上游化），随之引出一串 `af_unix.c` 的空指针/引用计数 bug。
但**这个变体至今未修**，且四条 oracle 内核轨道全都带这段代码：

| 想法 | 实测结论 |
|---|---|
| 升到更新的内核 | `linux-image-oracle-7.0` 有（7.0.0-1006），但 **v6.17 与上游主线的那一行完全相同**，补丁没进上游 → 白升 |
| 退回 6.17.0-1007（曾稳 105 天） | ①`/boot` 里只有 -1019/-1020，旧内核镜像早被清（dpkg 记录还在但文件没了），archive 里 6.17 轨道也只剩 -1020，装不回去；②同属 6.17 代码线 |
| 退回 LTS GA 的 6.8 | ❌ **这个想法是错的**。实测比对 kallsyms：`6.8.0-1060` 与 `6.17.0-1020` **都有** `unix_fs_perm` / `aa_unix_file_perm` / `aa_sock_file_perm`。Ubuntu 的 6.8 同样带中介 |

验证 kallsyms 的办法（`linux-image` 包里没有 System.map，得从压缩镜像里捞）：

```bash
# 在 oracle 节点上；只下载不安装
cd /tmp && apt-get download linux-image-6.8.0-1060-oracle
dpkg-deb -x linux-image-*.deb x && zcat x/boot/vmlinuz-* > img
for s in unix_fs_perm aa_unix_file_perm aa_sock_file_perm; do
  printf '%s: %s\n' "$s" "$(strings -a img | grep -cx "$s")"
done
```

> ⚠️ 别用「grep 源文件路径串」当判据：`security/apparmor/af_unix.c` 在
> 6.8 和 6.17 的镜像里**都搜不到**，而 6.17 明明有这段代码（System.map 为证）。
> 那个判据无效，只有直接搜符号名才可靠。

## 为什么 6 月 22 日才开始

时间线只能到「相关」，**证不到因果**，如实记录：

| 内核 | 装机日期 | 首次引导 | 之后表现 |
|---|---|---|---|
| 6.8.0-1025 | — | 2025-05-10 | 连续 **286 天** |
| 6.17.0-1007 | 2026-02-21 | 2026-03-09 | 连续 **105 天** |
| 6.17.0-1016 | **2026-06-04** | **2026-06-22**（晚 18 天）| 18 小时后首崩 |
| 6.17.0-1018 | 2026-06-28 | 2026-07-01 | 每 1–4 天 |
| 6.17.0-1019 | 2026-07-28 | 2026-07-31 | 每 1–4 天 |
| 6.17.0-1020 | 2026-08-20 | 2026-08-22 | 每 1–4 天 |

☠️ **-1016 装完隔了 18 天才被引导**，而后三个都是装完 2–3 天就引导
（符合「崩溃后 GRUB 自动进最新内核」）。这说明 6/4–6/22 机器没崩、一直安稳跑在
-1007 上，那么 **6/22 那次重启很可能就是发生在 -1007 上的第一次崩溃**——
即 -1007 也有 bug，105 天只是触发条件尚未出现。

想求证 6 月的情况，两个数据源都够不着：Prometheus 只留 **14 天**，
Uptime Kuma 的库因 2026-08-05 升级 2.5.0 重建过、最早只到 08-05。**故此点存疑，未证实。**

同期（06-17/06-18）有两个安全加固提交（PSA/Kyverno/Trivy、Falco 入 oracle），
时间上也接近，同样无法排除。

## 处置

**已做——止血**（`cloud/oracle/ansible/playbooks/setup-k3s.yaml`）：

```yaml
- name: Survive the AppArmor af_unix oops instead of hard-rebooting
  ansible.posix.sysctl:
    name: kernel.panic_on_oops
    value: '0'
    sysctl_file: /etc/sysctl.d/99-panic-on-oops.conf
```

oops 照旧发生，但只杀掉肇事线程、机器不再重启——把「每 1–4 天全集群断 6–10 分钟」
降成「死一个 Node 线程」。因为 oops 发生在 `read()` 系统调用的**进程上下文**
（不是中断上下文），杀掉任务后系统可以继续跑。

⚠️ 代价，别当成通用调优抄去别处：内核被标记污染、每次泄漏少量 AppArmor label
引用计数（1–4 天一次，可忽略），且这是**刻意偏离发行版编译期默认**。

**已做——更正被证伪的文本**：本条 + 2026-08-14 复盘的根因行与「客场证据已用尽」段 +
`prometheus-rules.yaml` 里 `NodeRebootLoop` 的排障指引（原文让人「查 OCI 维护事件」
后就止步，且断言「宿主层硬重置，客场查不出」）。

## 遗留（刻意不做）

- **根因没修，也修不了**。上游主线仍无 `path->mnt` 保护。真正的解要么等上游，
  要么给触发方 pod 设 AppArmor `Unconfined`（`unix_fs_perm` 开头就是
  `if (unconfined(label)) return 0`）——但**尚未定位到是哪个 pod**：
  崩溃进程名 `libuv-worker` 是 libuv 线程池的通名，oracle 上的 Node.js 候选有
  rsshub / rsshub-browserless / excalidraw-room / homepage / uptime-kuma / zitadel-login。
- **没提上游**。手上有 10 次一致签名 + 精确的偏移分析，是一份质量不错的 bug 报告素材。
- **止血后的实际效果待观察**。改完当天还没等到下一次 oops，
  判据是：`NodeRebooted` 不再响，但 `journalctl -k | grep -i oops` 会开始留下记录
  ——**这次 oops 终于能落盘了**，因为机器不再立刻重启。

## 教训

- **「查不到」和「不存在」是两回事**。上一份复盘把五条客场阴性结果推成了
  「根因在宿主层」，而那五条阴性恰恰是 guest panic 的标准形态。
  阴性证据要先问一句：**这个观测手段在故障发生时还活着吗？**
  panic 之后 journald 已经死了，它的沉默不构成证据。
- **结论行里写「客场证据已用尽」会终止后续排查**。那句话让这台机器又崩了 2.5 个月。
  写「已用尽」之前先确认**场外**的手段是不是也试过了——这次场外只差一条 API 调用。
- **上一份复盘自己给出了正确方向却没走完**：「去 OCI 查」是对的，
  但只查了维护事件（阴性）就停了，而真正的证据在同一个 API 的另一个方法里。
  阴性结果不该是终点，该是换方法的信号。
- **相关性不等于因果**。「6.17.0-1016 引入了 bug」这个说法很顺，
  但装机日期一摆出来就站不住了。差点据此推荐一个没用的内核回退。
