# MacBook (M2) — Ansible 配置归档

对那台**远程 Apple Silicon MacBook Pro（M2）**做可复现配置。这台机是无头 / 合盖（clamshell）运行，只经 **Tailscale**（`100.89.15.120`）访问，作为 `cluster=macbook` 被 homelab Prometheus 监控。

- 连接：`matthew@100.89.15.120`，key `~/.ssh/vgio`（见 `ansible.cfg`）。
- 控制端依赖：`ansible-core` + 集合 `community.general` / `ansible.posix`（本机已装）。

## 用法

```bash
just ping            # 连通性检查
just packages        # 确保 Homebrew + CLI 包（tmux 等）就位（无需 sudo，幂等）
just ai-clis         # 安装 AI CLI 工具（claude/qwen/codex/hermes，无需 sudo，幂等）
just node-exporter   # 装/升级 node_exporter LaunchAgent（无需 sudo，幂等）
just power           # headless 电源策略（pmset disablesleep，需 sudo 密码 -K）
just site            # 上面几个一起跑（会问 sudo 密码）
```

## Ansible 自动化的部分（幂等）

| Playbook | 内容 | sudo |
|---|---|---|
| `packages.yaml` | 确保 Homebrew(`/opt/homebrew`)+ CLI 包(`homebrew_packages`,默认 `tmux`)就位;以 matthew 身份跑(brew 不能 root)。Homebrew 缺失才跑官方安装器——**首次安装需交互式 admin 密码**,故重建机器时单独手动跑一次 | 否 |
| `ai-clis.yaml` | 安装 AI CLI 工具: `claude`(`@anthropic-ai/claude-code` npm), `qwen`(`@qwen-code/qwen-code` npm), `codex`(brew cask, 自含 arm64 二进制), `hermes`(`hermes-agent` brew formula)。先通过 brew 装 `node`(带 npm), 再 `npm install -g`。幂等：已装的不重装 | 否 |
| `node-exporter.yaml` | 下载校验 `darwin-arm64` 二进制 → `~/.local/bin/node_exporter`；写 LaunchAgent（`:9100`, KeepAlive, RunAtLoad）→ `~/Library/LaunchAgents/com.prometheus.node_exporter.plist`；`launchctl bootstrap` 到 GUI 域；校验 `/metrics` 200 | 否 |
| `power.yaml` | `pmset -c disablesleep 1`——插电时保持**系统**唤醒，合盖也不睡，从而 Tailscale 远程常在线（让"保持唤醒"不依赖 Amphetamine GUI） | 是 |

升级 node_exporter：改 `node-exporter.yaml` 里的 `node_exporter_version` + `node_exporter_sha256`，再 `just node-exporter`。

## 手动 / 仅 GUI 的步骤（Ansible 做不了，列在此处归档）

这些要么需要**登录密码作为参数**、要么是**GUI-only 的 app/系统设置**，无头 SSH + Ansible 无法可靠完成：

1. **Amphetamine "Allow display sleep"**（GUI）—— **停掉航拍壁纸 CPU 的关键**。Amphetamine 当前在 `PreventUserIdleDisplaySleep`，显示器永不空闲休眠，导致 `WallpaperAerialsExtension` 24h 解码视频。改成"保持系统唤醒但允许显示器休眠"后，10 分钟空闲即关屏、航拍归零，且远程访问不受影响。
   - 经 Screen Sharing 进 GUI：菜单栏 Amphetamine → 当前会话/偏好 → 勾选 **Allow display sleep**。

2. **自动登录**（`sysadminctl`，需登录密码；**已设置**，开机后无人值守自动进会话，Tailscale + node_exporter 才会随登录起来）：
   ```bash
   sudo sysadminctl -autologin set -userName matthew -password '<登录密码>'
   sysadminctl -autologin status     # 验证
   ```
   前提：FileVault 必须**关**（已关）。

3. **立即锁屏**（`sysadminctl`，需登录密码；防止开盖直接看到桌面。默认有 300s 宽限）：
   ```bash
   sysadminctl -screenLock immediate -password '<登录密码>'
   sysadminctl -screenLock status    # 应为 immediate
   ```

4. **Tailscale 无人值守 / 登录项**（GUI）：菜单栏 Tailscale → Settings → **Run Tailscale when logged out**，让隧道在登录前就起；并确认 Tailscale 的 LoginItemHelper 为 enabled（开机自连）。

5. **桌面壁纸换静态/纯色**（GUI）：macOS 26 的默认航拍壁纸**忽略** CLI（`osascript set picture` 无效、`killall` 会被 WallpaperAgent 拉回）。经 Screen Sharing：系统设置 → 墙纸 → 选纯色。注意：做了第 1 条（允许显示器休眠）后，屏一关航拍就停，本条可有可无。

> 检测屏幕当前是否关闭（无需 sudo）：
> ```bash
> ssh -i ~/.ssh/vgio matthew@100.89.15.120 \
>   'pmset -g log | grep -E "Display is turned (on|off)" | tail -1; \
>    ps -Ao %cpu,comm | awk "/WallpaperAerials/&&!/awk/{print \"aerial \"\$1\"%\"}"'
> ```
> 最近事件 `off` 且航拍 ≈0% → 屏已关。

## 相关（在本 repo 别处）

- Prometheus 抓取 job `node-exporter-macbook`：`k8s/helm/values/kube-prometheus-stack.yaml`
- Grafana 看板 "MacBook / Node Exporter"：`k8s/helm/manifests/macbook-node-dashboard.yaml`（`Hardware` 文件夹）
