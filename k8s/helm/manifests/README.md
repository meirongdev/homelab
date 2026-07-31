# k8s/helm/manifests/ — homelab 集群原生清单

> 布局规则：**一个子目录 ↔ 一个 ArgoCD Application（目录源）**。
> 把 yaml 放进目录即自动纳入同步（`monitoring/` 含子目录，App 带 `recurse: true`）；
> **不要在本目录根部放散文件**——没有任何 App 会认领它。
> 新增一组资源 = 建目录 + 在 `argocd/applications/` 加一个指向它的 Application（`root` App 自动接管）。
> 决策背景见 `docs/decisions/manifests-directory-per-app.md`。

## 所有权地图

| 目录 | ArgoCD App | 目标 ns | 内容 |
|------|-----------|---------|------|
| `bifrost/` | `bifrost` | `bifrost` | LLM 网关 + oauth2-proxy（PVC 带 `Prune=false`） |
| `calibre-metadata/` | `calibre-metadata` | `personal-services` | 元数据补全 Job/CronJob。⚠️ **kustomize**：新文件必须登记进 `kustomization.yaml` |
| `cloudflare/` | `cloudflare` | `cloudflare` | Cloudflare Tunnel（cloudflared） |
| `external-dns/` | `external-dns` | `external-dns` | Cloudflare token 的 ExternalSecret（chart 本体是 manual-helm：`just deploy-external-dns`） |
| `gateway/` | `gateway` | `kube-system` | `gateway.yaml` = GatewayClass + Gateway 本体；每条对外路由一个 `route-<service>.yaml`（ReferenceGrant + HTTPRoute 成对）。**新子域名 = 新建一个 `route-*.yaml`**，DNS 由 external-dns 自动建 |
| `kube-bench/` | `kube-bench` | `kube-bench` | CIS 周巡检 CronJob（ns 由 manifest 自身渲染） |
| `kyverno-policies/` | `kyverno-policies` | `kyverno` | Kyverno ClusterPolicy（与 kyverno chart 安装分离，便于逐条 Audit→Enforce） |
| `monitoring/` | `monitoring-dashboards` | `monitoring` | `dashboards/`（Grafana ConfigMap）、`alerts/`（PrometheusRule + Alertmanager 配置/secret）、`slos.yaml`、`krr.yaml`（右尺寸周报）、`monitoring-external.yaml`（外部抓取）、`cilium-envoy-servicemonitor.yaml` |
| `namespace-guardrails/` | `namespace-guardrails` | 跨 ns | 轻量应用 ns 的 LimitRange 护栏 |
| `personal-services/` | `personal-services` | `personal-services` | calibre-web、calibre-ebook-sync + 该 ns 的 LimitRange。**新个人服务放这里**（见 add-service 技能） |
| `vault-eso/` | `vault-eso` | `external-secrets` | ClusterSecretStore 配置 + 共享 ExternalSecret |

## 备注

- App 定义在 `argocd/applications/<app>.yaml`；`monitoring/` 对应的 App 名是历史名
  `monitoring-dashboards`（改 Application 名会触发 ArgoCD 删旧建新，故保留）。
- Helm 应用的 values 在 `../values/<app>.yaml`，oracle 集群变体为 `<app>-oracle.yaml`。
- oracle-k3s 集群的清单不在这里，在 `cloud/oracle/manifests/`（kustomize 树，
  新文件必须登记进 `kustomization.yaml`，与本目录的"放进即生效"不同）。
