# 运行时检测两集群统一用 Tetragon，退役 oracle 的 Falco

> 日期: 2026-11-24
> 状态: ✅ 已实施（oracle 的 Tetragon 与告警 11-24 上线并做过两向实测，Falco 同日删除）
> 关联：[reference/tetragon-runtime-detection.md](../reference/tetragon-runtime-detection.md) ·
> [records/2026-11-24-oracle-kernel-7-falco-to-tetragon](../records/2026-11-24-oracle-kernel-7-falco-to-tetragon.md) ·
> [reference/manifest-safety-checks.md（H2 共用树）](../reference/manifest-safety-checks.md)

## Context

- 2026-06 起运行时检测「按集群硬件分别选型」：homelab（5600H 热笔记本）用 Tetragon，内核态过滤省 CPU；
  oracle 用 Falco + Falcosidekick，理由是规则库开箱即用、**oracle CPU 有余量**。
- 2026-08-05 oracle 缩到 2 OCPU / 12G，「CPU 有余量」不再成立（`values/falco.yaml` 的注释自己写了），
  但两套组件留了下来。
- 两套并存的长期代价，11-24 一天里全部兑现：
  1. **两份内核兼容风险**。oracle 换 7.0 内核，Cilium 有升级闸门（[k3s-1-37 等 Cilium 1.21](../runbooks/k3s-cluster-upgrade.md)
     那条线），Falco 没有，0.44.1 直接 CrashLoop（加载 BPF 时 memcg OOM，见 record）。
  2. **检测覆盖随服务落在哪个集群而变**。服务会在两集群间搬（[落点决策](cluster-placement-for-new-services.md)），
     同一个攻击在 homelab 被 Tetragon 看、在 oracle 被 Falco 看，覆盖面与写法都不一样。
  3. **一切双份**：规则格式（Falco YAML / TracingPolicy CRD）、告警通路（falcosidekick / Loki ruler）、
     健康告警、踩坑记录。
- Falco 在 oracle 上的实际产出（Loki 7 天，11-17 起）：5042 条 Notice「Contact K8S API Server」（operator 正常访问）、
  865 条 Critical「Drop and execute new binary」——**全部**是夜备 Job 运行时 apk 现装的 find/restic/ssh/pg_dump，
  每天恰好 173 条、天天一样；5 条「Create Hardlink Over Sensitive Files」也是同一个 Job 的 `adduser`。
  **7 天零真告警**，Critical 还推 Telegram。

## Decision

两集群统一用 Tetragon，Falco 退役。用户 11-24 明确选择「只看长期可维护性、直接统一」，跳过并行观察期，
但不跳过验证：先在 oracle 部署 Tetragon 并两向实测，再撤 Falco。

- **结构**：策略与「两边必须一样」的 values 放 `security/tetragon/`（`check-manifests.py` 的 `SHARED_TREES`），
  两集群各一个 Helm App + 一个策略 App，引用同一目录；集群差异（资源、ServiceMonitor）放各自 values 树。
  chart 版本由 V1 强制一致。
- **不选「统一到 Falco」**：homelab 控制面是热笔记本，Falco 在用户态逐 syscall 过滤，CPU 开销与 CLAUDE.md 的
  热约束冲突——这一条与钱无关。且 Falco 的内核兼容不跟 Cilium 的升级闸门走。
- **Falco 规则的去向**（stable 规则集 25 条）：

| 处理 | Falco 规则 | Tetragon 侧 |
|---|---|---|
| 已覆盖 | PTRACE attached / anti-debug、Linux Kernel Module Injection | `container-escape-syscalls` 策略 |
| 已覆盖 | Read sensitive file trusted / untrusted、Find AWS Credentials（读文件那半） | `sensitive-file-access` 策略 |
| 已覆盖 | Terminal shell in container、Run shell untrusted（`kubectl exec` 有意不报） | Loki ruler `TetragonAppSpawnedShell` |
| 11-24 移植 | Execution from /dev/shm、Fileless execution via memfd_create；近似 Drop and execute new binary（写进 /tmp 再执行） | `TetragonFilelessExec` |
| 11-24 移植 | Netcat RCE、Search Private Keys or Passwords、Find AWS Credentials（搜索那半）、Remove Bulk Data、Debugfs、Clear Log Activities（截断 /var/log 那半） | `TetragonAttackToolExec` |
| 不移植 | Contact K8S API Server From Container | Notice 级，oracle 7 天 5042 条，基本是 operator，报了只会被忽略 |
| 不移植 | Drop and execute new binary（精确版：判断是否在镜像上层） | Tetragon 拿不到这个信息；oracle 上 100% 是夜备误报 |
| 不移植 | Create Symlink / Hardlink Over Sensitive Files | oracle 7 天 5 条全是夜备 `adduser`；要做得新加 kprobe |
| 不移植 | Detect release_agent File Container Escapes | 两集群都是 cgroup v2，要先在特权容器里挂 cgroup v1；有特权的人有更直接的路（模块装卸已覆盖） |
| 不移植 | Packet socket created、Redirect STDOUT/STDIN to Network、Disallowed SSH non-standard port、Directory traversal、System user interactive | 要网络基线或新 kprobe；反弹 shell 的常见形态已由「应用起 shell」+ `nc -e` 兜住；目录穿越内核看到的是解析后的路径 |

## Consequences

- **好处**：一份策略、一套告警、一个内核兼容闸门（跟 Cilium）；检测覆盖不再随服务落点变化；
  oracle 的 argv 也进 Loki，入侵排查两集群同一套查法。
- **代价，要正视**：
  - **检测规则从此自己维护**。Falco 有社区维护的规则库，Tetragon 只给探针；新攻击手法要自己写、自己调、
    自己两向实测。上表「不移植」那几行是有意接受的缺口。
  - **运行时告警不再有独立推送通路**。Falcosidekick 曾绕过 Alertmanager 直推 Telegram；现在两集群都走
    Loki ruler → Alertmanager。Alertmanager 挂掉时由死人开关兜底（[dead-mans-switch.md](../reference/dead-mans-switch.md)）。
  - **oracle 的 argv 进 Loki**，命令行里的密钥风险扩到 oracle（redactionFilters 两集群共用，规则同 homelab）。
  - **集群独有负载只在那个集群的基线里**：oracle 上线头一小时，「应用起 shell」就被 CNPG WAL 归档、
    browserless、s6 等 homelab 没有的负载触发，已精确放行；oracle 的基线截至 11-24 只有数小时。
- **复查触发**：上游出现 Tetragon 不支持的内核（unattended-upgrades 装好、重启即生效）；或某条未移植的 Falco
  规则对应的攻击在别处出现过。
