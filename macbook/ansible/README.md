# Mac (M2 MacBook + Mac Studio) — Ansible 配置归档

对两台**远程无头 Apple Silicon Mac** 做可复现配置，都只经 **Tailscale** 访问、都被 homelab
Prometheus 监控、都跑 OMLX 推理：

| inventory 主机 | 机器 | 连接 | Prometheus job |
|---|---|---|---|
| `mbp-m2-pro` | MacBook Pro M2，合盖运行 | `matthew@100.89.15.120` | `node-exporter-macbook`（`cluster=macbook`）|
| `mac-studio` | Mac Studio M5 Max / 128G，台式机 | **`matstudio`**`@100.98.220.75` | `node-exporter-mac-studio`（`cluster=mac-studio`）|

- key `~/.ssh/vgio`（见 `ansible.cfg`；登录用户默认 matthew，Studio 在 inventory 里覆盖）。
- **哪台跑哪些 playbook 由 [inventory.yaml](inventory.yaml) 的分组决定**：`macs`（全部）·
  `macbook`（只有 M2：AI CLI、multica）· `omlx`（两台）。
- 控制端依赖：`ansible-core` + 集合 `community.general` / `ansible.posix`（本机已装）。

## 用法

带 `target` 的配方不传参数就作用于该 playbook 的整个主机组，传主机名只跑一台。

```bash
just ping                    # 连通性检查（两台）
just packages [host]         # 确保 Homebrew + CLI 包（tmux / uv）就位（无需 sudo，幂等）
just ai-clis                 # 安装 AI CLI 工具（claude/qwen/codex/hermes，仅 M2，无需 sudo，幂等）
just omlx [host]             # OMLX 本体：brew + LaunchAgent + settings.json 的 host/port/key（key 从 Vault 取）
just node-exporter [host]    # 装/升级 node_exporter LaunchAgent（无需 sudo，幂等）
just omlx-metrics [host]     # 装/升级 OMLX 指标采集 LaunchAgent（无需 sudo，幂等）
just macmon [host]           # 装/升级 macmon 功耗/温度/风扇 exporter（:9090，两台，无需 sudo，幂等）
just power [host]            # headless 电源策略（逐台问 sudo 密码）
just multica-daemon          # 装/升级 Multica daemon LaunchAgent（仅 M2，认证全自动，从 Vault 取 PAT）
just site [host]             # 上面几个一起跑（逐台跑、逐台问 sudo 密码）

just os-updates [host]       # 只读：列出待装的 macOS 更新 + 本次会装什么（不要密码，可一次看两台）
just os-update <host>        # 装系统小版本/安全更新 + Safari/CLT，需要时自动重启并验收（一次一台）
just os-update-no-restart <host>  # 只装免重启的更新（Safari/CLT 等），需重启的留给下次
just os-upgrade-major <host> # 大版本升级（如 26 → 27），见下文风险
```

⚠️ 需要 sudo 的配方逐台跑：两台的登录密码不同，`--ask-become-pass` 只问一次，一次跑两台
必有一台认证失败。`os-update` 另有断言，一次只允许一台（还因为两台同时重启就同时失联）。

## Ansible 自动化的部分（幂等）

| Playbook | 主机组 | 内容 | sudo |
|---|---|---|---|
| `packages.yaml` | macs | 确保 Homebrew(`/opt/homebrew`)+ CLI 包(`homebrew_packages`：`tmux`、`uv`)就位;以登录用户身份跑(brew 不能 root)。Homebrew 缺失才跑官方安装器——**首次安装需交互式 admin 密码**,故重建机器时单独手动跑一次 | 否 |
| `ai-clis.yaml` | macbook | 安装 AI CLI 工具: `claude`(`@anthropic-ai/claude-code` npm), `qwen`(`@qwen-code/qwen-code` npm), `codex`(brew cask, 自含 arm64 二进制), `hermes`(`hermes-agent` brew formula)。先通过 brew 装 `node`(带 npm), 再 `npm install -g`。幂等：已装的不重装 | 否 |
| `omlx.yaml` | omlx | OMLX 本体：tap（☠️ formula 在 `jundot/omlx` 主仓，不带 URL 的 `brew tap` 会去拉不存在的 `homebrew-omlx`，报的却是「could not read Username」）→ `brew install`（**只 present，不升级**）→ 往 `~/.omlx/settings.json` **合并**四个键（`server.host=0.0.0.0` · `server.port=8000` · `auth.api_key`=Vault `secret/homelab/omlx` · `auth.allow_unauthenticated_inference=true`），其余设置不碰 → `brew services` 的 LaunchAgent `sh.brew.omlx`。没 key 时在启动前失败（0.7 起没 key 就 crash-loop）。验收：`/v1/models` 免 key 200、`/api/status` 无 key 401 / 带 key 200 | 否 |
| `node-exporter.yaml` | macs | 下载校验 `darwin-arm64` 二进制 → `~/.local/bin/node_exporter`；写 LaunchAgent（`:9100`, KeepAlive, RunAtLoad, **`--collector.textfile.directory`**）→ `~/Library/LaunchAgents/com.prometheus.node_exporter.plist`；`launchctl bootstrap` 到 GUI 域；校验 `/metrics` 200 + `node_textfile_scrape_error == 0` | 否 |
| `omlx-metrics.yaml` | omlx | OMLX 推理指标的**生产端**：LaunchAgent `com.meirongdev.omlx-textfile-collector` 每 60s 把 `~/.omlx/stats.json` 渲染成 `omlx.prom`，投进上面那个 textfile 目录。☠️ **StartInterval 不是 KeepAlive**（渲染器跑 0.03s 就退，KeepAlive 会变重启风暴）。☠️ 渲染器是 **`mlx-learning` 仓 venv 里的 console script**（跨仓依赖），缺了会明确失败并给出 `uv sync` 的修法。`stats.json` 还不存在（OMLX 没服务过请求）时装好 plist 但**不启动**。验收会一路查到 node_exporter 那端 | 否 |
| `macmon.yaml` | macmon | 功耗 / 温度 / 风扇：`brew install macmon`（只 present）→ LaunchAgent `com.meirongdev.macmon` 跑 `macmon serve --port 9090 --interval 15000`（采样间隔与 Prometheus 抓取对齐）。Darwin 版 node_exporter 没有任何温度/功耗指标，靠它补。**不要 sudo**（读 IOReport + SMC）。☠️ macOS 27 上 CPU/内存/ANE 功耗恒为 0（不是空闲，CPU 满载时也是 0；两台都这样），抓取时已丢掉；☠️ M2 的 CPU 温度是坏的（P 核断电时探头读 0–8°C，均值乱跳），也已丢掉，M2 看 GPU 温度；整机功耗是 SMC `PSTR`，不是墙插功率。两台的口径与压测数字在 playbook 文件头。别用 `macmon serve --install`（另一个 label、抢同一端口、不能设采样间隔）。验收断言整机功耗与 GPU 温度非 0 | 否 |
| `multica-daemon.yaml` | macbook | 装 `multica` CLI（**`darwin-arm64` 预编译包**，固定版本 + sha256，不走 Homebrew）→ 指向自建 service → 用 Vault 里的 PAT 认证 → LaunchAgent `ai.multica.daemon`。⚠️ 未认证时**刻意不 bootstrap**（否则 KeepAlive 会把必然失败的进程反复拉起）。这是 Multica「执行任务的那一半」，整体安装见 [docs/runbooks/multica-install.md](../../docs/runbooks/multica-install.md) | 否 |
| `power.yaml` | macs | `pmset -c disablesleep 1`——插电时保持**系统**唤醒，合盖也不睡，从而 Tailscale 远程常在线（让"保持唤醒"不依赖 Amphetamine GUI）。inventory 里 `pmset_autorestart: true` 的主机（Studio，无电池）另加 `pmset -a autorestart 1`：断电恢复后自己开机 | 是 |
| `os-update.yaml` | macs | macOS 软件更新，需要重启时无人值守地重启并验收。**不在 `site` 里**（它会重启机器），见下节 | 是（自己问密码） |

升级 node_exporter：改 `node-exporter.yaml` 里的 `node_exporter_version` + `node_exporter_sha256`，再 `just node-exporter`。

⚠️ **OMLX 指标是两个 playbook 合起来才成立的一条链路**：`node-exporter.yaml` 是读取端
（加 textfile flag），`omlx-metrics.yaml` 是生产端（写 `.prom`）。只跑一个**不会报错**，
指标静默不出现 —— 所以两个 playbook 都会跨过自己那一半去验收整条链路，并在缺另一半时
直接告诉你该跑哪条命令。`just site` 已按正确顺序（先读取端后生产端）包含两者。
口径/陷阱/单段排查 → [docs/reference/omlx-inference-metrics.md](../../docs/reference/omlx-inference-metrics.md)。

## 系统更新（`os-update.yaml`）

系统设置里的自动更新开关全开着，但在无头机上不生效（2026-09-26 M2 实测：26.7 挂着没装，
已 96 天没重启），所以改由 Ansible 触发。先 `just os-updates` 看计划，再 `just os-update`。

- **装什么**：不需要重启的（Safari、CLT…）全装，同一产品线只装最新版；需要重启的
  **一次只装一个**（版本最高的那个），其余下次再跑。大版本默认跳过；需要**关机**才能完成的
  一律不装（远程关了机没人按电源键）。`just os-update-no-restart` 只装免重启的，
  需重启的留给下次 `os-update`。
- **密码**：确认计划后问一次登录密码。sudo 和 Apple Silicon 的 volume owner 认证
  （`softwareupdate --user --stdinpass`）共用它，所以没用 `--ask-become-pass`（`-K` 拿到的
  密码不暴露给任务）。密码不进命令行参数。
- **重启前拒绝继续的情况**：FileVault 开着、自动登录用户不是该机的登录用户（`matthew` / `matstudio`）、没插电、空闲空间
  不够（小版本 20 GiB、大版本 40 GiB）、已有 `softwareupdate` 在跑。前两条不满足时重启后
  这台机就回不来了（停在解锁界面或登录窗口）。Tailscale「Run when logged out」
  （下面手动步骤 5）CLI 查不了，没法断言，靠你自己保证。
- **重启后验收**：版本到位、控制台用户是该机的登录用户（自动登录生效）、node_exporter
  `/metrics` 200、重启前**在运行的** LaunchAgent 全部重新跑起来（按运行时快照比对，
  没写死清单，hermes/vllm 这些非本 repo 管的也覆盖）、`SleepDisabled` 仍为 1
  （丢了就跑 `just power`）。
- **日志**：`/var/log/macbook-os-update.log`（root）。安装失败时 playbook 会直接把末尾打出来；
  重启前就失败的（认证、找不到该更新）会立刻报错，不用等超时。
- ☠️ **`os-upgrade-major`**：大版本升级后可能要重新批准 Tailscale 系统扩展，或停在升级后的
  设置助手。任何一个都会让它失联，只能去现场处理。确认有人能碰到机器再跑。

## 手动 / 仅 GUI 的步骤（Ansible 做不了，列在此处归档）

这些要么需要**登录密码作为参数**、要么是**GUI-only 的 app/系统设置**，无头 SSH + Ansible 无法可靠完成：

1. **开启「远程登录」(SSH)**（GUI）—— 系统设置 → 通用 → 共享 → **远程登录**。
   ☠️ **这是所有其它步骤的前提**：不开它 Ansible 根本连不上，而本机是无头运行，
   只能先经 Screen Sharing 或临时接显示器做这一次。同理需要先装好并登录 **Tailscale**
   （勾 *Run Tailscale when logged out*），否则重启后在登录前无隧道、SSH 也进不来。

2. **Amphetamine "Allow display sleep"**（GUI）—— **停掉航拍壁纸 CPU 的关键**。Amphetamine 当前在 `PreventUserIdleDisplaySleep`，显示器永不空闲休眠，导致 `WallpaperAerialsExtension` 24h 解码视频。改成"保持系统唤醒但允许显示器休眠"后，10 分钟空闲即关屏、航拍归零，且远程访问不受影响。
   - 经 Screen Sharing 进 GUI：菜单栏 Amphetamine → 当前会话/偏好 → 勾选 **Allow display sleep**。

3. **自动登录**（`sysadminctl`，需登录密码；**已设置**，开机后无人值守自动进会话，Tailscale + node_exporter 才会随登录起来）：
   ```bash
   sudo sysadminctl -autologin set -userName matthew -password '<登录密码>'
   sysadminctl -autologin status     # 验证
   ```
   前提：FileVault 必须**关**（已关）。

4. **立即锁屏**（`sysadminctl`，需登录密码；防止开盖直接看到桌面。默认有 300s 宽限）：
   ```bash
   sysadminctl -screenLock immediate -password '<登录密码>'
   sysadminctl -screenLock status    # 应为 immediate
   ```

5. **Tailscale 无人值守 / 登录项**（GUI）：菜单栏 Tailscale → Settings → **Run Tailscale when logged out**，让隧道在登录前就起；并确认 Tailscale 的 LoginItemHelper 为 enabled（开机自连）。

6. **桌面壁纸换静态/纯色**（GUI）：macOS 26 的默认航拍壁纸**忽略** CLI（`osascript set picture` 无效、`killall` 会被 WallpaperAgent 拉回）。经 Screen Sharing：系统设置 → 墙纸 → 选纯色。注意：做了第 2 条（允许显示器休眠）后，屏一关航拍就停，本条可有可无。

> 检测屏幕当前是否关闭（无需 sudo）：
> ```bash
> ssh -i ~/.ssh/vgio matthew@100.89.15.120 \
>   'pmset -g log | grep -E "Display is turned (on|off)" | tail -1; \
>    ps -Ao %cpu,comm | awk "/WallpaperAerials/&&!/awk/{print \"aerial \"\$1\"%\"}"'
> ```
> 最近事件 `off` 且航拍 ≈0% → 屏已关。

### Mac Studio 的现状（2026-10-03 逐项核对）

上面是按 M2 写的。Studio 上对应各条的状态，以及它独有的两步：

| 项 | Studio 现状 |
|---|---|
| 1 远程登录 | ✅ `com.openssh.sshd => enabled`；Tailscale 用的是 **Tailscale.app**（macsys 系统扩展），登录项 enabled、`TailscaleStartOnLogin=1` |
| 1/5 Run when logged out | ❓ CLI 查不到。目前靠自动登录兜着：自动登录一旦失效（例如改了登录密码），重启后就只剩局域网 `192.168.50.33` 能 SSH |
| 2/6 Amphetamine / 航拍壁纸 | 不适用：没装 Amphetamine，`displaysleep 10` 本来就会关屏 |
| 3 自动登录 | ✅ `matstudio`；FileVault Off |
| 4 立即锁屏 | 未核对 |
| ⚠️ 第二个 Tailscale | brew 的 `tailscale` formula 也装了，它的 `tailscaled` 以 root LaunchDaemon（`sh.brew.tailscale`）常驻，处于 **Logged out**，占着一个 utun。隧道是 App 那个的，这个是多余的；两套 daemon 并存是隐患，清掉：`sudo brew services stop tailscale && brew uninstall tailscale` |
| 渲染器 venv（omlx-metrics 的跨仓依赖）| ✅ 已手动建：`git clone https://github.com/meirongdev/mlx-learning.git ~/projects/meirongdev/mlx-learning && cd $_ && uv sync`（公开仓，走 https 不需要 GitHub 凭据）|

**模型**（2026-10-03）：`Qwen3.8-27B-MLX-4bit`（HF `lmstudio-community/Qwen3.8-27B-MLX-4bit`，
16.1 GB，VLM，262k ctx）。实测冷装载 14.4s、短 prompt 解码约 29 tok/s。
OMLX 0.7 的目录布局是 `~/.omlx/models/<org>/<name>/`，模型 ID **不带 org**；M2 上那批
`org__name` 平铺目录是旧版留下的，两种都能识别。命令行下载与 admin 面板等价，但 OMLX
**只在启动时扫描**，下完要 `launchctl kickstart -k gui/$(id -u)/sh.brew.omlx` 才会出现在 `/v1/models`：
```bash
ssh -i ~/.ssh/vgio matstudio@100.98.220.75
D=~/.omlx/models/<org>/<name>
HF_HUB_DISABLE_XET=1 /opt/homebrew/opt/omlx/libexec/bin/hf download <org>/<name> --local-dir "$D"
```

**DFlash2 投机解码**（2026-10-03 开启，生成提速 1.3–3.4 倍。草稿模型猜、主模型逐个验证，
设计上不改变输出分布；但 temp=0 下实测与基线**不逐字相同**（中文长文 444 vs 454 token），
是批量验证的数值差异，不是质量退化的证据，也没做过质量对比）。这是 OMLX 的 per-model 设置，归 admin 面板/`~/.omlx/model_settings.json`，
不归 Ansible；重建机器时照抄：

```bash
# 草稿模型：z-lab（DFlash 作者）为 Qwen3.8-27B 训练的 5 层 DFlash2 drafter，3.85 GB
D=~/.omlx/drafts/z-lab/Qwen3.8-27B-DFlash2      # 刻意不放 ~/.omlx/models，否则会被当成模型列进 /v1/models
HF_HUB_DISABLE_XET=1 /opt/homebrew/opt/omlx/libexec/bin/hf download z-lab/Qwen3.8-27B-DFlash2 --local-dir "$D"
# ~/.omlx/model_settings.json 里该模型加两个键，然后 launchctl kickstart -k gui/$(id -u)/sh.brew.omlx
#   "Qwen3.8-27B-MLX-4bit": {"dflash_enabled": true, "dflash_draft_model": "/Users/matstudio/.omlx/drafts/z-lab/Qwen3.8-27B-DFlash2"}
```

生效判据是 `/opt/homebrew/var/log/omlx.log` 里的 `DFlash drafter attached to engine ... kind=dflash2`。
`qwen3_5` 架构 + VLM 引擎走的是**批处理引擎内的 drafter**，视觉输入与并发都保留
（其它架构会退到单流 DFlashEngine）。实测（同一组 prompt，512 token，关思考）：

| | 基线 | DFlash temp=0 | DFlash temp=0.7 |
|---|---|---|---|
| 写代码 | 31.9 tok/s | 96–109 tok/s | 91–94 tok/s |
| 中文长文 | 31.9 tok/s | 43.8 tok/s | 39–42 tok/s |

基线 31.9 已接近带宽上限（稠密 27B 每 token 读一遍 16.6G 权重），不靠投机解码调参快不了多少。
可预测的文本（代码）收益最大；中文散文草稿命中率低，只多 25–37%。
⚠️ 没走 MTP：这一版（以及 mlx-community 的 4bit）转换时**删掉了 MTP 权重**，OMLX 的
Lightning MTP 没有头可用。

**预填充**（2026-10-03 实测）：3.7k token 865 tok/s（TTFT 4.2s）、14.8k token 1000 tok/s（TTFT 14.8s），
长文档/长对话时首 token 的等待才是瓶颈。OMLX 的 `qwen35_prefill` native 内核（q4 affine qmm、
head_dim 256 注意力）专门加速这一段，但**默认安装不带**（日志里自定义内核全部 import 失败就是这个），
`brew reinstall jundot/omlx/omlx --with-custom-kernel` 在 Studio 上**编译失败**：
`xcrun: error: unable to find utility "metal"` —— 要**完整 Xcode** 里的 Metal 编译器，
Command Line Tools 不够。Homebrew 失败时会还原原安装，服务不受影响。装了 Xcode
（`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`，`xcrun -sdk macosx metal --version` 能出版本号）
之后再重跑那条 reinstall，再按上面的数字对比。

## 相关（在本 repo 别处）

- **Multica daemon**（这台机跑的「执行任务那一半」）：安装/重建/退役全流程见 [docs/runbooks/multica-install.md](../../docs/runbooks/multica-install.md) 的步骤 6；⚠️ daemon 掉线时**服务端一切正常**（页面 200、监控全绿），判据在服务端 `agent_runtime` 表

- Prometheus 抓取 job `node-exporter-macbook` / `node-exporter-mac-studio`：`k8s/helm/values/kube-prometheus-stack.yaml`
  （⚠️ 两个 job 用 YAML 锚点共用 `metric_relabel_configs`：`omlx_*` → `omlx_alltime_*`，理由见下面那篇）
- Prometheus 抓取 job `macmon`（功耗/温度/风扇，`:9090`，每台 Mac 一个 target）：同一文件；看板是下面这张的「🌡️ 功耗 / 温度」行
- Grafana 看板 "Mac / Node Exporter"（两台共用，顶部选机器）：`k8s/helm/manifests/monitoring/dashboards/macbook-node-dashboard.yaml`（`Hardware` 文件夹）
- **OMLX 推理指标**（两条链路的口径、陷阱、验收）：[docs/reference/omlx-inference-metrics.md](../../docs/reference/omlx-inference-metrics.md)
  · 看板 "Hardware / Mac OMLX 推理"：`k8s/helm/manifests/monitoring/dashboards/omlx-dashboard.yaml`
