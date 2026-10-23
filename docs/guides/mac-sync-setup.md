# 多 Mac 目录与工作区同步 (mac-sync)

> Last updated: 2026-10-23
> 
> 面向「多台 Mac 之间共享开发目录、未提交代码与资料，以及让 Agent 在不同机器上协作」的同步体系指南。
> 架构自动化实现由 `macbook/ansible` 托管（[README](../../macbook/ansible/README.md)）；AI 助手上下文见 [../AGENTS.md](../AGENTS.md)。

## 1. 架构与设计原则

本工具（`mac-sync`）专为解决多台 Apple Silicon Mac（M5 工作站、M2 MacBook、Mac Studio）之间随地切换工作、避免 Agent 协作冲突而设计：

1. **目录清单绝不进 Repo（数据面与机制解耦）**：
   - 仓库仅固化同步机制、Jinja2 模板与 Ansible 自动化脚本。
   - 具体的同步目录清单严格保存在各台机器本地：`~/.config/mac-sync/dirs.list`。
   - 增减同步目录只需编辑本地该文件，任何机器的个人工作区变动均不污染 Git 历史。
2. **抹平系统用户名差异**：
   - Mac Studio 登录名为 `matstudio`，而 M5 与 M2 为 `matthew`。
   - `mac-sync` 脚本与 Ansible 生成的 `~/.ssh/config` 自动处理用户家目录映射，统一使用 `~/<relative_path>` 寻址。
3. **Agent & Git 安全免疫过滤**：
   - 完整保留 Git Commit 历史、分支与未提交代码（包含 `.git` 目录）。
   - 全局过滤列表（`~/.config/mac-sync/exclude.list`）强制拦截临时锁与构建噪音：
     `node_modules/`、`__pycache__/`、`.venv/`、`.terraform/`、`dist/`、`target/`、`.git/*.lock`。
   - 彻底杜绝跨机并发冲突或损坏开发环境。

---

## 2. 日常使用（三台机器通用）

无论在 M5、M2 还是 Studio 上，均可直接运行：

```bash
# 检查当前机器身份、对端机器连通性与已配置目录的大小
mac-sync status

# 将当前机器的改动一键推送到其他所有在线机器（增量安全推送，不覆盖对端更新的文件）
mac-sync push

# 从指定机器拉取最新改动（例如在 Studio 上干完活，回到 M5 时拉取）
mac-sync pull studio
```

### 目录清单配置（本地独立维护）

编辑 `~/.config/mac-sync/dirs.list`（相对家目录路径，一行一个）：

```text
projects/repo-a
projects/repo-b
documents/notes
```

---

## 3. 新机器加入（Add a new Mac）

当有一台新的 Mac（例如一台新 MacBook 或 Mac mini）加入舰队时，流程完全自动化：

### 步骤 1：新机器基础准备
1. 确保新机器已接入 Tailscale 网络（获得固定 100.x.x.x IP）。
2. 在系统设置中开启远程登录：**系统设置 → 通用 → 共享 → 打开「远程登录 (Remote Login)」**。
3. 确保现有密钥 `~/.ssh/vgio` 与 `~/.ssh/vgio.pub` 已拷贝至新机器的 `~/.ssh/`（权限 `600`/`644`）。

### 步骤 2：更新仓库中的机器定义
在 `macbook/ansible/playbooks/mac-sync.yaml` 的 `mac_fleet` 字典中登记新机器，并在 `macbook/ansible/inventory.yaml` 的 `base` 组中加入主机：

```yaml
# macbook/ansible/playbooks/mac-sync.yaml
mac_fleet:
  new-mac:
    host_name: my-new-mac
    tailscale_ip: "100.x.x.x"
    user: matthew
    ssh_alias: new-mac
```

### 步骤 3：一键部署与打通全网互信
在 M5 本机运行：

```bash
cd macbook/ansible && just mac-sync
```

Ansible 将自动完成：
* 新机器的 `~/.local/bin/mac-sync` 与 `~/.config/mac-sync/exclude.list` 部署。
* 自动在新机器上初始化 `dirs.list` 模板。
* **全网全自动更新 `~/.ssh/config`**：老机器（M5/Studio/M2）自动获得 `Host new-mac` 配置；新机器自动获得全套老机器的别名与免密授权。
* 自动在各端运行 `mac-sync status` 校验全链路连通性。

---

## 4. 机器离开/下线（Decommission a Mac）

当某台 Mac 退休或移出集群时：

1. 从 `macbook/ansible/playbooks/mac-sync.yaml` 的 `mac_fleet` 字典中删除该节点。
2. 从 `macbook/ansible/inventory.yaml` 对应分组中移除。
3. 重新跑一遍：
   ```bash
   cd macbook/ansible && just mac-sync
   ```
   Ansible 会通过 `blockinfile` 自动重写所有留存机器的 `~/.ssh/config`，清理旧节点的别名块，并更新 `mac-sync` 脚本内的探测列表。

---

## 5. 后台自动定时同步（可选 LaunchAgent）

若希望工作机在后台静默自动向其他无头机推送更新，可以使用随脚本自动部署的 LaunchAgent（每 5 分钟安全巡检推送一次，断网或对端休眠时静默跳过）：

```bash
# 启用定时推送（每 5 分钟）
cp ~/.config/mac-sync/com.meirongdev.mac-sync.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.meirongdev.mac-sync.plist

# 停用
launchctl unload ~/Library/LaunchAgents/com.meirongdev.mac-sync.plist
rm -f ~/Library/LaunchAgents/com.meirongdev.mac-sync.plist
```
