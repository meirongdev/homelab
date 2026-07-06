# Backstage 开发者门户（RHDH 发行版）设计方案

> **状态:** 📐 Design（2026-06-06）— 待评审，评审通过后转 writing-plans 出实现计划
> **结论（拟）:** 在 oracle-k3s 上以 **Red Hat Developer Hub（RHDH）预构建发行版**形态部署 Backstage，插件走动态配置（无源码仓库、无镜像构建）。专用 `backstage` 命名空间 + 自管 PostgreSQL，ZITADEL OIDC 登录，经独立 Helm-source ArgoCD Application 纳入 GitOps。分三阶段落地。

**Goal:** 给 homelab 加一个开发者门户/IDP——统一编目 ~15 个服务（Software Catalog），集中渲染各仓库文档（TechDocs），提供黄金路径模板（Scaffolder），并在门户内直接查看每个服务的 Kubernetes / ArgoCD 部署状态。

**为什么选 RHDH 发行版（方案 B）而非原生 app（方案 A）:** 用户明确优先「零维护」。RHDH 是预构建镜像，目标插件（Catalog/TechDocs/Scaffolder 为 core；Kubernetes/ArgoCD/GitHub 为动态插件）全部通过 Helm values 启用，升级 = bump chart version + image tag，**彻底免去维护 yarn monorepo + CI 的负担**。代价是绑定该发行版的 release 节奏与动态插件兼容性——已接受。

**Tech Stack:** RHDH Helm chart（`redhat-developer/rhdh-chart`，chart `backstage` ~v4.6.x，预构建镜像，社区构建 quay.io）、PostgreSQL 15、ArgoCD（homelab hub，经 Tailscale 纳管 oracle 外部集群）、Cilium Gateway API、Cloudflare Tunnel、HashiCorp Vault + ESO、ZITADEL OIDC。

---

## 1. 架构

```
Internet → Cloudflare DNS → Cloudflare Tunnel (http2) → oracle-gateway (Cilium Gateway API)
         → HTTPRoute idp.meirong.dev → backstage Service:7007 → RHDH Deployment
                                                                  ├─ install-dynamic-plugins initContainer
                                                                  └─ → PostgreSQL (backstage ns, ClusterIP)
登录： Backstage ──OIDC──→ ZITADEL (auth.meirong.dev)
密钥： Vault secret/oracle-k3s/backstage ──ESO──→ K8s Secret (backstage ns)
```

- **命名空间 `backstage`**：干净隔离，独立生命周期。
- **集群落点**：oracle-k3s（24Gi 内存仅用 32%，余量充足；比 homelab 12Gi 更合适）。
- **部署载体（关键集成决策）**：RHDH 是 Helm chart，而 oracle 现有工作负载是单个 Kustomize 树（由 `oracle-k3s` App 管理）。不强行把 Helm 塞进 Kustomize。改为拆成两块：
  - **裸资源**（namespace、PostgreSQL、ExternalSecret）放进 Kustomize 树 `cloud/oracle/manifests/backstage/`，随 `oracle-k3s` App 一起 sync（复用已验证的同步链路）。
  - **路由**（HTTPRoute + ReferenceGrant）按仓库惯例统一进 `cloud/oracle/manifests/base/gateway.yaml`。
  - **RHDH 本体**由一个新的独立 **multi-source ArgoCD Application `backstage`** 部署：source 1 = RHDH Helm chart 仓库（`https://redhat-developer.github.io/rhdh-chart`），source 2 = homelab git 仓库提供 `cloud/oracle/backstage/values.yaml`（经 `$values` 引用），destination = oracle 外部集群（`https://100.107.166.37:6443`）。这样 values 提交进 Git、与 chart 解耦。先例：`argocd-image-updater` 即 Helm-source Application。
  - 启动次序依赖（PG/Secret 先于 RHDH）由 k8s 重试兜底：RHDH 在 PG 就绪前 CrashLoop，PG 起来后自愈，无需显式编排。

## 2. 组件清单

| 组件 | 形态 | 归属 | 备注 |
|---|---|---|---|
| RHDH (Backstage) | Helm chart `backstage` v4.6.x | 新 ArgoCD App `backstage`（multi-source: chart + git values） | 预构建镜像，插件走 `global.dynamic.plugins` |
| PostgreSQL | `postgres:15-alpine` Deployment + PVC | Kustomize 树 `cloud/oracle/manifests/backstage/` | 复刻 rss-postgres 模式；PVC 带 `Prune=false` 护栏 |
| Namespace `backstage` | Namespace manifest | 同上 | `CreateNamespace=false`，显式声明 |
| ExternalSecret | ESO `ExternalSecret` | 同上 | 复用 ClusterSecretStore `vault-backend` |
| HTTPRoute + ReferenceGrant | Gateway API | `base/gateway.yaml` | `idp.meirong.dev` → backstage:7007；关掉 chart 自带 ingress |
| Cloudflare ingress + DNS | Terraform | `cloud/oracle/cloudflare/terraform.tfvars` | 加 `idp`，`just apply` |
| Uptime Kuma monitor | ConfigMap MONITORS | `cloud/oracle/manifests/uptime-kuma/uptime-kuma.yaml` | 加 `idp.meirong.dev` |
| ArgoCD AppProject | 既有 `homelab` project | — | oracle destination 已在 project 白名单 |

## 3. 数据库（自管专用 PG）

- 在 `backstage` ns 起一个 `postgres:15-alpine` Deployment（单副本）+ ClusterIP Service + PVC（带 `argocd.argoproj.io/sync-options: Prune=false`），模式与 `rss-system` 的 `rss-postgres` 一致。
- 选自管而非 chart 自带 subchart 的理由：chart 自带 PG 走 Bitnami 镜像，近年 registry/许可变动频繁；自管镜像可控、与现有 homelab 约定一致、适合长期服务。
- RHDH 通过 app-config 指向该外部 PG（host `postgres.backstage.svc`、port 5432）。
- 备份：纳入 oracle-k3s 既有 Kopia 备份策略（后续 runbook 更新；P1 数据级别）。

## 4. 密钥（Vault `secret/oracle-k3s/backstage`）

遵循约定「oracle-only 凭据放 `secret/oracle-k3s/<service>`」。ESO 在 `backstage` ns 物化为一个 K8s Secret，chart 经 `extraEnvVarsSecrets` 注入：

| Key | 用途 |
|---|---|
| `BACKEND_SECRET` | Backstage 后端会话/服务间鉴权密钥 |
| `ZITADEL_CLIENT_ID` / `ZITADEL_CLIENT_SECRET` | ZITADEL OIDC app 凭据 |
| `GITHUB_TOKEN` | catalog 扫仓库 + Scaffolder 写仓库 + GitHub 插件（细粒度 PAT：repo + read:org） |
| `POSTGRES_PASSWORD` | 自管 PG 的口令（PG Deployment 与 RHDH 共用引用） |

ClusterSecretStore `vault-backend` 的 token 引用固定在 `rss-system` ns，但 ClusterSecretStore 可被任意 ns 的 ExternalSecret 引用，故 `backstage` ns 无需新 bootstrap，直接复用。

## 5. 认证（ZITADEL OIDC）

- 在 ZITADEL（`auth.meirong.dev`）新建一个 OIDC Web App，回调 URI：`https://idp.meirong.dev/api/auth/oidc/handler/frame`。
- Backstage `auth.providers.oidc` 指向 ZITADEL OIDC discovery endpoint；sign-in resolver 按邮箱匹配。
- 单人场景：允许「catalog 中无对应 User 实体也能登录」（新版 Backstage 默认收紧，需显式开启）。
- 不再引入 ingress 层 ForwardAuth/oauth2-proxy——与仓库现行「auth 下沉到应用层」方向一致。

## 6. GitOps 流程（落地后）

- 插件增减、app-config 调整 = 改 Helm values → `git push` → ArgoCD 3 分钟内 reconcile。
- 升级 RHDH = bump chart version + image tag → `git push`。
- **全程无镜像构建、无 argocd-image-updater**（方案 B 的核心红利）。

## 7. 分阶段落地（均仅改 values / manifests，无重建）

### Phase 1 — 骨架可登录
- `backstage` ns + 自管 PG + ExternalSecret + RHDH Helm App + HTTPRoute + Cloudflare DNS。
- ZITADEL OIDC 打通，能登录。
- core 插件（Catalog/TechDocs/Scaffolder）随发行版自带；手动登记几个 catalog 实体（homelab 仓库 + 2~3 个服务）验证 catalog 可用。
- Uptime Kuma 加监控。
- **验收**：`idp.meirong.dev` 经 ZITADEL 登录后看到 catalog，至少一个 Component 实体可浏览。

### Phase 2 — Catalog 充实 + 黄金路径
- 启用 GitHub 集成动态插件（catalog 自动发现 `meirongdev` org 内带 `catalog-info.yaml` 的仓库）。
- 给 homelab 主要服务补 `catalog-info.yaml`。
- 写一个「新建 homelab 服务」Scaffolder 模板（生成仓库骨架 + manifest 脚手架 + 自动注册 catalog），呼应现有 add-service 流程。
- TechDocs 用 local builder 渲染各仓库 `docs/`。
- **验收**：org 内仓库自动入 catalog；跑通一次模板生成；至少一个服务的 TechDocs 可渲染。

### Phase 3 — 运维视图
- 启用 Kubernetes + ArgoCD 动态插件。
- 建只读 ServiceAccount（oracle，必要时 homelab）+ ArgoCD API token，存入 Vault→ESO。
- 给 catalog 实体加 `backstage.io/kubernetes-id`、ArgoCD 注解，使每个 Component 直接显示部署/同步/健康状态。
- **验收**：在某 Component 页内看到其 Pod 状态与 ArgoCD 同步状态。

## 8. 资源预算与风险

**资源（oracle-k3s 现状：4 vCPU / 24Gi，内存用 32%，余 ~16Gi）：**
- RHDH 稳态 ≈ 1–1.5Gi 内存 / 0.5 vCPU；PG ≈ 256Mi。合计对节点无压力。

**风险与应对：**
| 风险 | 应对 |
|---|---|
| RHDH 默认走 Ingress/OpenShift Route | values 关闭 chart 自带 ingress，改用我们的 Gateway HTTPRoute |
| 新版 Backstage OIDC sign-in resolver 收紧 | app-config 显式允许无 catalog-user 登录 |
| 动态插件版本与 chart/镜像版本耦合 | 锁定一组经验证的 plugin 版本；升级时整组对齐回归 |
| 单节点单副本 PG 无冗余 | 接受（与 rss-postgres 同等级）；纳入 Kopia 备份 |
| 离站备份缺口（既有 homelab 全局问题） | 沿用现状，不在本设计范围内解决 |

## 9. 关键文件路径（拟）

| 操作 | 文件 |
|------|------|
| 新建 | `cloud/oracle/manifests/backstage/namespace.yaml` |
| 新建 | `cloud/oracle/manifests/backstage/postgres.yaml`（Deployment + Service + PVC） |
| 新建 | `cloud/oracle/manifests/backstage/external-secret.yaml` |
| 修改 | `cloud/oracle/manifests/kustomization.yaml` — 加入 backstage/* |
| 修改 | `cloud/oracle/manifests/base/gateway.yaml` — 加 HTTPRoute + ReferenceGrant `allow-gateway-to-backstage` |
| 新建 | `argocd/applications/backstage.yaml` — multi-source Application（RHDH chart + git values，targets oracle 外部集群） |
| 新建 | `cloud/oracle/backstage/values.yaml` — RHDH Helm values（经 Application `$values` 引用） |
| 修改 | `cloud/oracle/cloudflare/terraform.tfvars` — ingress_rules 加 `idp` |
| 修改 | `cloud/oracle/manifests/uptime-kuma/uptime-kuma.yaml` — MONITORS 加 `idp.meirong.dev` |
| 修改 | `CLAUDE.md` / `docs/CONVENTIONS.md` — Services 表 + GitOps 段补 Backstage |
| 修改 | `docs/plans/README.md` — 登记本设计 |
| 外部 | ZITADEL 建 OIDC app；Vault 写 `secret/oracle-k3s/backstage` |

## 10. 范围之外（YAGNI）

- 不做 ingress 层 SSO（沿用应用层 auth）。
- 不做原生 app 源码仓库 / CI（方案 A 已否决）。
- 不做多副本 / HA PG。
- 不在本设计内解决离站备份缺口。
