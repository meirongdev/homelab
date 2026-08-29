# Services — 服务清单

> Last updated: 2026-08-29
> Status: 生效事实
>
> **这张表是服务清单的唯一真相源** —— `docs/README.md`、`docs/ARCHITECTURE.md` 与各 runbook
> 只链接到这里，不要再复制副本（复制过，三份各自漂移了）。
> 核对方式: `kubectl --context <ctx> get httproute -A`。
>
> 表格只回答**「有什么、在哪」**，一行一眼看完；带 ⚠️/☠️ 的服务另有
> [运维备忘](#运维备忘按服务) 段落展开。

| Service | Cluster | Namespace | URL | 备注 |
|---------|---------|-----------|-----|------|
| Homepage | oracle-k3s | `homepage` | `home.meirong.dev` | ⚠️ 配置不热加载，见备忘 |
| IT-Tools | oracle-k3s | `personal-services` | `tool.meirong.dev` | |
| BentoPDF | oracle-k3s | `personal-services` | `pdf.meirong.dev` | **无认证，人人可用**；2026-08-11 取代 Stirling-PDF。纯客户端 WASM，服务端只是 nginx 静态站、零状态无 PVC |
| Squoosh | oracle-k3s | `personal-services` | `squoosh.meirong.dev` | |
| Excalidraw | oracle-k3s | `personal-services` | `draw.meirong.dev` | 无认证（2026-08-04 去掉 oauth2-proxy） |
| Trends | oracle-k3s | `personal-services` | `trends.meirong.dev` | |
| readlist (技术书评分/书单) | oracle-k3s | `personal-services` | `readlist.meirong.dev` | 2026-08-05 上线；3 个夜间 CronJob，snapshot 读 calibre 两库（[bootstrap](../runbooks/readlist-bootstrap.md)） |
| Timeslot | oracle-k3s | `personal-services` | `slot.meirong.dev` | |
| Uptime Kuma | oracle-k3s | `personal-services` | `status.meirong.dev` | ⚠️ monitor 声明式管理，见备忘 |
| Miniflux | oracle-k3s | `rss-system` | `rss.meirong.dev` | |
| RSSHub (+browserless/redis) | oracle-k3s | `rss-system` | Internal only | |
| Calibre-Web | **oracle-k3s** | `personal-services` | `book.meirong.dev` | 2026-08-03 迁移 |
| Open Notebook (AI 研读) | homelab | `personal-services` | `notebook.meirong.dev` | 模型走 DGX + Mac OMLX（[open-notebook.md](open-notebook.md)） |
| Multica (AI 编码 agent 协作台) | homelab | `personal-services` | `multica.meirong.dev` | ☠️ **服务是两半的**，daemon 在 MacBook 上；另有 `/` 重定向坑 —— 见备忘 |
| LiteLLM (LLM 网关) | homelab | `litellm` | `llm.meirong.dev` | inference API + 自带认证 admin UI `/ui`；DGX 主 + Mac 兜底。运维事实与坑见 [litellm-gateway.md](litellm-gateway.md) |
| Nakama (游戏后端) | homelab | `personal-services` | `nakama.meirong.dev` + `nakama-console.meirong.dev` | ☠️ 控制台裸挂公网、只有自带口令 —— 见备忘 |
| 家庭游戏大厅 (Godot Web) | homelab | `personal-services` | `game.meirong.dev` | ☠️ 这个域名下**还挂着 Nakama 的 API**，路由少两条游戏就打不开 —— 见备忘 |
| jobs-sg (SG 岗位周报) | homelab | `jobs-sg` | `jobs.meirong.dev` | 2026-08-03 上线；独立 ns + 3 个 CronJob（[jobs-sg.md](jobs-sg.md)） |
| Jellyfin (视频) | homelab | `media` | `media.meirong.dev` | 2026-08-16；媒体读 106 只读 NFS，config 走 local-path（[OIDC 接入中](identity.md#jellyfin)） |
| Navidrome (音乐) | homelab | `media` | `music.meirong.dev` | 2026-08-16；媒体读 106 只读 NFS，DB 走 local-path |
| Podcast (自录 RSS 发布) | homelab | `media` | `podcast.meirong.dev` | 2026-08-16；nginx 伺服 106 只读 NFS 的 mp3 + rss.xml |
| Grafana | homelab | `monitoring` | `grafana.meirong.dev` | |
| HashiCorp Vault | homelab | `vault` | `vault.meirong.dev` | |
| ArgoCD | **oracle-k3s** | `argocd` | `argocd.meirong.dev` | 2026-08-02 控制面迁 oracle，经 Tailscale 纳管 homelab |
| ZITADEL (SSO) | oracle-k3s | `zitadel` | `auth.meirong.dev` | |
| PostgreSQL (`apps-pg`, CNPG 共享应用库) | oracle-k3s | `databases` | Internal only | 2026-08-06 取代手搓的 `rss-postgres`；当前租户只有 miniflux。加库见 [决策](../decisions/shared-postgres-platform.md) |
| PostgreSQL (`zitadel-pg`, CNPG) | oracle-k3s | `zitadel` | Internal only | 身份面**刻意独立**，不并入 `apps-pg` |
| PostgreSQL (`apps-pg`, 共享应用库) | **homelab** | `databases` | Internal only | ☠️ 与 oracle 那个**同名同角色但形态不同** —— 见备忘 |

## 集群外托管的 meirong.dev 站点

> `stack.meirong.dev` 与本仓库的分工（谁拥有 DNS / WAF / 凭据 / 监控）见
> [decisions/home-stack-repo-boundary.md](../decisions/home-stack-repo-boundary.md)。

⚠️ 这三个**不在**上表里，也查不到 HTTPRoute（`kubectl get httproute` 核对不到不等于没上线），
但它们占着 `meirong.dev` 的主机名、且在 Homepage 上有磁贴。机制与注意事项（GitHub Pages 必须
DNS-only、绕过 WAF、DNS 通了≠站点通了）见
[networking-ingress.md](networking-ingress.md#不走这条链的-meirongdev-主机名集群外托管)。

✅ **可用性监控 2026-08-23 补齐**（此前三个都没有，即"站点挂了没人知道"）：oracle 的
uptime-kuma provisioner 的 `MONITORS` 里各一条 HTTP 探测，并自动进 `status.meirong.dev`
状态页。⚠️ **它们不是集群存活信号** —— 三条全绿只说明外部托管与 DNS 还在，
dead-man's switch 仍只认 Grafana/Vault/Open Notebook 那组。

| 站点 | 托管 | URL |
|------|------|-----|
| Blog | Cloudflare Pages (`meirongdevblog.pages.dev`) | `meirong.dev`（apex） |
| Playgrounds（各语言官方在线 Playground 导航） | GitHub Pages，repo `meirongdev/playgrounds` | `playgrounds.meirong.dev`（2026-08-13 接域名；DNS 记录在 `cloudflare/terraform` 的 `local.external_origin_dns`） |
| Home Stack（homelab 自托管技术选型目录，97 条） | Cloudflare Workers（Rust→wasm SSR + 静态资源层），repo `meirongdev/home-stack` | `stack.meirong.dev`（2026-08-23 上线；DNS 记录由 Workers 自定义域名**自建**，声明在 home-stack 仓库的 terraform，**不在本仓库 state 里**） |

## 运维备忘（按服务）

### Homepage — 配置不热加载

配置 ConfigMap 用 `subPath` 挂载，**不会热加载** —— `git push` 让 ArgoCD 同步 ConfigMap 后，
必须 `kubectl --context oracle-k3s rollout restart deployment/homepage -n homepage` 才生效。
不要 `kubectl delete configmap`（会和 ArgoCD 冲突）。

判据（2026-08-08 拆服务时实踩）：ConfigMap 已是新版但 UI 还显示旧磁贴时，**先别改清单** ——

```bash
# ① 确认 ConfigMap 内容已更新
kubectl --context oracle-k3s get cm homepage-config -n homepage -o jsonpath='{.data.services.yaml}'
# ② 再看运行中 Pod 的挂载
kubectl --context oracle-k3s exec -n homepage deploy/homepage -- grep -ri <关键词> /app/config/
```

subPath 会让 ① 与 ② 不一致，属正常 —— 以 `rollout restart` 收尾。

### Uptime Kuma — monitor 声明式管理

全部 monitor 定义在 `cloud/oracle/manifests/uptime-kuma/provisioner.yaml` 的
`uptime-kuma-provisioner` ConfigMap 的 `MONITORS` 列表（oracle 本地服务用集群内 Service URL，
homelab 服务用公网 URL）。`git push` → ArgoCD PostSync hook 自动重跑 provisioner Job。

幂等 + **声明式 prune** —— 不在 `MONITORS` 里的 monitor 会被删除，从列表摘掉一条就是退役它
（不会在状态页留一个永久红的孤儿）。Admin 凭据 Vault `secret/oracle-k3s/uptime-kuma`
（keys: `admin_username`/`admin_password`）→ ESO `uptime-kuma-admin`（`personal-services` ns）。

⚠️ **provisioner 有个静默滞后 bug（2026-08-23 修）**：`add_monitor()` 之后 `get_monitors()`
**看不见**刚建的监控（客户端列表靠服务端推事件填），于是状态页的 `publicGroupList`
**落后一次运行** —— 监控确实建成、告警也会响，可公开状态页上一条都没有，而日志三条全绿、
ArgoCD hook 报 Succeeded，无处可查。现已改为「等所有声明的监控都出现在服务端返回里再存
状态页」，等不到则响亮警告但**不失败**（这是 PostSync hook，失败会连累整个 App 的 sync）。

### Multica — 服务是两半的

☠️ **这里只有 service 端，执行任务的 daemon 跑在 M2 MacBook 上** —— daemon 离线时页面照常
200、Uptime Kuma 全绿、任务静默堆积。安装/重建见 [runbooks/multica-install.md](../runbooks/multica-install.md)。

2026-08-18 上线；官方 OCI Helm chart，本仓库**唯一** OCI chart 源。

☠️ `/` 由网关 302 到 `/homelab/issues` —— 上游在 `/` 服务的是 SaaS 营销页，
chart / feature_flags / 前端 middleware 三处都没有关掉它的开关，只能在 HTTPRoute 层截。
该 302 由 Envoy 就地应答**不经过 pod**，故 Uptime Kuma 探的是 `/api/config`。

### Nakama — 管理台裸挂公网

客户端 API 走 7350（HTTP+WebSocket），内嵌管理控制台走 7351。2026-08-25 上线；
**无 PVC**，状态全在共享 Postgres `apps-pg` 的 `nakama` 租户。

⚠️ `nakama.meirong.dev` 用浏览器打开是**空白页**（`GET /` 返回 200 + `content-length: 0`）
—— 它是 API，不是网页；给人看的入口是 `game.meirong.dev`。⚠️ 7349 的 gRPC API 没暴露。

☠️ **控制台是公网可达的管理面且只有自带口令、没接 ZITADEL** —— 能删账号/改数据/跑任意 RPC，
风险靠 32 字节随机口令压住，**有意接受**（要收紧就在那条 HTTPRoute 前加 oauth2-proxy）。
已记入 [security.md 已知缺口](security.md)。

**游戏逻辑（服务端 Lua）来自另一个仓库** `meirongdev/godot-games`，由 initContainer 从 OCI
镜像拷进 `/nakama/data/modules`，发版 = 换 tag。`runtime.lua_{min,max}_count` 已按上游契约
设成 1/4 —— **两个必须成对**，`min` 默认 16 且校验 `min<=max`，只调 max 直接启动失败。

### 家庭游戏大厅 (Godot Web) — 域名下还挂着 Nakama 的 API

静态 Godot 4 Web 导出 + `nginx-unprivileged:8080`（`/healthz` 探活）。**无状态无 PVC**，
游戏状态全在 Nakama。镜像与游戏源码在 `meirongdev/godot-games`
（[部署契约](https://github.com/meirongdev/godot-games/blob/main/docs/deployment-contract.md)），
本仓库只拥有域名/限额/落点。

☠️ Web 客户端从页面自身来源推导服务器地址（镜像里零环境事实），所以 `game.meirong.dev` 的
HTTPRoute 有**三条**规则 —— `/v2/*` 与 `/ws` 打到 `nakama:7350`，其余给静态站。
**少了那两条游戏就是打不开**，而上游 e2e 工具直连 `nakama.meirong.dev:443`、结构上绕过它们，
**e2e 全绿也证明不了网页能玩** —— 唯一判据是用浏览器真开一次（含"看得见中文"）。

上游有个自动化替身可以直接打线上：

```bash
NAKAMA_HOST=game.meirong.dev NAKAMA_PORT=443 NAKAMA_TLS=1 \
  python3 tools/web_smoke.py https://game.meirong.dev
```

☠️ **那三个环境变量不是可选的**：脚本要先用 `e2e_match` 建一个"别人的房"供浏览器点，而
`e2e_match` 的 `NAKAMA_HOST` 默认是 `127.0.0.1:7350` —— 漏了就把房建到**本机 compose** 上，
浏览器在线上列表里永远看不到它，报「房间列表里没有『别人的房…』这一行」，看着像线上路由/
房间列表坏了（2026-08-28 实测误判过一次；补上后两档全绿）。

⚠️ **必须无头或让标签页可见** —— Chrome 对隐藏标签不跑 `requestAnimationFrame`，而 Godot
主循环挂在 rAF 上，标签一隐藏引擎就不转，任何等待都超时，看着像服务端卡住。

⚠️ server key 是**公开常量** `family-lobby-2026`（跟着 web 制品发布），刻意放在 git 里而不是
Vault：它必须与上游 `NakamaConfig.SERVER_KEY` 一致，放 Vault 会让这个一致性看不见。

### homelab 的 `apps-pg` — 与 oracle 同名但形态不同

2026-08-25 合并 `litellm-pg` + `multica-postgres` 而来，租户 litellm / multica。

☠️ **与 oracle 那个同名同角色但形态不同**：这边是**裸 Deployment**，加租户 = 改 initdb 脚本
+ 手工建库 + 备份脚本加一行，**不是** `Database` CR。homelab 刻意不装 CNPG（operator 自身
实测开销比省下的 postmaster 还贵），理由见
[decisions/shared-postgres-platform.md](../decisions/shared-postgres-platform.md) 决策四。

---

新增服务的完整流程（manifest → HTTPRoute → homepage → monitor）见 skill
`.claude/skills/add-service/SKILL.md`；「写 HTTPRoute 即建 DNS」的机制见
[networking-ingress.md](networking-ingress.md)。
