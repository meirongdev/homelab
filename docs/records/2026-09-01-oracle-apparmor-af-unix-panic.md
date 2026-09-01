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
> 结果: 两步。①`kernel.panic_on_oops=0` 止血（已入 ansible）；②kprobe 定位到触发方是
>       **uptime-kuma 容器内的 nscd**，关掉它后 libuv-worker 对该函数的调用归零。
>       另更正 2026-08-14 复盘与 `NodeRebootLoop` 告警描述里被证伪的排障指引。
>       **内核 bug 本身未修，上游无补丁**——我们只是让本集群不再走到那条路径。
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

**已做——根治触发方**（`cloud/oracle/manifests/uptime-kuma/provisioner.yaml`）：

用 ftrace kprobe 挂 `unix_fs_perm` 定位到了触发方（方法见下节）。链条是：
uptime-kuma **默认在容器内起 nscd** 做 DNS 缓存（`start()` 里
`if (enable || enable === null)`，设置缺失即默认开），nscd 持有绑定到文件系统路径的
AF_UNIX **服务端**套接字 `/var/run/nscd/socket`。libuv 的 DNS 线程每次 `getaddrinfo`
都要连它，而 AppArmor **对每次操作检查两次**——自己的套接字（无路径，安全）
和**对端的**（nscd 的，带路径）——所以 nscd 套接字拆除的竞态会在
**libuv-worker 的上下文里**踩空。这解释了为何受害者恒为 libuv-worker 而非 nscd。

修法是关掉 uptime-kuma 的 `nscd` 设置（它自带这个开关），**而不是给 pod 摘 AppArmor**：
`status.meirong.dev` 公网可达，`Unconfined` 会实打实削弱约束；关 nscd 只是让容器内
不再有带路径的 unix 套接字对端，代价仅是每次监控检查多一次 DNS 查询
（21 个 monitor / 60s，对 CoreDNS 可忽略）。

⚠️ `set_settings` 的坑：它把**全部**参数打包整体提交，没传的键会被库默认值覆盖。
本仓库的 `keepDataPeriodDays` 已定制，直接调用会被冲掉，故实现为 get→merge→set。

前后对比（kprobe 60 秒采样，同一函数的调用者分布）：

| 调用者 | 修复前 | 修复后 |
|---|---|---|
| `nscd` | 69 | **0** |
| `libuv-worker` | 69 | **0** |
| `postgres` | 36 | 36 |
| `pg_isready` | 12 | 12 |

⚠️ 剩下的 postgres/pg_isready 仍在访问带路径的套接字（`dentry != 0`），
**理论上仍暴露在同一个竞态下**。只是它们的套接字是长生命周期的（不像 nscd 的
客户端连接那样每次查询建/拆），拆除竞态窗口小得多，且 10 次崩溃无一发生在它们身上。
**这不是零风险，是把实际发生过的那条路径切断了。**

### 定位方法：ftrace kprobe（不需要装任何东西）

`unix_fs_perm` 没被内联，可以直接挂 kprobe。arm64 下第 5 个参数 `path` 在 `x4`，
`struct path` 的 `mnt` 在偏移 0、`dentry` 在偏移 8：

```bash
# 在 oracle 节点上，全程只读，不改内核行为
sudo bash -c '
cd /sys/kernel/tracing
echo "p:aa_unixfs unix_fs_perm mnt=+0(%x4):x64 dentry=+8(%x4):x64" > kprobe_events
echo "mnt == 0 && dentry != 0" > events/kprobes/aa_unixfs/filter   # 危险组合
echo 1 > events/kprobes/aa_unixfs/enable'
sudo cat /sys/kernel/tracing/trace          # 看 comm-pid
# 用完务必清理：
sudo bash -c 'cd /sys/kernel/tracing; echo 0 > events/kprobes/aa_unixfs/enable; echo > kprobe_events'
```

拿到 PID 后映射到 pod：`sudo grep -oE "pod[0-9a-f_-]{36}" /proc/<pid>/cgroup`。

☠️ **两个坑**：①别同时开着 `cat trace_pipe`——它是**破坏性读取**，会把事件从缓冲区
取走，导致 `cat trace` 恒为空，看起来像"探针没工作"；②`pkill -f "cat .../trace_pipe"`
会匹配到你自己这条命令的命令行而自杀（SSH 直接掉线，exit 255）。

**已做——更正被证伪的文本**：本条 + 2026-08-14 复盘的根因行与「客场证据已用尽」段 +
`prometheus-rules.yaml` 里 `NodeRebootLoop` 的排障指引（原文让人「查 OCI 维护事件」
后就止步，且断言「宿主层硬重置，客场查不出」）。

**已做——把自己弄哑的信号补回来**（`cloud/oracle/ansible/playbooks/setup-k3s.yaml`
\+ `k8s/helm/manifests/monitoring/alerts/prometheus-rules.yaml`）：

☠️ `panic_on_oops=0` 有个必须正视的副作用：**它把响亮的故障变哑了**。改之前
oops → panic → 重启 → `NodeRebooted`/`NodeRebootLoop` 必然告警；改之后机器活下来，
但那次 oops 不触发任何告警，只在 dmesg 里留一行。而残留暴露面是真实存在的
（postgres/pg_isready 仍在访问带路径的 unix 套接字，kprobe 实测 60s 内 36+12 次）。
只止血不补检测，等于把问题藏起来。

补法：`kernel-health-metrics.timer` 每 5 分钟经 node-exporter 的 textfile collector
（两集群早就开着，路径 `/var/lib/node_exporter/textfile`）导出四个指标，
配 `KernelOopsOccurred` 告警。

| 指标 | 含义 |
|---|---|
| `kernel_taint_die` | taint bit 7（D）= 内核自上次启动以来 oops/BUG 过 —— **主判据** |
| `kernel_taint_soft_lockup` | taint bit 14（L） |
| `kernel_taint_bits` | 原始位图 |
| `kernel_oops_recent` | 近 10 分钟 dmesg 里的 oops 条数，只作新鲜度参考 |

判据选 taint 位而不是数 dmesg：**taint 是内核自己置的、零成本、绝不漏**，且置位后
保持到重启——正好符合「这台机器死过一次，处理前别让告警自己消失」的语义。
告警按仓库规矩做了**两向实测**：`kernel_taint_die == 1` 现返回 0 条（无 oops，符合预期），
`== 0` 返回 1 条（证明指标在、比较运算能命中）——不是只验了一半就当它会响。

⚠️ **homelab 侧刻意不装**：那两个节点仍是发行版默认的 `panic_on_oops=1`，
oops 会照旧重启并触发 `NodeRebooted`，信号没丢。所以告警里**不能写 `absent()` 类判据**，
那会对 homelab 永久误报。

## 遗留（刻意不做）

- **内核 bug 本身没修，也修不了**。上游主线仍无 `path->mnt` 保护。我们只是让
  本集群不再走到那条路径；postgres 那条路径理论上仍暴露，现在至少**出事能被看见**
  （`KernelOopsOccurred`）。上游修掉之后，可以删掉 provisioner 里那段 nscd 豁免、
  把 `panic_on_oops` 改回默认、并撤掉这套导出器。
- ☠️ **homelab 的 `k8s-node` 同样暴露，未处理**。实测它跑 `7.0.0-30-generic`，
  `sudo grep -w unix_fs_perm /boot/System.map-$(uname -r)` **有命中**，
  且 24 个 AppArmor profile 在 enforce、`panic_on_oops=1`。
  只是它上面没有 nscd 那种「libuv 反复连带路径 unix 套接字」的负载，从没被踩到。
  **刻意维持现状**：它从没触发过，为一个未发生的风险偏离发行版默认不划算；
  而且 `panic_on_oops=1` 意味着真出事会重启 → `NodeRebooted` 必响，信号是有的
  （代价是控制面重启 = 全集群中断）。哪天要改，导出器和告警得一并搬过去。
- **上游报告已写好但未提交**（见上一节，正文可直接粘贴）。提交需要用你自己的
  Launchpad / 邮件列表账号，不是我能代劳的一步。
- **止血后的实际效果待观察**。改完当天还没等到下一次 oops，
  判据是：`NodeRebooted` 不再响，但 `journalctl -k | grep -i oops` 会开始留下记录
  ——**这次 oops 终于能落盘了**，因为机器不再立刻重启。

## 上游报告（待提交，正文可直接粘贴）

☠️ **本仓库只能治标**：关掉 nscd 是让本集群绕开，`path->mnt` 那个空指针在上游仍在。
提上游是唯一能让它真正消失的路径。两个去处二选一或都发：

- Ubuntu：`ubuntu-bug linux-oracle`（或 Launchpad 对 `linux-oracle` 开 bug），
  它会自动附上内核版本、`dmesg`、AppArmor 状态
- AppArmor 上游：`apparmor@lists.ubuntu.com`（`af_unix.c` 的一串同类修复都在这条邮件列表上讨论）

⚠️ 提交前把下面的 `<...>` 占位符补上；**别贴节点 IP / OCID / tailnet 地址**。

---

**Title**: apparmor: NULL pointer dereference in `unix_fs_perm()` — `path->mnt` not checked before `mnt_idmap()`

**Environment**
- Ubuntu 24.04.4 LTS (noble), arm64, QEMU/KVM guest
- Kernel: `6.17.0-1020-oracle` (also reproduced on `6.17.0-1019-oracle`)
- AppArmor: 127 profiles loaded, 29 in enforce mode
- Containers confined by the default `cri-containerd.apparmor.d` profile (k3s + containerd)

**Symptom**

Kernel panics every 1–4 days since ~2026-06-22. Ten captured occurrences have an
identical signature; the faulting instruction and address are the same every time.
The crash is invisible from inside the guest: `CONFIG_PANIC_ON_OOPS` is enabled, so
the box reboots ~10s later and journald never flushes the oops. All ten traces were
recovered from the hypervisor-side serial console buffer.

**Analysis**

The faulting address is `0x18` and the faulting instruction is
`f9400c00` = `ldr x0, [x0, #24]` with `x0 == 0`. In `struct vfsmount`,
offset 24 is `mnt_idmap` (`mnt_root`@0, `mnt_sb`@8, `mnt_flags`@16, `mnt_idmap`@24).

In `security/apparmor/af_unix.c`, `unix_fs_perm()` guards `path->dentry` but not
`path->mnt`, then dereferences the latter:

```c
if (path->dentry) {
        struct inode *inode = path->dentry->d_inode;
        vfsuid_t vfsuid = i_uid_into_vfsuid(mnt_idmap(path->mnt), inode);
```

So a `struct path` with `dentry != NULL` and `mnt == NULL` faults. The same code is
present unchanged in v6.17 and in current mainline.

**Trigger**

A confined Node.js process whose libuv threadpool calls `getaddrinfo()` against
nscd's filesystem-bound `AF_UNIX` socket (`/var/run/nscd/socket`). Both peers are
confined by the same profile. AppArmor mediates each operation twice — once for the
socket itself and once for its peer — so the peer check runs in the *client's*
context, which is why the victim task is always the libuv worker and never nscd.

A kprobe on `unix_fs_perm` confirmed the pairing: over a 60s window, `nscd` and
`libuv-worker` each hit the function exactly 69 times, and each libuv-worker
operation produced two consecutive events in the same microsecond. Disabling nscd
in that container dropped both to zero and the crashes stopped.

Reproducer sketch: a confined process repeatedly connecting to and reading from a
path-bound AF_UNIX socket owned by another confined process, while that socket is
torn down concurrently.

**Oops**

```
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000018
Mem abort info:
  ESR = 0x0000000096000006
  EC = 0x25: DABT (current EL), IL = 32 bits
  FSC = 0x06: level 2 translation fault
[0000000000000018] pgd=080000023a625403, p4d=080000023a625403, pud=080000023a626403, pmd=0000000000000000
Internal error: Oops: 0000000096000006 [#1]  SMP
CPU: 0 UID: 0 PID: 13352 Comm: libuv-worker Not tainted 6.17.0-1020-oracle #20-Ubuntu
Hardware name: QEMU KVM Virtual Machine, BIOS 1.6.6 08/22/2023
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
 __arm64_sys_read+0x28/0x50
 invoke_syscall+0x74/0x128
 el0_svc_common.constprop.0+0x114/0x140
 do_el0_svc+0x28/0x58
 el0_svc+0x40/0x160
 el0t_64_sync_handler+0xc0/0x108
 el0t_64_sync+0x1b8/0x1c0
Code: aa0203f7 f9401838 f9400080 f9401701 (f9400c00)
---[ end trace 0000000000000000 ]---
```

A `watchdog: BUG: soft lockup - CPU#1 stuck for 23s! [cilium-agent]` follows in every
trace; it is a consequence (the kernel is already `Tainted: G D`, CPU0 is gone and
CPU1 waits on an IPI that never arrives), not a second bug.

**Note**

This looks like the same family as the recent `af_unix.c` fixes on the AppArmor list
(`ctx->peer` NULL derefs, premature refcount put), but a distinct site: those crash in
`aa_label_is_subset` / refcount paths, this one in `unix_fs_perm` on `path->mnt`.

---

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
