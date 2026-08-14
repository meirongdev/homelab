# Identity — ZITADEL / OIDC 接入

> Last updated: 2026-08-11
> Status: 生效事实
>
> 身份面的部署形态与各应用接入细节。安全视角的摘要在 [security.md §3](security.md)；
> 入口层共享 SSO 为何被移除见 [../plans/security/2026-03-08-cilium-zitadel-sso-plan.md](../plans/security/2026-03-08-cilium-zitadel-sso-plan.md)。

## 当前模型

- **单一 IdP**: ZITADEL，`auth.meirong.dev`。**没有共享入口层 SSO**（Traefik ForwardAuth /
  全局 oauth2-proxy 链已移除——省掉每个请求的第二跳认证）。每个服务三选一：
  **公开**、**原生 ZITADEL OIDC**、或**自带认证**（如 Vault、Timeslot admin Basic Auth）。
- **方向约定**: `HTTPRoute` 保持 controller-neutral，认证放应用层。优先原生 OIDC；
  应用不会说 OIDC 时才用 per-app `oauth2-proxy` 反代（当前**无实例**：Excalidraw 那个
  2026-08-04 拆了，Bifrost 2026-08-08 退役）。

## ZITADEL 部署形态（oracle-k3s）

- **✅ 2026-07-06 迁至 oracle-k3s**: ZITADEL v4.10.1 + Login V2（`zitadel-login` pod）跑在
  `cloud/oracle/manifests/zitadel/`。masterkey 沿用同一个 `secret/homelab/zitadel`，
  签名密钥/OIDC token 全程有效，切换对 OIDC client 无感。homelab 侧 ZITADEL 已彻底退役。
- **⚠️ Cilium `enable-gateway-api-app-protocol: true` 是硬前提**（`cloud/oracle/values/cilium-values.yaml`）：
  没有它 console 的 v1 gRPC（auth.v1/admin.v1）过网关 404。踩坑记录
  [../records/2026-06-07-zitadel-console-grpc-404.md](../records/2026-06-07-zitadel-console-grpc-404.md)。
- **部署机制是 k3s `HelmChart` CR，不是 ArgoCD Helm App**: 改 `valuesContent` → git push →
  ArgoCD 同步 CR → k3s helm-controller 重跑 `helm upgrade`。ArgoCD 只追踪 `HelmChart` CR 本身，
  所以手动 scale 其子 Deployment **不会**被 selfHeal 拉回。
- **不入 git 的 bootstrap 依赖**: `zitadel` ns 里的 `login-client` Secret（Login V2 PAT）——
  setup job 在已恢复的 DB 上**不会**重建它，重建集群时要从备份拷入
  （见 `cloud/oracle/manifests/kustomization.yaml` 头注 + [oracle-k3s-rebuild runbook](../runbooks/oracle-k3s-rebuild.md)）。

### DB: CloudNativePG（2026-07-18 起）

- CNPG `Cluster` CR **`zitadel-pg`**（PG 17.6，单实例，Service `zitadel-pg-rw`，`zitadel` ns）；
  operator 来自 ArgoCD `cnpg-operator` App（chart `cloudnative-pg` 0.29.0，**必须与 Cluster CR 同集群**）。
  凭据复用 Vault `secret/homelab/zitadel` 的 `db-password`（app 用户与 superuser 同密码——单租户 DB，刻意）。
  迁移前最后一份 dump 在仓库外 `~/backups/zitadel-migration/`。
- ⚠️ **CNPG pod 是 `readOnlyRootFilesystem: true`** —— `/tmp` 不可写。临时文件放 `/controller`
  （可写 emptyDir）或 pgdata 下（2026-07-31 实测：`touch /tmp/x` → Read-only file system）。
- ⚠️ **备份容器的 `pg_dump` 版本必须 ≥ 服务端**——client 16 拒绝 dump PG 17。
  这就是 `backup/base/cronjob.yaml` pin `alpine:3.22`（带 `postgresql17-client`）的原因。

## 原生 ZITADEL OIDC 应用

**Grafana** (`grafana`) / **Miniflux** (`rss`) /
**ArgoCD** (`argocd`) 直连 OIDC。共同点：

> 2026-08-11：**Stirling-PDF (`pdf`) 已退役**，接替它的 BentoPDF 是纯客户端应用、
> 刻意不做权限管理（人人可用），因此 ZITADEL 侧的 `stirling-pdf` 应用与
> Vault `secret/oracle-k3s/stirling-pdf` 一并删除。
>
> 2026-08-14：**KaraKeep (`keep`) 已退役**——Miniflux→KaraKeep 书签管道整体下线
> （实测近 7d 零 webhook 流量、SQLite 仅 564K，用户确认不需要）。ZITADEL 侧的
> `karakeep` 应用与 Vault `secret/oracle-k3s/karakeep`、`secret/oracle-k3s/redpanda-connect`
> 已一并删除。

- 各自的机密 WEB client 由 `zitadel/scripts/configure-oidc-app.sh` **幂等**下发
  （REST 而非 Terraform，原因见下「配置脚本为何走 REST」）。
- creds 放 Vault 应用自己的 path（`secret/homelab/{grafana,argocd-oidc}`、
  `secret/oracle-k3s/miniflux`，keys `oauth_client_id`/`oauth_client_secret`）
  → ESO → 应用的 K8s Secret。
- **各应用本地账号密码登录保留为后备**（无锁死风险）。
- Redirect URIs: Grafana `…/login/generic_oauth`、Miniflux `…/oauth2/oidc/callback`、
  ArgoCD `…/auth/callback`（+ CLI 用的 `http://localhost:8085/auth/callback`）。

各应用要点：

- **部署路径不同**: Grafana → 改 `values/kube-prometheus-stack.yaml` → git push（ArgoCD
  `kube-prometheus-stack` App）；ArgoCD 本体 → `just deploy-argocd`（写完 Vault 后跑）；
  Miniflux 与 ArgoCD 的 `argocd-oidc` ExternalSecret 都随 git push 由
  ArgoCD 调和（分别经 `oracle-k3s` 与 `vault-eso` App）。
- **Grafana**: `role_attribute_path: "'Admin'"` —— 任何 ZITADEL 认证过的身份都是 Admin
  （单用户 + 注册锁死的 IdP 下安全）。
- **Miniflux**: `OAUTH2_USER_CREATION=1` 首次 SSO 登录自动建号；要保住 admin 权限，
  先用本地 admin 登录、在 Settings 里链接 OIDC 身份。
- **ArgoCD**: dex 保持禁用——原生 `configs.cm.oidc.config`，`clientID/clientSecret:
  $argocd-oidc:oidc.client*` 从带 `app.kubernetes.io/part-of=argocd` label 的 ESO secret 解析
  （与 chart 管的 `argocd-secret` 分开）。`rbac.policy.default: role:admin`。
  **Gotcha**: 改 `oidc.config` 只热更 ConfigMap——必须 `rollout restart` `argocd-server`，
  否则首次 SSO 登录 500 `Initializing OIDC provider (issuer: )`。Helm 4（默认 SSA）下
  `just deploy-argocd` 曾需一次性 `--force-conflicts` 从残留的 `kubectl-patch` manager
  手里接过 `gateway` 健康检查字段。

## 无法直连 OIDC 的应用：per-app oauth2-proxy

**Bifrost** 曾是样板（OSS admin UI / config-API 无认证 → per-app `oauth2-proxy` 反代 +
ZITADEL OIDC；推理 API 直连 + virtual key 把关），**2026-08-08 已随整个 `bifrost`
ArgoCD App 退役**。`zitadel/scripts/configure-bifrost-oauth.sh` 与 Vault
`secret/homelab/bifrost-oauth2-proxy` 已无消费者（保留作历史）。

**Excalidraw**（`draw`）曾用同模式，**2026-08-04 移除**：画布只存浏览器 localStorage、服务端
无状态，那层 SSO 保护不了任何东西，只是登录摩擦；现在 HTTPRoute 直接分流到前端与协作 room，
和同 ns 的 IT-Tools/Squoosh 一样公开。ZITADEL 应用与 Vault `secret/oracle-k3s/excalidraw-oauth2-proxy`
已一并清理。

## GitHub 社交登录（联邦 IdP）

- GitHub 加为 ZITADEL **instance 级外部 IdP** —— 所有 ZITADEL-OIDC 应用自动获得
  "Sign in with GitHub" 按钮，ZITADEL 仍是唯一 IdP。由 `zitadel/scripts/configure-github-idp.sh` 下发。
- **锁死注册**: `isCreationAllowed/isAutoCreation=false`、`autoLinking=AUTO_LINKING_OPTION_EMAIL`
  —— 陌生 GitHub 账号无法自助注册；GitHub 身份只能按**已验证邮箱**链接到既有 ZITADEL 用户。
  当前链接: `zitadel-admin` ↔ GitHub `meirongdev`（extUserId `137514603`）。
- **Gotchas**:
  1. 本实例跑 **Login V2**，IdP 回调是 `https://auth.meirong.dev/idps/callback` ——
     **不是** v1 的 `/ui/login/login/externalidp/callback`；GitHub OAuth App 的
     Authorization callback URL 必须精确一致。
  2. ZITADEL 只读 GitHub 的**公开**邮箱：首次邮箱自动链接时 GitHub 邮箱必须设为公开；
     链接成功后按 GitHub user ID 匹配，邮箱可改回私密。

## 配置脚本为何走 REST 而非 Terraform

`zitadel/scripts/*.sh`（OIDC 应用、Bifrost OAuth、GitHub IdP、SMTP）统一用 REST API 幂等下发：
**Terraform/gRPC 的写操作过 Cloudflare edge 会坏**，而这些脚本从任何机器经公网 `auth.meirong.dev`
都能跑。`zitadel/terraform/` 仅用于 bootstrap 期的用户/项目/客户端。
