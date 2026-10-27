# Identity — ZITADEL / OIDC 接入

> Last updated: 2026-10-28
> Status: 生效事实
>
> 身份面的部署形态与各应用接入细节。安全视角的摘要在 [security.md §3](security.md)；
> 入口层共享 SSO 为何被移除见 [../plans/2026-03-08-cilium-zitadel-sso-plan.md](../plans/2026-03-08-cilium-zitadel-sso-plan.md)。

## 当前模型

- **单一 IdP**：ZITADEL `auth.meirong.dev`（oracle-k3s）。**没有共享入口层 SSO**（省掉每个请求的第二跳认证），
  `HTTPRoute` 保持 controller-neutral，认证放应用层。每个服务三选一：公开、原生 ZITADEL OIDC、
  自带认证（如 Vault、LiteLLM `/ui`、Timeslot admin Basic Auth）。不会说 OIDC 的应用才用
  [per-app oauth2-proxy](#无法直连-oidc-的应用per-app-oauth2-proxy)（当前无实例）。
- **刻意公开**：BentoPDF（`pdf`，纯客户端）与 Excalidraw（`draw`，画布只存浏览器 localStorage，
  套 SSO 保护不了任何东西，只添登录摩擦）。

## ZITADEL 部署形态（oracle-k3s）

- ZITADEL + Login V2（`zitadel-login` pod），清单在 `cloud/oracle/manifests/zitadel/`（ArgoCD
  `oracle-zitadel` App），chart 版本看 `zitadel.yaml` 里 HelmChart 的 `version`。masterkey 与 DB 密码
  仍在 `secret/homelab/zitadel`（从 homelab 迁来时沿用，没改成 `oracle-k3s/` 路径）。
- ⚠️ **Cilium `gatewayAPI.enableAppProtocol: true` 是硬前提**（`cloud/oracle/values/cilium.yaml`，
  即 cilium-config 的 `enable-gateway-api-app-protocol`）：没有它 console 的 v1 gRPC（auth.v1/admin.v1）
  过网关 404 → [../records/2026-06-07-zitadel-console-grpc-404.md](../records/2026-06-07-zitadel-console-grpc-404.md)。
- **部署机制是 k3s `HelmChart` CR，不是 ArgoCD Helm App**：改 `valuesContent` → git push →
  ArgoCD 同步 CR → k3s helm-controller 跑 `helm upgrade`。ArgoCD 只追踪 `HelmChart` CR 本身，
  所以手动 scale 其子 Deployment 不会被 selfHeal 拉回。
- **不入 git 的 bootstrap 依赖**：`zitadel` ns 里的 `login-client` Secret（Login V2 PAT）。
  setup job 在已恢复的 DB 上不会重建它，重建集群时要从备份拷入
  （`cloud/oracle/manifests/kustomization.yaml` 的 ZITADEL 注释 + [oracle-k3s-rebuild runbook](../runbooks/oracle-k3s-rebuild.md)）。

### DB: CloudNativePG

- CNPG `Cluster` CR `zitadel-pg`（单实例，Service `zitadel-pg-rw`，`zitadel` ns；PG 镜像钉在
  `zitadel-pg-cluster.yaml` 的 `imageName`）。operator 来自 ArgoCD `cnpg-operator` App（chart
  `cloudnative-pg`，版本看其 `targetRevision`），**必须与 Cluster CR 同集群**。
- 凭据复用 `secret/homelab/zitadel` 的 `db-password`（app 用户与 superuser 同密码，单租户 DB，刻意）。
  迁 CNPG 前最后一份 dump 在仓库外 `~/backups/zitadel-migration/`。
- ⚠️ **CNPG pod 是 `readOnlyRootFilesystem: true`**，`/tmp` 不可写（`touch /tmp/x` → Read-only file system）。
  临时文件放 `/controller`（可写 emptyDir）或 pgdata 下。
- ⚠️ **备份容器的 `pg_dump` 版本必须 ≥ 服务端**：client 16 拒绝 dump PG 17。所以
  `backup/base/cronjob.yaml` 钉 `alpine:3.22`（带 `postgresql17-client`）。

## 原生 ZITADEL OIDC 应用

**Grafana**（`grafana`）/ **Miniflux**（`rss`）/ **ArgoCD**（`argocd`）直连 OIDC；Jellyfin 走插件，见[下节](#jellyfin)。共同点：

- 各自的机密 WEB client 由 `zitadel/scripts/configure-oidc-app.sh` 幂等下发（为何不用 Terraform 见末节）。
- creds 放 Vault 应用自己的 path（`secret/homelab/{grafana,argocd-oidc}`、`secret/oracle-k3s/miniflux`，
  keys `oauth_client_id`/`oauth_client_secret`）→ ESO → 应用的 K8s Secret。
- **各应用本地账号密码登录保留为后备**（无锁死风险）。
- Redirect URIs：Grafana `…/login/generic_oauth`、Miniflux `…/oauth2/oidc/callback`、
  ArgoCD `…/auth/callback`（+ CLI 用的 `http://localhost:8085/auth/callback`）。

各应用要点：

- **部署路径不同**：Grafana → 改 `k8s/helm/values/kube-prometheus-stack.yaml` → git push（`kube-prometheus-stack` App）；
  ArgoCD 本体是 manual-helm → 写完 Vault 后 `cd k8s/helm && just deploy-argocd`；Miniflux（`oracle-rss` App）
  与 `argocd-oidc` ExternalSecret（`cloud/oracle/manifests/argocd/`，`oracle-k3s` App）随 git push 由 ArgoCD 调和。
- **Grafana**：`role_attribute_path: "'Admin'"`，任何 ZITADEL 认证过的身份都是 Admin（单用户 + 注册锁死的 IdP 下安全）。
- **Miniflux**：`OAUTH2_USER_CREATION=1` 首次 SSO 登录自动建号；要保住 admin 权限，先用本地 admin 登录、
  在 Settings 里链接 OIDC 身份。
- **ArgoCD**：dex 保持禁用，用原生 `configs.cm.oidc.config`，`clientID/clientSecret: $argocd-oidc:oidc.client*`
  从带 `app.kubernetes.io/part-of=argocd` label 的 ESO secret 解析（与 chart 管的 `argocd-secret` 分开）。
  `rbac.policy.default: role:admin`。
  - ⚠️ 改 `oidc.config` 只热更 ConfigMap，必须 `rollout restart` `argocd-server`，否则首次 SSO 登录 500
    `Initializing OIDC provider (issuer: )`。
  - `just deploy-argocd` 报 SSA 字段冲突（如被 `kubectl-patch` 占着）时加 `--force-conflicts` 重跑，见 `k8s/helm/justfile` 注释。

## Jellyfin

**Jellyfin**（`media`，homelab）用原生 OIDC 插件，不是 oauth2-proxy 反代：

- **为什么是插件**：非浏览器客户端（iOS/Android/Kodi/Infuse、直连流媒体 URL）走 API token 不走 cookie，
  反代层的 oauth2-proxy 会把它们全挡掉；插件在认证层接 ZITADEL，API token / Quick Connect 不受影响。
  Navidrome 同理但无官方 OIDC，只用本地账号。
- **插件**：`aussierk/jellyfin-plugin-oidc`（安全加固 fork），由 `k8s/helm/manifests/media/jellyfin.yaml`
  的幂等 initContainer 下载到 `/config/plugins/`（dll 在则跳过），因为 Jellyfin 插件不能随 git 声明式安装。
  版本与匹配的 `targetAbi` 钉在那里，升 Jellyfin 前先核对。
- **ZITADEL client**：`jellyfin`（plain WEB OIDC + BASIC client auth，`configure-oidc-app.sh` 注册，Homelab 项目）。
  creds → Vault `secret/homelab/jellyfin-oidc`（keys `oauth_client_id`/`oauth_client_secret`）。
- **Redirect URI**：`https://media.meirong.dev/sso/OIDC/Callback/zitadel`（插件回调固定后缀，providerId = `zitadel`）。
- ⚠️ **未完成的手动环节**（GUI，无文件接口可预设）：Dashboard → Plugins → Provider 填
  authority/client/scopes/claims → Test Connection（端点 pinning）→ Role Mapping
  （单用户可映射 ZITADEL 角色 → admin）→ 登录按钮 BrandingSnippet。
  **保留至少一个本地密码 Jellyfin admin 作为 SSO 故障恢复路径。**

## 无法直连 OIDC 的应用：per-app oauth2-proxy

当前无实例。形态：HTTPRoute → 该应用专属的 `oauth2-proxy`（作为 ZITADEL OIDC client，同样由
`configure-oidc-app.sh` 注册、creds 进 Vault）→ 应用。仓库里没有现成模板，上一份配置脚本随旧 LLM 网关
退役删在 `2380d6a`，可从 git 取回参考。

## GitHub 社交登录（联邦 IdP）

- GitHub 是 ZITADEL **instance 级外部 IdP**，所有 ZITADEL-OIDC 应用自动有 "Sign in with GitHub"，
  ZITADEL 仍是唯一 IdP。由 `zitadel/scripts/configure-github-idp.sh` 下发。
- **锁死注册**：`isCreationAllowed/isAutoCreation=false`、`autoLinking=AUTO_LINKING_OPTION_EMAIL`：
  陌生 GitHub 账号无法自助注册，GitHub 身份只能按已验证邮箱链接到既有 ZITADEL 用户。
  当前链接：`zitadel-admin` ↔ GitHub `meirongdev`（extUserId `137514603`）。
- **Gotchas**：
  1. 本实例跑 Login V2，IdP 回调是 `https://auth.meirong.dev/idps/callback`，**不是** v1 的
     `/ui/login/login/externalidp/callback`；GitHub OAuth App 的 Authorization callback URL 必须精确一致。
  2. ZITADEL 只读 GitHub 的**公开**邮箱：首次邮箱自动链接时 GitHub 邮箱必须设为公开；
     链接成功后按 GitHub user ID 匹配，邮箱可改回私密。

## 配置脚本为何走 REST 而非 Terraform

`zitadel/scripts/*.sh`（`configure-oidc-app.sh` / `configure-github-idp.sh` / `configure-smtp.sh` /
`bootstrap-terraform-user.sh`）统一用 REST API 幂等下发：**Terraform/gRPC 的写操作过 Cloudflare edge 会坏**，
而这些脚本从任何机器经公网 `auth.meirong.dev` 都能跑。`zitadel/terraform/` 仅用于 bootstrap 期的用户/项目/客户端。
