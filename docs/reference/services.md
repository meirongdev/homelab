# Services — 服务清单

> Last updated: 2026-08-06
> Status: 生效事实
>
> **这张表是服务清单的唯一真相源** —— `docs/README.md`、`docs/ARCHITECTURE.md` 与各 runbook
> 只链接到这里，不要再复制副本（复制过，三份各自漂移了）。
> 核对方式: `kubectl --context <ctx> get httproute -A`。

| Service | Cluster | Namespace | URL |
|---------|---------|-----------|-----|
| Homepage | oracle-k3s | `homepage` | `home.meirong.dev` |
| IT-Tools | oracle-k3s | `personal-services` | `tool.meirong.dev` |
| Stirling-PDF | oracle-k3s | `personal-services` | `pdf.meirong.dev` |
| Squoosh | oracle-k3s | `personal-services` | `squoosh.meirong.dev` |
| Excalidraw | oracle-k3s | `personal-services` | `draw.meirong.dev`（无认证，2026-08-04 去掉 oauth2-proxy） |
| Trends | oracle-k3s | `personal-services` | `trends.meirong.dev` |
| readlist (技术书评分/书单) | oracle-k3s | `personal-services` | `readlist.meirong.dev`（2026-08-05 上线；3 个夜间 CronJob，snapshot 读 calibre 两库，见 [runbooks/readlist-bootstrap.md](../runbooks/readlist-bootstrap.md)） |
| Timeslot | oracle-k3s | `personal-services` | `slot.meirong.dev` |
| Uptime Kuma | oracle-k3s | `personal-services` | `status.meirong.dev` |
| Miniflux | oracle-k3s | `rss-system` | `rss.meirong.dev` |
| KaraKeep | oracle-k3s | `rss-system` | `keep.meirong.dev` |
| RSSHub (+browserless/redis) | oracle-k3s | `rss-system` | Internal only |
| Redpanda Connect | oracle-k3s | `rss-system` | Internal only |
| Calibre-Web | **oracle-k3s** | `personal-services` | `book.meirong.dev`（2026-08-03 迁移） |
| Open Notebook (AI 研读) | homelab | `personal-services` | `notebook.meirong.dev`（模型走 DGX + Mac OMLX，见 [open-notebook.md](open-notebook.md)） |
| jobs-sg (SG 岗位周报) | homelab | `jobs-sg` | `jobs.meirong.dev`（2026-08-03 上线；独立 ns + 3 个 CronJob，见 [jobs-sg.md](jobs-sg.md)） |
| Grafana | homelab | `monitoring` | `grafana.meirong.dev` |
| HashiCorp Vault | homelab | `vault` | `vault.meirong.dev` |
| ArgoCD | **oracle-k3s** | `argocd` | `argocd.meirong.dev`（2026-08-02 控制面迁 oracle，经 Tailscale 纳管 homelab） |
| ZITADEL (SSO) | oracle-k3s | `zitadel` | `auth.meirong.dev` |
| PostgreSQL (`apps-pg`, CNPG 共享应用库) | oracle-k3s | `databases` | Internal only（2026-08-06 取代手搓的 `rss-postgres`；当前租户只有 miniflux。加库见 [decisions/shared-postgres-platform.md](../decisions/shared-postgres-platform.md)） |
| PostgreSQL (`zitadel-pg`, CNPG) | oracle-k3s | `zitadel` | Internal only（身份面**刻意独立**，不并入 `apps-pg`） |

## 运维备忘（按服务）

- **Homepage 配置更新**: 配置 ConfigMap 用 `subPath` 挂载、**不会热加载** —— `git push` 让 ArgoCD
  同步 ConfigMap 后，必须 `kubectl --context oracle-k3s rollout restart deployment/homepage -n homepage`
  才生效。不要 `kubectl delete configmap`（会和 ArgoCD 冲突）。
  判据（2026-08-08 拆 bifrost 时实踩）：ConfigMap 已是新版但 UI 还显示旧磁贴时，**先别改清单**——
  ① `kubectl --context oracle-k3s get cm homepage-config -n homepage -o jsonpath='{.data.services.yaml}'`
  确认内容已更新；② 再看运行中 Pod 的挂载 `kubectl --context oracle-k3s exec -n homepage deploy/homepage
  -- grep -ri <关键词> /app/config/`；subPath 会让 ① 与 ② 不一致，属正常——以 `rollout restart` 收尾。
- **Uptime Kuma monitors**: 全部声明式定义在 `cloud/oracle/manifests/uptime-kuma/provisioner.yaml`
  的 `uptime-kuma-provisioner` ConfigMap 的 `MONITORS` 列表（oracle 本地服务用集群内 Service URL，
  homelab 服务用公网 URL）。`git push` → ArgoCD PostSync hook 自动重跑 provisioner Job；
  幂等 + **声明式 prune** —— 不在 `MONITORS` 里的 monitor 会被删除，从列表摘掉一条就是退役它
  （不会在状态页留一个永久红的孤儿）。Admin 凭据 Vault `secret/oracle-k3s/uptime-kuma`
  （keys: `admin_username`/`admin_password`）→ ESO `uptime-kuma-admin`（`personal-services` ns）。

新增服务的完整流程（manifest → HTTPRoute → homepage → monitor）见 skill
`.claude/skills/add-service/SKILL.md`；「写 HTTPRoute 即建 DNS」的机制见
[networking-ingress.md](networking-ingress.md)。
