# 运行时检测：两集群统一 Tetragon

> Last updated: 2026-11-25
> Status: 生效事实
> Scope: 纵深防御第 10 层（运行时检测）的部署、策略、告警、已知坑与验证方法。
> 2026-11-25 从 [security.md](security.md) §8.5 拆出；逐层状态总表仍在 security.md（R6）。

eBPF 运行时威胁检测（容器内起 shell、读敏感文件、提权、无文件执行、攻击工具）。**2026-11-24 起两集群统一用
Tetragon**，oracle 原来的 Falco + Falcosidekick 同日退役（取舍与 Falco 规则逐条去向见
[ADR](../decisions/runtime-detection-tetragon-both-clusters.md)，经过见
[records/2026-11-24](../records/2026-11-24-oracle-kernel-7-falco-to-tetragon.md)）。

## 部署与策略

- **部署**：两集群各一个 Helm App（homelab `tetragon`、oracle `tetragon-oracle`，ns `tetragon`，chart 版本由 V1 强制
  一致），都先引用两集群共用的 `security/tetragon/values-common.yaml`（导出过滤、argv 脱敏、优先级），再叠加各自的
  `values/tetragon.yaml`（agent 资源；homelab 另开 ServiceMonitor）。`security/tetragon/` 是 H2 登记的共用树
  （[manifest-safety-checks.md](manifest-safety-checks.md)）。内核态过滤只上报命中事件，省 CPU。
  默认进程 exec/exit → `export-stdout` → 各集群 OTel → oracle 上的 Loki（`{k8s_namespace_name="tetragon"}`，`cluster`
  标签区分）。指标：homelab 走 ServiceMonitor；oracle 由 OTel 抓 `tetragon:2112`，只留告警用的三个指标。
- **策略**（`security/tetragon/policies/`，两集群同一份，独立 App `tetragon-policies` / `tetragon-policies-oracle`，
  拆法同 kyverno-policies）：`container-escape-syscalls`（容器内 ptrace / process_vm_writev / 内核模块装卸 / kexec /
  open_by_handle_at）与 `sensitive-file-access`（`security_file_open` 上内核态匹配 /etc/shadow、sudoers、/root/.ssh 等
  凭据路径）。全部**只观察、不拦截**：仓库硬约束是安全组件 fail-open，拦截型策略误报即杀生产进程。

## 告警

- **告警分两路**。健康走 Prometheus（`alerts/tetragon-alerts.yaml`：`TetragonDown` / `TetragonPolicyLoadFailed` /
  `TetragonPolicyNotEnabled` / `TetragonEventsLost`，按 `(cluster, node)` 分组，`TetragonDown` 每集群一个 absent；
  promtool 用例在 `scripts/alert-rule-tests/tetragon-alerts.test.yaml`）。检测走 **Loki ruler**
  （`cloud/oracle/manifests/monitoring/loki-rules.yaml` 的 tetragon-runtime 组，不按集群过滤，warning）：
  - `TetragonRuntimePolicyHit`：上面两条策略的命中，`tp-` 前缀的策略视为临时测试不告警。夜备精确放行三条
    （restic 调 ssh 读自己的 `/root/.ssh/{id_ed25519,known_hosts,config}`、`backup.sh` 写 config、apk 的 `adduser` 改
    `/etc/shadow`）：策略 11-20 上线起每晚误报 ~130 次，11-24 才发现并补上。
  - `TetragonAppSpawnedShell`（11-22）：父进程是应用（node、python…）的 shell，webshell / 命令注入最典型的形态。
    父进程是 containerd-shim / runc 的（容器入口、exec 探针、`kubectl exec`）分不开，homelab 7 天 689 次 shell 里约 600 次
    是这类，**不报**，所以 `kubectl exec` 起的 shell 不在视野里。放行按「父进程参数 + 命令」精确写，不按 namespace：
    Prisma 的 `ldconfig -p`、supervisord；11-24 补 oracle 独有的 CNPG `manager wal-archive`、s6 的 `./run`、browserless
    读 `/proc/stat`、rsshub 的 npm 入口。
  - `TetragonFilelessExec`（11-24，移植自 Falco）：从 `/dev/shm`、memfd（`/proc/*/fd/N`）、`/tmp`、`/var/tmp` 执行或
    二进制已删除。`/dev/shm` 在容器里实测可执行。
  - `TetragonAttackToolExec`（11-24，移植自 Falco）：`nc`/`ncat`/`socat` 带 `-e`/`-c`/`EXEC:`；grep/find/rg 翻私钥标记、
    ssh key、云凭据、kubeconfig；shred/wipefs/mkfs/debugfs；truncate `/var/log`；`busybox nc -e` 直接调用一支（经软链
    调用时 Tetragon 报调用路径 `/bin/grep`，不是 busybox）。
  命中不用指标，因为 **Tetragon 会在 pod 删除后清掉该 pod 的指标序列**（实测），寿命短的 pod 里的命中可能在被评估前
  就没了，日志行不会。

## 已知坑

- ☠️ **集群独有负载只在那个集群的基线里**：oracle 上线头一小时，「应用起 shell」就被 homelab 没有的负载触发（见上）。
  oracle 的基线截至 11-24 只有数小时，日/小时级的合法 shell 还可能冒出来，照同样写法补精确放行并重放。
- ☠️ **换内核前把 eBPF 组件当成要过闸门的东西**：unattended-upgrades 装好新内核、下次重启即生效。Falco 就是这样在
  7.0 上被 BPF 校验器的内存顶破 limit 的。重启后核：`tetra tracingpolicy list` 两条 enabled、agent 的 `memory.peak`
  离 limit 有余量（两集群 limit 都是 512Mi，按**策略更新路径**的峰值定：oracle 308Mi、homelab 373Mi；稳态远低于此，
  测法见 `cloud/oracle/values/tetragon.yaml` 的注释）。
- ⚠️ **增删策略要同步改 `TetragonPolicyNotEnabled` 里的 `2`**，否则要么永远报警、要么少一条也不报。
- ☠️ **`matchBinaries NotIn` 在这里不生效**（Tetragon 1.7.0、内核 6.8/7.0，对照实验：排除 python3 的策略照样上报 python3）。别指望用它排噪声，要排就在告警表达式 / `exportDenyList` 里做，并且做完拿真事件验证。已知噪声：apps-pg 的就绪探针 `pg_isready -U postgres` 每次都打开 /etc/shadow；它不在 Loki 里（`exportDenyList` 已挡），但在 Prometheus 指标里。
- **`exportDenyList` 也会挡策略事件**：kube-system / cilium / 宿主（namespace 为空）的命中不会进 Loki，也就不会告警；宿主进程本来就被策略的 `matchNamespaces Pid NotIn host_ns` 排除（已用宿主 `sudo cat /etc/shadow` 实测不触发）。
- **CRD 会回填服务端默认值**（`return` / `maxData` / `resolve` / `returnCopy` / `followChildren`），App 永久 OutOfSync，已用 `ignoreDifferences` 忽略。新策略用到别的可选字段时可能再冒出新键：逐字段对比 git 与 live 再补，别写 `*`。
- ☠️ **跨文件挪 values 要拆两次提交**：多源 App 的 `$values` 跟 `main` 立即生效，valueFiles 列表要等 root App 同步；
  11-24 拆共用 values 时中间态把 tetragon-config 的 redaction-filters 写空了 6 分钟（agent 未重启，未生效）。

## 验证方法

- **验证要两个方向都测，而且别往群里发消息**：测试 pod 放 kube-system（`exportDenyList` 不导出 → 不进 Loki、不告警），
  在 agent 上 `tetra getevents --namespace kube-system --pods <pod>` 看策略命中；ptrace 用 `PTRACE_PEEKDATA` 打向不存在的
  pid，无副作用，再读一个普通文件当对照。只测 exec 类规则时测试 pod 才放导出的 ns，再用规则表达式直接查 Loki。
  ☠️ 别在导出的 ns 里 `grep -r … /etc`：会顺带打开 /etc/shadow（11-24 就这么误发过一条）。`tetra tracingpolicy list`
  显示 `enabled` 不等于探针真的在工作。

## argv 里的密钥

- ☠️ **进程事件带完整 argv，命令行里的密钥会进 Loki**（2026-11-24 起两集群都是）。密钥改用 env，或 curl 的 `--variable %VAR` + `--expand-*`（curl ≥ 8.3，命令行只剩 `{{VAR}}`）。exit 事件也带 argv，Tetragon 重启时还会给存量进程补发 exec 事件（`flags=procFS`），所以长期运行的进程同样会漏。
- `redactionFilters` 兜底 6 条（两集群共用）：bot token / `-u` 口令 / Bearer / URL 里的 `user:pass@` / `-token`、`--token` 的参数值 / `…Token:` 请求头的值。兜底不是正解：带空格且加引号的口令只能打掉一半。泄露经过与未轮换项见 [records/2026-10-24](../records/2026-10-24-intrusion-sweep-argv-secrets-in-loki.md)。
