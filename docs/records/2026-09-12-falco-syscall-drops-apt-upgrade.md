# Falco 一分钟丢掉 402,586 个 syscall：不是 CPU 被卡住，是 8MB 缓冲区接不住 apt 升级

> 日期: 2026-09-12（告警 07:03 → 07:18 +08，已自动 resolved）
> 影响: **无服务影响**。oracle-k3s 上 Falco 出现约一分钟的**检测盲区** —— 该窗口内的
>       syscall 不会被任何规则评估。一条 warning 投递 Telegram。无重启、无崩溃、
>       无规则加载失败，Falco 自身全程健康
> 根因: 06:48:53–06:49:57 `unattended-upgrades` 升级 **glibc(libc6) + locales + python3.12**
>       —— 连带重启 fail2ban/firewalld/systemd-binfmt、`locale-gen` 重生成全部 locale、
>       `py3compile` 重编译 stdlib 字节码。fork 率 **1.5/s → 21.2/s**，system CPU 翻倍，
>       瞬间灌满 scap 环形缓冲区。默认 `buf_size_preset: 4` = **8MB**，而
>       `cpus_for_each_buffer: 2` 在这台 2 OCPU 机器上意味着**全机只有这一个 8MB**
> 结论: ☠️ **不是 Falco 被 CPU limit 卡住**（告警描述原先这么引导，已改）：全程实测
>       **0.024 / 1 核**、零 throttle。缓冲区容量问题，与 Falco 自身负载无关
> 处置: 2026-09-12 `bufSizePreset: 4 → 6`（8MB → 32MB，`cloud/oracle/values/falco.yaml`），
>       并重写 `FalcoKernelEventDrops` 的排查指引。告警阈值**刻意仍保持 `> 0`**
> 触发: 宿主 `apt-daily-upgrade.timer`，随机延迟落在 06:48

全文时刻均为 **+08**（oracle 节点时区 Asia/Singapore，与 Prometheus 渲染一致）。

## 一、计数器长什么样

`falcosecurity_scap_n_drops_total{cluster="oracle-k3s"}` 在 12 天里**恒为 0**，
07:00 单步跳到 402,586，此后再次恒定：

```
08-31 10:00        0
09-12 07:00   402586     ← 一次突发，之后不再增长
```

序列连续、无 gap、无 reset，所以**不是采集伪影**。Falco 进程自 09-01 13:06 起未重启
（`falco_duration_seconds_total` = 939,208s ≈ 10.87 天），计数器是同一条命的累计值。

⚠️ **别被 Loki 里的启动 banner 骗了**：`falco-6xgd8` 在 09-10 21:25 又完整打了一遍
version / plugins / rules / buffer dimension，看着像重启过。那是 falcoctl 拉到新规则后的
**热重载** —— 进程没重启（duration 计数器连续、pod `RESTARTS` 未动），scap 计数器也没归零。
判据用 `falco_duration_seconds_total`，不是日志里有没有 banner。

占比：402,586 / `n_evts_total` 2,067,162,917 = **0.019%**。

⚠️ **别拿分类明细去核对总数**，两者差三个数量级：

```
n_drops_total                    402586
n_drops_buffer_total  exit/open     376   ← 明细只统计「感兴趣」的那几类
                      exit/close    296
                      exit/clone_fork 3
                      exit/connect    2
n_drops_scratch_map_total             0
n_drops_full_threadtable_total        0
```

明细里 **open + close 占 99%** —— 文件系统遍历型风暴的签名（mandb / locale-gen /
py3compile 都是这个形状），这条线索比总数更有用。

## 二、为什么排除了「Falco 被 CPU limit 卡住」

告警描述原先把人往这个方向引。实测三条都不支持：

| 判据 | 实测 | 结论 |
|------|------|------|
| Falco 容器 CPU | 0.024 核（突发时 0.032），limit `1` | 用到 2.4%，谈不上卡 |
| throttle 指标 | oracle 侧无 `container_cpu_cfs_throttled` 序列 | 无从谈起，且用量离 limit 差 30 倍 |
| 节点 CPU 归属 | 节点 0.92 核，容器总和仅 **0.26 核** | **0.66 核在容器外** —— 宿主进程 |

「容器外烧掉 2/3 的 CPU」这一条直接把排查从 K8s 推到宿主层。

## 三、宿主层证据

节点 CPU 分解（06:45 → 06:50）：

```
user     0.322 → 0.454      system   0.122 → 0.250   （翻倍）
nice     0.000 → 0.036      iowait   0.003 → 0.018
forks/s    1.5 → 21.2       ctxsw/s  16805 → 17576   （几乎没动）
```

**fork 暴涨 14 倍而上下文切换几乎不变** = 在疯狂 spawn 新进程，不是线程抖动；
`nice` 从 0 冒头 = 有 niced 的维护任务在跑。三个 timer 恰好命中：

```
apt-daily-upgrade.service   LAST 2026-09-12 06:48:53
man-db.service              LAST 2026-09-12 06:49:32
motd-news.service           LAST 2026-09-12 06:49:32
```

`/var/log/apt/history.log` 给出确切内容 —— 四笔 `unattended-upgrade`，06:49:04–06:49:57：

| 包 | 版本 | 连带代价 |
|----|------|---------|
| `python3.12` + `libpython3.12{-minimal,t64,-stdlib,-dev}` 等 7 个 | 3.12.3-1ubuntu0.15 → 0.17 | `py3compile` 重编译整个 stdlib 字节码 |
| `libc6` `locales` `libc-bin` `libc-dev-bin` `libc6-dev` | 2.39-0ubuntu8.8 → 8.9 | **glibc 换代 → 重启全部服务**；`locale-gen` 重生成 |
| `wireless-regdb` | 2026.02 → 2026.05 | 无 |

journal 佐证连锁重启：`systemd-binfmt` 停→启、`packagekit` 拉起、`fail2ban` 停、
`firewalld` 停。

## 四、为什么 09-05 那次没丢

同一个 timer，**上一次升级零丢弃** —— 差别只在包的体量：

```
09-05 06:29   gnupg 全家 · linux-tools-common/linux-libc-dev · openssh      → 0 drops
09-12 06:49   glibc + locales + python3.12                                  → 402,586 drops
```

所以这不是「每天都在丢、只是今天才够阈值」，而是**只有触及 glibc/locales/python 这类
牵动全系统的包时才会打穿**。频率上大致对应 Ubuntu 推这类更新的节奏，不是每日事件。

## 五、处置

`cloud/oracle/values/falco.yaml`：

```yaml
driver:
  kind: modern_ebpf
  modernEbpf:
    bufSizePreset: 6        # 4(8MB) → 6(32MB)
```

- 代价：锁定内核内存 **+24MB**（不计入容器 512Mi limit）；节点 12GB 现用 7.3GB。
- 部署：falco 是 GitOps App（`argocd/applications/falco.yaml`，automated+selfHeal），
  **push 即可**；chart 在 pod 模板上有 `checksum/config` 注解，配置一变 DaemonSet 自动滚动。
- ✅ **验收判据**（唯一正向证据，别拿「告警没响」代替）：

  ```bash
  kubectl --context oracle-k3s logs -n falco -l app.kubernetes.io/name=falco -c falco \
    | grep 'syscall buffer dimension' | tail -1
  # 期望：The chosen syscall buffer dimension is: 33554432 bytes (32 MBs)
  ```

  ⚠️ `tail -1` 不能省：热重载会把这行重打一遍，不加就可能读到同一个 pod 里的历史值。

告警侧：`FalcoKernelEventDrops` 的 description 重写，把第一顺位从「查 CPU limit」改成
「查宿主 `apt-daily-upgrade` 与 `/var/log/apt/history.log`」，并写明 open/close 占多数
意味着文件系统遍历型风暴。

## 六、刻意没做的事

- **没有抬高告警阈值。**`> 0` 是这条规则的设计前提（丢弃 = 盲区，不是性能损耗）。
  把阈值抬到「盖住正常的 apt 升级」等于让健康信号说谎 —— 同
  [2026-08-30 页缓存误报](2026-08-30-memory-alert-page-cache-false-alarm.md) 相反的方向：
  那次是指标测错了东西，这次指标测得对，是缓冲区不够。
- **没有关掉 `man-db.timer` / `motd-news.timer`。**它们确实是无头服务器上的纯浪费，
  但本次的主要贡献是 py3compile 与 locale-gen，关掉这两个 timer 收益有限，
  却让节点偏离发行版默认（下次装机/重建要记得复现）。想省这点 CPU 属于另一件事。
- ⚠️ **32MB 是降低概率，不是消灭。**足够大的突发照样能灌满。若再响，正确动作是继续
  加档（preset 7 = 64MB）或 `cpusForEachBuffer: 1`（每 CPU 独立缓冲），
  **不是抬阈值**。

## 七、为什么值得管

丢弃窗口里发生的一切对 Falco 不存在。本次窗口恰好覆盖的是一次**宿主特权操作**
（glibc 替换 + 服务全体重启）—— 良性，但形状与「攻击者先制造 syscall 风暴再动手」
完全一致。制造噪声淹没审计是已知的 Falco 规避手法，所以这条告警值 warning，
缓冲区也值那 24MB。
