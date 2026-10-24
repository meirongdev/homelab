# 新 Mac 初始化与跨机同步 (mac-sync)

> Last updated: 2026-10-24
> 
> 面向「多台 Mac 之间切换工作、让 Agent 在不同机器上协作」的同步约定，以及新机器的初始化工具 `mac-sync`。
> 架构自动化实现由 `macbook/ansible` 托管（[README](../../macbook/ansible/README.md)）；AI 助手上下文见 [../AGENTS.md](../AGENTS.md)。

## 1. 分工：日常走 git，mac-sync 只初始化新机器

| 场景 | 用什么 |
|---|---|
| 已提交的代码在 M5 / M2 / Studio 之间流转 | `git push` / `git pull` |
| 未提交的改动要换机器继续 | 提交到 WIP 分支再 push（见第 2 节） |
| 新 Mac 第一次拿到全部开发目录 | `mac-sync push <新机器>`（见第 3 节） |

**为什么不做双向同步**（2026-10-24 实测）：mac-sync 底层是 rsync，`-u` 只比较 mtime，也不传播删除，
多台机器互推时会静默丢数据：

- 同一文件两台都改了：mtime 晚的那份整个覆盖另一份，不合并、不提示。
- `git checkout -- f` / `git stash` / 切分支写出的旧内容带着当前 mtime，被当成「更新的」盖掉对端的真实改动。
- 删除或改名后，对端一推回来，文件就复活了。
- 两台各自 commit 后互推：`refs/heads/*` 按 mtime 定输赢，另一台的提交变成 dangling commit，`git log` 里看不到。

所以 `mac-sync push` 对**对端已存在的目录整个跳过、从不写入**，`pull` 和每 5 分钟定时互推的 LaunchAgent 已移除
（playbook 会删掉各机器上残留的 plist）。

其他设计原则：

1. **目录清单绝不进 Repo**：具体目录保存在各台机器本地的 `~/.config/mac-sync/dirs.list`，仓库只放机制与模板。
2. **抹平系统用户名差异**：Mac Studio 登录名为 `matstudio`，M5 与 M2 为 `matthew`；脚本与 Ansible 生成的
   `~/.ssh/config` 统一用 `~/<relative_path>` 寻址。
3. **初始化复制整份工作区**：包含 `.git`、未提交改动与被 gitignore 的本地文件（如 `.env`），新机器拿到即可用。
   全局过滤列表（`~/.config/mac-sync/exclude.list`）只拦构建产物与锁文件：
   `node_modules/`、`__pycache__/`、`.venv/`、`.terraform/`、`dist/`、`target/`、`.git/*.lock`。

---

## 2. 日常：换机器接力

离开当前机器前，把未提交的改动推到 WIP 分支：

```bash
git switch -c wip/<topic>
git add -A && git commit -m "wip: <topic>"
git push -u origin HEAD
```

到另一台机器上接着干：

```bash
git fetch origin
git switch wip/<topic>
```

注意：被 gitignore 的文件（`.env` 之类）和只在一台机器上新建的仓库不会随 git 走，前者手动 `scp`，后者在另一台 `git clone`。

查看当前机器身份、对端连通性与已配置目录的大小：

```bash
mac-sync status
```

---

## 3. 新机器加入（Add a new Mac）

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

### 步骤 4：把开发目录复制到新机器
在 M5 本机运行（按 M5 的 `dirs.list` 复制）：

```bash
mac-sync push new-mac
```

- 每个目录先传到对端的 `<dir>.mac-sync-partial`，传完才改名为 `<dir>`；中断了直接重跑同一条命令，会接着传。
- 新机器上已存在的目录整个跳过（输出 `⏭️ ... 已存在`），那些目录用 `git pull` 更新。
- 复制完成后，新机器就和其他机器一样只走 git（第 2 节），不要再对它 `mac-sync push`。

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
