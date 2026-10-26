# 两把 LiteLLM 虚拟 key 明文推上公开仓库：本地与 CI 两道 gitleaks 全绿

> 日期: 2026-10-26（10-26 17:38 推送，10-27 01:18 吊销；时刻均为 +08）
> 影响: `m2-magpie` / `studio-magpie` 两把 key 在公开仓库里挂了 7 小时 40 分。白名单含
>       `openrouter/*`（OpenRouter 余额为 0 也能调付费模型，见网关文档），所以这是真实的花费
>       敞口。spend log 实查两把 key **从生成起一次调用都没有**（含失败请求），没有被用过的迹象
> 根因: 三层同时漏：① agent 把 key 写成 playbook 的 vars 字面量（仓库惯例是 Vault 现取）；
>       ② 推送的那台没启用 pre-push 钩子，`just check` 根本没跑；③ 就算跑了也拦不住：
>       gitleaks 默认规则集认不出 LiteLLM 虚拟 key，CI 的 secret-scan 对这个提交是绿的
> 处置: LiteLLM 删两把 key、按原 alias 与白名单重发，新值只进 Vault；playbook 改从 Vault 现取；
>       `.gitleaks.toml` 加 `litellm-virtual-key` 规则；三台 Mac 的 clone 都启用钩子；
>       改写那一个提交（两串 key 换成 `***REMOVED***`）并 force push

## 经过

| 时刻 | 事件 |
|------|------|
| 10-26 15:25 | Antigravity CLI（agy）的会话用 master key 调 `/key/generate` 发了两把 key，`models` 含 `openrouter/*`、`nvidia/*`，无过期时间 |
| 15:39 | 同一会话应「对当前 repo 变更做合适的 commit」提交了 magpie playbook：两把 key 以字面量写在 `macbook/ansible/playbooks/magpie.yaml` 的 `vars.litellm_keys` 里 |
| 17:38 | 从 M5 推到 `origin/main`（`meirongdev/homelab`，**公开**）。12 秒后 CI 的 secret-scan 跑完：success |
| 10-27 凌晨 | 排查 magpie 接 agy 时读到这个文件，发现明文 key |
| 01:15 | 改写那个提交并 force push |
| 01:18 | 两把 key 在 LiteLLM 删除，之后拿它们调用一律 401 |
| 01:21 | 重发并写入 Vault；M2 随即 `just magpie` 换上新 key，`provider test` 通过 |
| 02:5x | Studio 的 magpie 不再卡死，`just magpie mac-studio` 换上新 key，`provider test` 通过 |

## 根因：三层各漏一次

**写法。**仓库里给 playbook 喂密钥的现成做法有两个（`just omlx`、`just multica-daemon`）：配方从
Vault 现取，经环境变量或 `-e` 传入，不进 git。这次的 playbook 没照做，直接写了字面量。

**本地那道没跑。**`.githooks/pre-push` 会在 push 前跑 `just check`（含 gitleaks），但钩子要每个
clone 自己 `git config core.hooksPath .githooks` 才生效，不启用也没有任何提示。事后查三台 Mac 的
clone（M5、M2、Studio）：**全都没启用**。`.gitleaks.toml` 与 `secret-scan.yml` 的注释都把
本地那道写成「真正的防线」，而它在每一台机器上都是空的。

**就算跑了也拦不住。**用仓库当时的配置对完整历史跑 `gitleaks git`：rc=0，零命中。LiteLLM 虚拟
key 是 `sk-` 加 22 位 base64url，没有 OpenAI key 那种固定标记；默认规则里能兜它的只有
generic-api-key，而那条要求同一行出现 key / token 一类的词。YAML 写成 `mbp-m2-pro: "sk-…"`，
整行一个都没有。

所以①不是靠第二、三层兜住的那种失误：后两层在这个仓库里对这类 key 从来就不存在。

## 处置

1. **吊销与重发。**按 `key_alias` 删掉两把（删前用 sha256 核对删的正是泄露的那两把），用同样的
   `key_alias`、`models`、`metadata` 重发。新值写进 Vault `secret/homelab/magpie`，字段名是
   inventory 主机名，过程中不在任何输出里出现原文。白名单没有收窄，含不含 `openrouter/*` 是另一个问题。
   ☠️ **删完拿 `key/info` 核验会被骗**：已删除的 key 照样返回 200 和完整信息（删后数分钟内反复
   实测），而它已经不在有效表里、也进了 `LiteLLM_DeletedVerificationToken`。核验要看
   `/key/list?key_alias=` 是否为空，或者直接拿旧 key 调用：两把都是 401。
2. **playbook 改从 Vault 取。**`just magpie` 把整份 JSON 经 `MAGPIE_LITELLM_KEYS` 传入，带 key 的任务
   `no_log`，取不到 key 时第一步就失败。顺带修了一个轮换必踩的坑：`magpie provider add homelab`
   换一把不同的 key **不报错，而是静默新建 `homelab-2`**，旧 key 原样留着（本地实测）。原写法重跑
   永远换不了 key，现在先 `provider key`，provider 不存在才 `add`。
3. **补规则。**`.gitleaks.toml` 加 `litellm-virtual-key`（`\bsk-[A-Za-z0-9_-]{22}\b`，熵 ≥ 3.5）。改写历史前
   对全部 1400+ 个提交只命中这两把，零误报；同格式的新 key 能抓到（`gitleaks stdin` 实测）。
4. **启用钩子。**M5、M2、Studio 三个 clone 都设了 `core.hooksPath`。M2 与 Studio 是 herdr 派活的
   agent 主机，也会往这个仓库推。
5. **改写历史。**泄露的提交正好是 `main` 的最新一个，所以只重建了它：两串 key 换成 `***REMOVED***`，
   作者、时间、提交信息不变，`--force-with-lease` 推上去。本地没用 `git filter-repo`：它收尾会过期
   **全部** reflog、去掉 origin，波及无关分支与 stash；这里只删了引用旧提交的两条 reflog 再 gc，
   本地已取不到旧提交和那个 blob。
   M2、Studio 的 clone 从没拉到过它，tag 与唯一的 fork 也都不含它。

⚠️ **改写只是清理，不是补救。**key 公开过 7 小时 40 分，期间谁都可能拉走。改写后实测：GitHub 仍按
SHA 返回旧提交和那个 blob，经 fork 的仓库地址也能取到（fork 网络共享对象）。挂在旧提交上的 4 条
CI 运行记录已删。**没有找 GitHub Support 清缓存**：官方文档写明只在「轮换凭据消除不了风险」时才
处理，而这两把已吊销。真正让 key 失效的只有第 1 条。

## 留下的

- 钩子仍然要每个 clone 手动启用，新机器、新 clone 会再次是空的。启用步骤在
  [dev-machine-bootstrap.md](../guides/dev-machine-bootstrap.md)，但这次说明「写在指南里」挡不住。
- Studio 上的 magpie 自 10-26 15:28 起所有状态命令都卡死（探测已装 agent 时一次 `open()` 不返回），
  10-26 那次 playbook 因此挂了 9 小时。挂着的进程全部退出后（M5 上的孤儿 playbook 被结束，ssh 断开，
  远端收到 SIGHUP）现象消失，用真实 HOME 跑只要 0.6s。**根因没查实**：排除了 OrbStack 的 NFS 挂载
  （它也确实挂死了，但与此无关），只缩到 `~/Library`；最像的是 ssh 下触发的 macOS 隐私授权弹窗没人
  应答，读不了 TCC 库无法证实。再卡住时 playbook 有 `timeout` 兜着，不会再挂几个小时。
- 排查时的一个误判，记下以免再犯：`perl -e 'alarm N; exec …'` 给 Go 程序设不了超时，Go 运行时会
  捕获并**忽略** SIGALRM，进程照样跑下去，不能据此推断「卡在不可中断的系统调用里」。远端探测用
  `ssh -tt` 加本地超时，ssh 一断远端就收到 SIGHUP（Go 收到 SIGHUP 会退出）。
