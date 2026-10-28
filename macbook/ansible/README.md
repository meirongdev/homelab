# Mac (M2 MacBook + Mac Studio + M5 工作站) — Ansible 配置归档

对两台**远程无头 Apple Silicon Mac** 做可复现配置，都只经 **Tailscale** 访问、都被 homelab
Prometheus 监控、都跑 OMLX 推理，2026-10-22 起也都是 M5 的 herdr agent 主机（替 M5 跑 agent 任务，
见「把任务派给 Studio / M2」一节）。另外管**本机 M5 的开发环境**（只装软件，见「开发环境」一节）：

| inventory 主机 | 机器 | 连接 | Prometheus job |
|---|---|---|---|
| `mbp-m2-pro` | MacBook Pro M2，合盖运行 | `matthew@100.89.15.120` | `node-exporter-macbook`（`cluster=macbook`）|
| `mac-studio` | Mac Studio M5 Max / 128G，台式机 | **`matstudio`**`@100.98.220.75` | `node-exporter-mac-studio`（`cluster=mac-studio`）|
| `m5` | MacBook Pro M5，日常工作机（跑 Ansible 的这台） | 本地连接 | 无 |

- key `~/.ssh/vgio`（见 `ansible.cfg`；登录用户默认 matthew，Studio 在 inventory 里覆盖）。
- **哪台跑哪些 playbook 由 [inventory.yaml](inventory.yaml) 的分组决定**：`macs`（两台远程机）·
  `macbook`（只有 M2：AI CLI、multica）· `omlx`（两台远程机）· `herdr`（两台远程机）· `qwen`（两台远程机）·
  开发环境三层 `base` / `dev` / `ops`（三台）。⚠️ `m5` 刻意不在 `macs` 里：那个组会被 `power`（禁睡眠）、
  `os-update`（无人值守重启）、`node-exporter` 作用到。
- 控制端依赖：`ansible-core` + 集合 `community.general` / `ansible.posix`（本机已装）。

## 用法

带 `target` 的配方不传参数就作用于该 playbook 的整个主机组，传主机名只跑一台。

```bash
just ping                    # 连通性检查（两台）
just packages [host]         # 开发环境的软件：base 层 + ops 层（三台）（无需 sudo，幂等）
just mise [host]             # 语言运行时（mise，三台）（无需 sudo，幂等）
just ai-clis [host]          # AI CLI：claude/codex 仅 M2，qwen（钉版本）M2 与 Studio，Antigravity CLI 三台（无需 sudo，幂等）
just magpie [host]           # Magpie + homelab 网关 provider（两台；每台的 LiteLLM key 从 Vault 取，无需 sudo，幂等）
just omlx [host]             # OMLX 本体：brew + LaunchAgent + settings.json 的 host/port/key（key 从 Vault 取）
just node-exporter [host]    # 装/升级 node_exporter LaunchAgent（无需 sudo，幂等）
just omlx-metrics [host]     # 装/升级 OMLX 指标采集 LaunchAgent（无需 sudo，幂等）
just macmon [host]           # 装/升级 macmon 功耗/温度/风扇 exporter（:9090，两台，无需 sudo，幂等）
just orbstack [host]         # OrbStack 容器/虚拟化环境（cask + 无头免密 + 开机自启 + 启动服务；三台，无需 sudo，幂等）
just power [host]            # headless 电源策略（逐台问 sudo 密码）
just multica-daemon          # 装/升级 Multica daemon LaunchAgent（仅 M2，认证全自动，从 Vault 取 PAT）
just herdr [host]            # herdr：开机拉起 server 的 LaunchAgent + claude/codex integration（两台，无需 sudo，幂等）
just mac-sync [host]         # 新 Mac 初始化工具：部署 mac-sync 脚本、建立 SSH 互信与 Host 别名（三台，无需 sudo，幂等；日常同步走 git）
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
| `packages.yaml` | base · ops | base：Homebrew(`/opt/homebrew`)+ 基础 CLI + AWS/GCP CLI（`awscli` + `gcloud-cli` cask）+ 克隆 oh-my-zsh/两个插件/TPM；ops：k8s/IaC 工具，HashiCorp 的 terraform/vault **先逐个 `brew trust` 再装**。以登录用户身份跑(brew 不能 root)，只补装不升级。Homebrew 缺失才跑官方安装器——**首次安装需交互式 admin 密码**,故重建机器时单独手动跑一次。包清单与理由见 playbook 本身和下面「开发环境」 | 否 |
| `mise.yaml` | dev | 写 `~/.config/mise/config.toml`（整份覆盖，版本写前缀不写 latest）→ `mise ls --missing` 有缺才 `mise install` → 再查一遍断言全部装齐。缺 mise 本体时提前失败并指向 `just packages` | 否 |
| `ai-clis.yaml` | macbook · qwen · base | base（三台）：`agy`（`antigravity-cli` brew cask，`auto_updates`，brew 不升级它）。macbook 只有 M2：`claude`(`@anthropic-ai/claude-code` npm)、`codex`(brew cask, 自含 arm64 二进制)，只补装不升级。qwen 组（M2 + Studio）：`qwen`(`@qwen-code/qwen-code`，装在 Homebrew node 下)**钉版本**（`qwen_code_version`，版本不一致就装成它；原来的 present 让 M2 停在 0.19.0，multica daemon 用的就是这份），要求 Node ≥ 22。⚠️ M2 另有一份 qwen 装在 fnm 的 node 下，交互 shell 里排在前面，不归 playbook 管，升级时手动 `npm install -g @qwen-code/qwen-code@<版本>` 跟上。hermes 2026-10-11 起不再安装（三台都已卸载） | 否 |
| `omlx.yaml` | omlx | OMLX 本体：tap（☠️ formula 在 `jundot/omlx` 主仓，不带 URL 的 `brew tap` 会去拉不存在的 `homebrew-omlx`，报的却是「could not read Username」）→ `brew install`（**只 present，不升级**）→ 往 `~/.omlx/settings.json` **合并**四个键（`server.host=<Tailscale IP>,127.0.0.1`：局域网连不上，☠️ Tailscale 必须排第一，排反了开机早于 Tailscale 时静默只剩回环 · `server.port=8000` · `auth.api_key`=Vault `secret/homelab/omlx` · `auth.allow_unauthenticated_inference=true`），其余设置不碰 → `brew services` 的 LaunchAgent `sh.brew.omlx`。没 key 时在启动前失败（0.7 起没 key 就 crash-loop）。运行版本落后于 brew 已装版本（升级后没重启）就重启。验收：`/v1/models` 免 key 200、`/api/status` 无 key 401 / 带 key 200、Tailscale IP 200、本机 LAN IP 拒绝连接、运行版本 = 已装版本 | 否 |
| `node-exporter.yaml` | macs | 下载校验 `darwin-arm64` 二进制 → `~/.local/bin/node_exporter`；写 LaunchAgent（`:9100`, KeepAlive, RunAtLoad, **`--collector.textfile.directory`**）→ `~/Library/LaunchAgents/com.prometheus.node_exporter.plist`；`launchctl bootstrap` 到 GUI 域；校验 `/metrics` 200 + `node_textfile_scrape_error == 0` | 否 |
| `omlx-metrics.yaml` | omlx | OMLX 推理指标的**生产端**：LaunchAgent `com.meirongdev.omlx-textfile-collector` 每 60s 把 `~/.omlx/stats.json` 渲染成 `omlx.prom`，投进上面那个 textfile 目录。☠️ **StartInterval 不是 KeepAlive**（渲染器跑 0.03s 就退，KeepAlive 会变重启风暴）。☠️ 渲染器是 **`mlx-learning` 仓 venv 里的 console script**（跨仓依赖），缺了会明确失败并给出 `uv sync` 的修法。`stats.json` 还不存在（OMLX 没服务过请求）时装好 plist 但**不启动**。验收会一路查到 node_exporter 那端 | 否 |
| `macmon.yaml` | macmon | 功耗 / 温度 / 风扇：`brew install macmon`（只 present）→ LaunchAgent `com.meirongdev.macmon` 跑 `macmon serve --port 9090 --interval 15000`（采样间隔与 Prometheus 抓取对齐）。Darwin 版 node_exporter 没有任何温度/功耗指标，靠它补。**不要 sudo**（读 IOReport + SMC）。☠️ macOS 27 上 CPU/内存/ANE 功耗恒为 0（不是空闲，CPU 满载时也是 0；两台都这样），抓取时已丢掉；☠️ M2 的 CPU 温度是坏的（P 核断电时探头读 0–8°C，均值乱跳），也已丢掉，M2 看 GPU 温度；整机功耗是 SMC `PSTR`，不是墙插功率。两台的口径与压测数字在 playbook 文件头。别用 `macmon serve --install`（另一个 label、抢同一端口、不能设采样间隔）。验收断言整机功耗与 GPU 温度非 0 | 否 |
| `orbstack.yaml` | base | OrbStack 容器/虚拟化环境：检查 `/Applications/OrbStack.app` 是否存在，缺失时才通过 Homebrew cask 安装（避免强行覆盖已有的 app 触发 sudo 提示）；配置 `setup.use_admin false`（避免无头机弹窗要求管理员密码）、`app.start_at_login true` 开机自启；非运行状态自动 `orb start` 并断言状态为 `Running` | 否 |
| `magpie.yaml` | macs | Magpie（官方安装器，只在缺失时装）→ `homelab` provider 指向 `llm.meirong.dev`，key 每台一把，由 `just magpie` 从 Vault `secret/homelab/magpie` 现取（字段名 = 主机名，带 key 的任务 `no_log`）→ 不暴露 `custom_dgx`、建 `qwen` 路由组（DGX 优先、Studio 兜底）→ `provider test`。☠️ 换 key 只能 `provider key`：`provider add` 给一把不同的 key 会静默新建 `homelab-2`。key 曾明文进过公开仓库，见 [records](../../docs/records/2026-10-26-litellm-keys-in-public-repo.md) | 否 |
| `multica-daemon.yaml` | multica | M2 与 Studio 的登录用户各跑一份（全权限）。装 `multica` CLI（**`darwin-arm64` 预编译包**，固定版本 + sha256，不走 Homebrew；版本在 `vars/multica.yaml`，与 chart 同版本）→ 指向自建 service → 用 Vault 里的 PAT 认证 → LaunchAgent `ai.multica.daemon`。⚠️ 未认证时**刻意不 bootstrap**（否则 KeepAlive 会把必然失败的进程反复拉起）。☠️ daemon 默认会自己追 GitHub 最新版，plist 里用 `MULTICA_DAEMON_AUTO_UPDATE=false` 关掉了。以登录用户（M2 的 matthew、Studio 的 matstudio）身份跑，任务能用它的全部凭据，所以接 Telegram/告警的 agent 不绑在这里。☠️ 同一台机器上的第二份 daemon 必须用命名 profile：本地端口由 profile 名决定（默认 19514），Studio 上受限那份已占着，这份用 `--profile full`（19950，设备名 `mac-studio-full`，见 inventory）。这是 Multica「执行任务的那一半」，整体安装见 [docs/runbooks/multica-install.md](../../docs/runbooks/multica-install.md) | 否 |
| `multica-daemon-restricted.yaml` | multica_restricted | Studio 上的**受限**执行端：建专用标准用户 `multica`（home 0700，☠️ 主组是独立的 `multica` 组而不是 `staff`，并把登录用户的 home 收成 0700：macOS 默认 home 0750 + 属组 staff，留在 staff 里就能读到 matstudio 名下 0644 的 `vault-keys.json`）→ 同版本 CLI + Qwen Code 指向本机 OMLX 的 Qwen3.8-27B（可选：Vault 里有 `studio_claude_oauth_token` 时再装该用户自己的 Claude Code，token 放 0600 env 文件）→ 只读 kubeconfig（SA `multica-agent`：`view` + 只读查 Prometheus）→ LaunchDaemon `ai.multica.daemon.restricted`（system 域 + `UserName`，因为这个用户从不 GUI 登录）。没有 gh/ssh/Vault/git 写权限。验收会实测 `kubectl auth can-i`（能 list pods，不能 get secrets / exec / delete）、不在 staff 组里，并以这个用户跑一次 `qwen -p` 确认整条模型链路能答。入口 `just multica-studio`。☠️ PAT 是你账号的，任务能借它把活转派给 M2，见文件头 | 是 |
| `herdr.yaml` | herdr | M5 派活的远端：herdr 本体（官方安装器，只在缺失时装）→ `config.toml` 关掉首次引导 → LaunchAgent `com.meirongdev.herdr-server`，**跑的是一次性启动器 `herdr remote-client-bridge </dev/null`，不是 `herdr server`**（原因见下面「把任务派给 Studio / M2」）→ 断言 `detached_server_daemon: true` → 给已装的 claude/codex 装或刷新 integration。启动器重载不影响正在跑的 pane | 否 |
| `mac-sync.yaml` | base | 新 Mac 初始化：部署 `mac-sync` 脚本（只把目录整份复制到新机器，对端已有的目录跳过；日常跨机同步走 git）、配置全网状 SSH 互信与 Host 别名、分发过滤规则（清单不进 git，保存在本地 `~/.config/mac-sync/dirs.list`）。指南见 [mac-sync-setup.md](../../docs/guides/mac-sync-setup.md) | 否 |
| `power.yaml` | macs | `pmset -c disablesleep 1`——插电时保持**系统**唤醒，合盖也不睡，从而 Tailscale 远程常在线（让"保持唤醒"不依赖 Amphetamine GUI）。inventory 里 `pmset_autorestart: true` 的主机（Studio，无电池）另加 `pmset -a autorestart 1`：断电恢复后自己开机 | 是 |
| `os-update.yaml` | macs | macOS 软件更新，需要重启时无人值守地重启并验收。**不在 `site` 里**（它会重启机器），见下节 | 是（自己问密码） |

升级 node_exporter：改 `node-exporter.yaml` 里的 `node_exporter_version` + `node_exporter_sha256`，再 `just node-exporter`。

⚠️ **OMLX 指标是两个 playbook 合起来才成立的一条链路**：`node-exporter.yaml` 是读取端
（加 textfile flag），`omlx-metrics.yaml` 是生产端（写 `.prom`）。只跑一个**不会报错**，
指标静默不出现 —— 所以两个 playbook 都会跨过自己那一半去验收整条链路，并在缺另一半时
直接告诉你该跑哪条命令。`just site` 已按正确顺序（先读取端后生产端）包含两者。
口径/陷阱/单段排查 → [docs/reference/omlx-inference-metrics.md](../../docs/reference/omlx-inference-metrics.md)。

## 开发环境（base / dev / ops）

按层装，每台只进它需要的组（[inventory.yaml](inventory.yaml)）：

| 层 | 组 | 主机 | 装什么 | playbook |
|---|---|---|---|---|
| 1 基础 | `base` | M5 · M2 · Studio | awscli、gcloud、gh、glab、tmux、chezmoi、age、mise、uv、fzf、ripgrep、yq、htop、just、lazygit、hugo；oh-my-zsh + zsh-autosuggestions + zsh-syntax-highlighting；TPM | `packages.yaml` |
| 2 运行时 | `dev` | M5 · M2 · Studio | mise 管：node、pnpm、bun、go、python、java（temurin）、maven、gradle、rust | `mise.yaml` |
| 3 运维 | `ops` | M5 · M2 · Studio | kubectl、helm、kubectx、k9s、cilium-cli、hubble、argocd、ansible、gitleaks、kind、tilt、k6、kubeconform、terraform、vault | `packages.yaml` |

Antigravity CLI（`agy`）也是三台都装，但归 `ai-clis.yaml`（和其它 AI CLI 放在一起）。

```bash
just packages m5 && just mise m5 && just ai-clis m5   # 一台：先 packages（装 mise 本体）再 mise
just packages && just mise && just ai-clis            # 全部（按各自的组）
```

**边界：Ansible 只装软件，配置文件归 chezmoi**（dotfiles 仓库 `meirongdev/dotfiles`，
含 age 加密的凭据）。`~/.zshrc`、`~/.tmux.conf` 都不在这里写，所以：

- oh-my-zsh 是 `git clone` 下来的，**不跑它的 `install.sh`**（那个会改写 `~/.zshrc` 并 `chsh`）。
  还没有 `.zshrc` 的机器装完 oh-my-zsh 也不生效，要等 chezmoi 写出 `.zshrc`（Studio 的那份由 chezmoi
  `role=agent` 在 2026-10-22 写出；M2 和 M5 用各自手写的）。
- mise 装好的运行时，要等 `.zshrc` 里有 `eval "$(mise activate zsh)"` 才会用上，在那之前
  PATH 上仍是 brew 的 node/go。brew 的 node 会一直在（`ai-clis.yaml` 和 qwen-code 等 formula 依赖它）。
- ☠️ **mise 的 shim 不在默认位置**（`shims_dir = ~/.local/share/mise/shims-hidden`，写在 `mise.yaml` 管的全局配置里）。
  GUI 应用看不到 shell 的 PATH，有的会无条件把默认的 `~/.local/share/mise/shims` 拼到自己 PATH 的最前面（排在 fnm/Homebrew 前），
  shim 一出现，它拉起的所有进程就静默改用 mise 的 node/python/java（2026-10-11 撞上过）。
  我们走 `mise activate` 不用 shim，挪走无损失。别改回默认，也别在这台机器上 `mise activate --shims`。
- AWS/GCP CLI 装上≠能管资源。`~/.aws/config` 与 gcloud 配置由 chezmoi 按 role 下发，
  `~/.aws/credentials` 只发 `workstation` 和 `agent`（Studio、M2；dotfiles README 里的「暂定」）；gcloud 的登录令牌
  不在 chezmoi 里：agent 主机是 2026-10-22 从 M5 一次性拷过去的，其他机器自己 `gcloud auth login --no-launch-browser`。

**新机器从零开始**：先手动做 Ansible 做不了的两步，再跑上面两条命令。

1. `xcode-select --install`：没装 CLT 时，`/usr/bin/python3` 只是个会弹 GUI 安装框的占位程序，
   Ansible 的任何模块都跑不起来（无头机上那个框没人看得见）。
2. Homebrew 官方安装器：要交互输入 admin 密码。

要在新机器上改这个仓库（密钥、kubeconfig、pre-push 钩子、要从旧机拷的 gitignored 文件），
完整流程见 [docs/guides/dev-machine-bootstrap.md](../../docs/guides/dev-machine-bootstrap.md)。

## 把任务派给 Studio / M2（herdr）

2026-10-22 起两台远程 Mac 都是 M5 的 agent 主机：M5 用 [herdr](https://herdr.dev) 把 agent 任务派过去跑。
三块分别归三个地方管：

| 哪一块 | 归谁管 | 内容 |
|---|---|---|
| 远端常驻 | 本目录 `herdr.yaml`（`just herdr`） | herdr 本体、开机拉起 server 的 LaunchAgent、claude/codex 的 integration |
| 凭据 | dotfiles 仓库，chezmoi `role=agent` | 和 M5 相同，只少 Terraform（state 只在 M5 上，有 token 没 state 时 `apply` 会把资源再建一份）。kubeconfig、gcloud 这类工具自己维护的登录状态是从 M5 一次性拷的，命令和 M2 的差异都写在 dotfiles README |
| M5 这端 | `herdr machine add studio` / `herdr machine add m2`，一次性，存在 M5 的 herdr 配置里 | SSH 目标就是 `~/.ssh/config` 里的 `studio`、`m2` 两个 Host（也由 dotfiles 下发） |

在 M5 上（`herdr` TUI 的侧栏里也能直接切到这两台）：

```bash
herdr machine status                     # 两台都应是 reachable
herdr --machine studio workspace create --cwd /Users/matstudio/projects/homelab --label <任务名> --no-focus
#   → 返回里的 .result.root_pane.pane_id
herdr --machine studio agent start <名字> --kind claude --pane <pane_id>
herdr --machine studio agent prompt <名字> "<任务>" --wait --timeout 600000
herdr --machine studio agent read <名字> --source recent-unwrapped --lines 120
herdr --machine studio workspace close <workspace_id>
```

- ⚠️ `--cwd` 写**远端**的绝对路径：Studio 的家目录是 `/Users/matstudio`，M2 是 `/Users/matthew`。代码要先在那台机器上
  clone 好（herdr 不同步代码）。
- ☠️ `herdr --machine` 的 CLI 转发**从不启动**远端 server，server 不在时只报连不上。开机由 LaunchAgent 拉起；
  手动 `herdr server stop` 之后，在那台机器上 `launchctl kickstart gui/$(id -u)/com.meirongdev.herdr-server`
  （或在 M5 打开 TUI，侧栏重连时也会拉起）。
- ☠️ 远端 server 必须是 herdr **自己 detach 出来的**（`herdr status server --json` 的
  `capabilities.detached_server_daemon` 为 `true`），否则 `machine add` 和侧栏只报一句
  「remote server is not ready for saved machines」，不说原因。launchd 拉起的进程已经是进程组组长，
  setsid 不了，所以 LaunchAgent 跑的是一次性启动器 `herdr remote-client-bridge </dev/null`（saved machine
  经 SSH 调的就是这条），不是 `herdr server`。也别在这两台上手动跑 `herdr server`。
- 升级：`herdr update` 只换二进制，跑着的 server 仍是旧版，等远端没有 agent 在跑时 `herdr server stop`
  再 kickstart。之后重跑 `just herdr`，把显示 `outdated` 的 integration 刷新掉。
- integration 的 hook 只在 herdr pane 里生效（脚本先查 `HERDR_ENV`），M2 上 multica 拉起的 claude/codex 不受影响。
- 两台的 claude 登录的是个人 Pro 账号，不是 M5 的 Team 账号（2026-10-22），额度小得多，
  首次派活就碰到了 usage limit。要换账号，在那台机器的 claude 里 `/login`。
- 提交身份：agent 主机的 `~/.gitconfig` 按 remote 地址选个人/工作身份（dotfiles `role=agent`），
  不会再出现 `matstudio@Matthews-Mac-Studio.local` 这种 git 自己凑的身份。

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
  没写死清单，vllm 这类非本 repo 管的也覆盖）、`SleepDisabled` 仍为 1
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

2. **Amphetamine 允许显示器休眠**（CLI 可做，不必进 GUI；**2026-10-22 已改**）—— **停掉航拍壁纸 CPU 的关键**。
   Amphetamine 出厂默认 `Allow Display Sleep = 0`，又开着 `Start Session At Launch`（无限期），
   于是每次登录都起一个同时挂 `PreventUserIdleSystemSleep` 和 `PreventUserIdleDisplaySleep` 的会话：
   显示器永不空闲休眠（合盖也一样，系统照样认为屏是亮的），`WallpaperAerialsExtension` 24h 解码视频。
   改之前整机功耗 24h 中位数 8.2W，关屏后 ~4W。
   显示器开关**与 Wi‑Fi / 远程访问无关**：掉线只发生在整机睡眠，那由 `SleepDisabled 1`（`just power`）
   和 Amphetamine 的 `Allow Closed-Display Sleep = 0` 管，这两项都别动。
   改法是写沙盒容器里的偏好再重启 app（app 停的那几秒靠 `SleepDisabled 1` 保持唤醒）：
   ```bash
   D=~/Library/Containers/com.if.Amphetamine/Data/Library/Preferences/com.if.Amphetamine
   killall Amphetamine; sleep 2
   defaults write "$D" "Allow Display Sleep" -int 1
   open -a Amphetamine; sleep 5
   pmset -g assertions | grep Amphetamine   # 只剩 PreventUserIdleSystemSleep 才算生效
   ```
   改完后 `pmset -g` 的 `displaysleep 10` 后面不再带 `(display sleep prevented by Amphetamine)`。
   要立刻关屏（不等 10 分钟空闲）：`pmset displaysleepnow`，无需 sudo。

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
