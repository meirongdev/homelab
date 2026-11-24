# oracle 换 7.0 内核：Falco 加载 BPF 被 OOM，顺势统一到 Tetragon

> 日期: 2026-11-24（UTC；重启 14:25Z，Tetragon 上线约 16:00Z）
> 影响: oracle 运行时检测中断约 70 分钟（Falco CrashLoop 14:30Z → 0.45.2 就绪 15:37Z），期间 Tetragon 未上线。
>       homelab 的 tetragon-config ConfigMap 有约 6 分钟（16:02–16:08Z）缺 redaction-filters 与大半 denylist，
>       agent 未重启、从未生效，无泄露。Loki ruler 误触发 warning 4 条（1 条是自测、3 条是 oracle 独有负载；
>       按路由经 Alertmanager 推 Telegram，是否实际送达未核）。
> 根因: ① 7.0 内核加载 BPF 时校验器的 slab 记在 Falco 容器 memcg 上，峰值 520Mi 顶破 512Mi；② 多源 App 的
>       `$values` 跟 main 立即生效、valueFiles 列表要等 root App 同步，两者之间渲染出半截配置；
>       ③ 「应用起 shell」的 7 天零误报基线只在 homelab 上测过。
> 相关: [ADR：统一用 Tetragon](../decisions/runtime-detection-tetragon-both-clusters.md) ·
>       [AppArmor 崩溃的原始复盘（已有上游修复）](2026-09-01-oracle-apparmor-af-unix-panic.md) ·
>       [k3s 1.36 升级（panic_on_oops 守卫的由来）](2026-11-20-k3s-1-36-upgrade.md)

## 1 为什么换内核

unattended-upgrades 早已装好 `7.0.0-1016-oracle`，GRUB 默认最新，所以**下一次任何重启都会自动换内核**——
与其等一次意外重启时没人盯，不如计划内换。它带着 09-01 那个崩溃的上游修复：
`apparmor: fix race in unix socket mediation when peer_path is used`（b1aea2c19607，CVE-2026-72462）——对端
套接字的 path 在 state lock 外读取，和 `unix_release_sock()` 竞态，与当时 nscd 套接字拆除、kprobe 抓到的
`mnt==0 && dentry!=0` 吻合（按描述匹配，没读 diff）。⚠️ 它自带的后遗症修复 1cdda838e847（sleep-in-atomic）不在
7.0.0-1016 里；重启后 dmesg 无告警、taint 0。

重启前先上了 panic_on_oops 守卫（11-20 记录 §2），这次重启顺带回答了那边悬着的问题：守望日志
`REASSERT … (k3s ready +2s)`——**kubelet 在 k3s 报 READY 之后才写回 1**，当初若只在 `ExecStartPost` 里改一次就会被盖回去。

## 2 Falco：不是 Falco 漏内存，是校验器的内存记在它头上

重启后 Falco 0.44.1 每次都在 `Opening 'syscall' source with modern BPF probe` 之后无声退出，exit 137 OOMKilled。
dmesg 的 memcg 统计才说清楚：usage 512Mi = limit，**anon 只有 32MB，kernel 503MB，其中 slab 467MB**，栈在 `__sys_bpf`。
6.17 上同一配置一直没事。

没靠 GitOps 一轮轮试：用 ArgoCD 不跟踪的一次性 pod（0.45.2、3Gi 上限、去掉 DaemonSet 的选择器标签免得被收编）
在节点上实测——**加载那十几秒 memory.peak 520Mi，稳态 131Mi**，只超原上限 2%。于是 limit 512Mi→1Gi，chart
9.1.0→9.2.2（0.44.x 在 7.0 这类可抢占内核上另有 auxmap 解析崩溃，falco#3955，0.45.0 修）。上线实测峰值 522Mi。

> **教训**：判断内存 limit 够不够看 `memory.peak` / dmesg 的 memcg 统计，不看稳态 working set；eBPF 组件的
> 「加载峰值」随内核漂移，升内核前要把它们当成和 Cilium 一样需要过闸门的东西。

## 3 统一到 Tetragon 时的两个坑

**半截渲染**：把 homelab 的 tetragon values 拆成 `security/tetragon/values-common.yaml` + 集群文件，同一提交里改了
Application 的 valueFiles。本地 `helm template` 叠加两文件与改前逐字节一致，推上去仍出事：`$values` ref 源跟
`main`，tetragon App 立刻读到**新的、已被掏空的** homelab values，而新增的 valueFiles 要等 root App 下一轮同步。
中间态 operator 掉了 priorityClass，**tetragon-config 的 redaction-filters 被写空**。DaemonSet 更新被 Kyverno
`require-requests-limits` 拦下（export-stdout 没了 resources），agent 没重启；Tetragon 不热加载这个 ConfigMap
（期间 Loki 无 runc init 事件洪峰为证），旧过滤一直在内存里——侥幸。失败的同步钉着旧 spec 重试满 5 次后，
按新 spec 自动恢复。
跨文件挪 values 要拆两次提交：先让 App 引用新文件（内容重复、渲染不变），等 Synced 后再删旧文件里的重复部分。

**基线只覆盖一个集群**：Loki 里的两条 Tetragon 规则本来就不按集群过滤，oracle 的事件一进来就生效。
「应用起 shell」头一小时就被 CNPG 的 archive_command（`manager wal-archive`）、browserless 读 `/proc/stat`、s6 的
`./run`、rsshub 的 npm 入口触发——homelab 没有这些负载。已按「父进程 + 命令」精确放行，放行后 7 天窗口仍命中
11-20 的正向对照。另有 1 条是自测误发：在导出的 ns 里 `grep -r … /etc` 顺带打开了 /etc/shadow。不发消息的测法写进了
loki-rules 的注释（测试 pod 放 kube-system，用 `tetra getevents` 看）。

**顺带发现的旧误报**：给看板换查询时数到 24 小时 128 次策略命中——`sensitive-file-access` 11-20 上线起，homelab
两个夜备 Job 每晚都触发（restic 调 ssh 读 `/root/.ssh/`、`backup.sh` 写 config、apk 的 `adduser` 改 `/etc/shadow`），
统一后 oracle 的夜备（同一个脚本）也会触发。按「ns + 程序 + 父进程/参数 + 路径」放行，7 天回放只剩测试 pod。
上线时只回放了「应用起 shell」，没回放「策略命中」——新规则要对**所有**相关规则回放，不只对新写的那条。

## 4 验证做了什么

- 策略：kube-system 测试 pod 里 `cat /etc/shadow`、ptrace 命中，`cat /etc/hostname` 不中（arm64 + 7.0）。
- 新检测：default 测试 pod 里 /tmp、/dev/shm、memfd 执行 3/3 命中；`nc -e`、`busybox nc -e`、grep 私钥标记、
  find id_rsa、shred 5/5 命中；`nc -h`、`grep localhost`、`find hosts` 不中；两集群全部可用历史回放 0 命中。
- 健康告警：promtool 11 组 + 12 处变异全杀；现网真实表达式为空、放宽后三个节点全中。
- 资源：oracle 的 Tetragon 首次加载 memory.peak 185Mi（limit 先给 768Mi，策略更新路径峰值待测）。
