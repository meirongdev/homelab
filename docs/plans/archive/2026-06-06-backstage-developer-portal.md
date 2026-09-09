# Backstage 开发者门户（RHDH）— 设计与 Phase 1 计划

> 日期: 2026-06-06
> 状态: ❌ **从未实施**（2026-07-31 复核：repo 内零痕迹，无 `argocd/applications/backstage.yaml`、
> 无 manifest、无 `cloud/oracle/manifests/backstage/`）。设计和 Phase 1 实现计划都写完了，
> 但从未动工，也没有接替者——homelab 至今没有开发者门户。
> 结论: 本页只作选型留档。**2026-09-09 合并**：原「设计」与「Phase 1 实现计划」两份文档
> （合计 920 行，其中大半是从未执行的逐任务 checklist）压缩成本页。

## 当初想解决什么

统一编目当时的 ~15 个服务（Software Catalog）、集中渲染各仓库文档（TechDocs）、
提供黄金路径模板（Scaffolder），并在门户内直接看每个服务的 Kubernetes / ArgoCD 部署状态。

## 选型：RHDH 发行版（方案 B），否决原生 app（方案 A）

用户明确优先「零维护」。Red Hat Developer Hub 是预构建镜像，目标插件
（Catalog/TechDocs/Scaffolder 为 core；Kubernetes/ArgoCD/GitHub 为动态插件）全部靠 Helm values
启用，升级 = bump chart version + image tag，**彻底免掉维护 yarn monorepo + CI 的负担**。
代价是绑死该发行版的 release 节奏与动态插件兼容性——当时已接受。

## 拟定的落地形态

| 项 | 拟定值 |
|---|---|
| 集群 | oracle-k3s（当时 4 vCPU / 24Gi，内存仅用 32%；比 homelab 12Gi 宽裕） |
| 域名 | `idp.meirong.dev` → backstage Service:7007 |
| 命名空间 | `backstage`（独立生命周期） |
| 数据库 | 自管 `postgres:15-alpine` 单副本 + PVC（`Prune=false`） |
| 认证 | ZITADEL OIDC，回调 `https://idp.meirong.dev/api/auth/oidc/handler/frame` |
| 密钥 | Vault `secret/oracle-k3s/backstage` → ESO → K8s Secret |
| 资源预算 | RHDH 稳态 ≈ 1–1.5Gi / 0.5 vCPU；PG ≈ 256Mi |

**部署载体是这份设计里最值得留的一条**：RHDH 是 Helm chart，而 oracle 现有工作负载是单个
Kustomize 树。不强行把 Helm 塞进 Kustomize，改为拆成两块——

- 裸资源（namespace / PostgreSQL / ExternalSecret）进 Kustomize 树，随 `oracle-k3s` App 一起 sync；
  路由（HTTPRoute + ReferenceGrant）按仓库惯例进 `base/gateway.yaml`。
- RHDH 本体由一个新的独立 **multi-source ArgoCD Application** 部署：source 1 = RHDH chart 仓库，
  source 2 = 本仓库提供的 `values.yaml`（经 `$values` 引用），destination = oracle 外部集群。
  values 提交进 Git、与 chart 解耦。

> ⚠️ 当时援引的先例 `argocd-image-updater` 已于 2026-08-03 退役
> （见 [argocd-image-updater 归档](2026-02-19-argocd-image-updater.md)）。multi-source Application
> 这个模式本身仍有效，现状见 [reference/argocd-app-patterns.md](../../reference/argocd-app-patterns.md)。

启动次序依赖（PG/Secret 先于 RHDH）当时决定不显式编排，靠 k8s 重试兜底：RHDH 在 PG 就绪前
CrashLoop，PG 起来后自愈。

## 识别到的风险

| 风险 | 拟定应对 |
|---|---|
| RHDH 默认走 Ingress/OpenShift Route | values 关掉 chart 自带 ingress，改用 Gateway HTTPRoute |
| 新版 Backstage OIDC sign-in resolver 收紧 | app-config 显式允许无 catalog-user 登录（单人场景必需） |
| 动态插件版本与 chart/镜像版本耦合 | 锁定一组经验证的 plugin 版本，升级时整组对齐回归 |
| 单节点单副本 PG 无冗余 | 接受（与 `rss-postgres` 同等级） |

选自管 PG 而非 chart 自带 subchart 的理由：chart 自带的走 Bitnami 镜像，近年 registry/许可
变动频繁；自管镜像可控、与仓库既有约定一致。

## 明确不做（YAGNI）

不做 ingress 层 SSO（沿用应用层 auth，与 [app-native-oidc-sso](../../decisions/app-native-oidc-sso.md) 一致）·
不做原生 app 源码仓库 / CI · 不做多副本或 HA PG · 不在本设计内解决离站备份缺口。

## 为什么最终没做

计划写完就搁置了，没有记录明确的否决理由。要重新评估的话，先问一遍最初的动机还在不在：
服务清单现在有 [reference/services.md](../../reference/services.md) 这个唯一真相源，
部署状态直接看 ArgoCD UI，文档有 [docs/](../../README.md) 的分域索引——
Backstage 当初要解决的三件事，两件已经被更轻的东西覆盖了。
