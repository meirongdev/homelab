# macOS「本地网络」授权把 LAN 伪装成 `no route to host` —— 一年悬案定性

> 日期: 2026-08-13
> 影响: 这台 Mac（工作机）上**所有非 Apple 签名的二进制**（terraform / kubectl /
>       Homebrew python 等）访问 `192.168.50.0/24` 一律 `connect: no route to host`，
>       而 `ping`/`curl`/`ssh`/`nc` 全部正常。表现为"terraform 管不了 Proxmox"，
>       ROADMAP 已知问题里挂着"100% 复现、已排除 Tailscale、原因不明"。
> 根因: **macOS 的本地网络隐私（Local Network / TCC）**。未获授权的进程访问本地链路
>       地址时，内核返回 `EHOSTUNREACH`——与真正的路由不可达**完全同形**。
>       Apple 自带 `/usr/bin/*` 免疫，Homebrew 装的一律受限；Tailscale(utun) 与
>       loopback 不算"本地网络"，所以从来没出过问题。
> 结果: 悬案关闭。绕法（Tailscale 地址 / SSH 隧道）已固化进 IaC；根治是一次 GUI 授权。
> 触发: 建 storage-106 实验田时，terraform 的磁盘导入 SSH 与 kubectl 连实验集群双双失败。

## 判别实验（2×2，决定性）

同一时刻、同一台 Mac、同一目标端口：

| 二进制 | LAN `192.168.50.107:6443` | Tailscale `100.94.186.7:6443` |
|---|---|---|
| `/usr/bin/curl`（Apple 签名） | ✅ HTTP 401（连通，仅缺证书） | ✅ |
| Homebrew `python3`（非 Apple） | ❌ `[Errno 65] No route to host` | ✅ 连上 |
| `kubectl`（Homebrew，Go） | ❌ `no route to host` | ✅ 全程正常 |
| `nc` / `ssh`（Apple） | ✅ | ✅ |

结论只能是"**按二进制身份**判定"，不可能是路由——路由对进程一视同仁。同时排除：
`route -n get 192.168.50.107` 选的是 en0（正确）、ARP 表有正常条目
（`bc:24:11:ba:af:2b on en0`）、`tailscale down` 后仍复现（ROADMAP 当时已验证）。

## 为什么骗了这么久

- **错误信息和真故障同形**。`EHOSTUNREACH` 是路由层的经典错误码，没人会想到隐私授权。
- **排查者手边的工具全是 Apple 的**。`ping`/`curl`/`ssh`/`nc` 全通，于是"网络没问题、
  是 terraform 的锅"——方向从一开始就偏了（ROADMAP 里那句"从 provider 的 HTTP client
  行为查起"正是这个误导的产物）。
- **Tailscale 路径一直好用**，而本仓库的约定恰好是"节点一律用 Tailscale 寻址"，
  于是这个坑只在少数直连 LAN 的场合露头，长期被绕过去而非被定性。
- 路由表里确实有噪音（`192.168.50.0/24` 同时挂 en0 与 utun5），**是个诱人的假线索**。

## 处置

**根治**（一次性，需 GUI）：系统设置 → 隐私与安全性 → **本地网络** → 允许运行这些
CLI 的终端程序（Terminal / iTerm / Claude Code）。授权后 terraform 直连
`192.168.50.4:8006`、kubectl 直连 `192.168.50.107:6443` 都应立即恢复。

**已固化的绕法**（不依赖授权状态，IaC 里就这么写的）：

| 场景 | 做法 | 位置 |
|---|---|---|
| terraform 连 106 的 PVE API | SSH 隧道 → `127.0.0.1:18006`（loopback 免疫） | `proxmox/terraform-storage/justfile` 的 `_tunnel` |
| terraform 登 PVE 导磁盘 | provider `ssh.node.address` 指 **Tailscale** 地址 | `proxmox/terraform-storage/provider.tf` |
| ~~kubectl 连实验田~~ | ~~SSH 隧道 → `127.0.0.1:16443`~~ | ⛔ 配方已随实验田退役（2026-08-13 同日 106 改入编 homelab worker）。那台机现在用主 kubeconfig 的 `k3s-homelab` context 就能看到 |

## 教训

- **不是所有 `no route to host` 都是网络问题。** macOS 15+ 起，这个错误码多了一种含义。
  判别只要一步：拿 `/usr/bin/curl` 和一个 Homebrew 二进制打同一个地址。
- **排查工具的"身份"会污染结论。** 用系统自带工具验证的"网络正常"，对被排查的第三方
  二进制并不成立——这类不对称在容器/沙箱/权限体系里越来越常见。
- **绕过去的问题不会消失**，只会在下一次直连时重新出现。这次是 IaC 化 106 的 VM 逼出来的。
