# manual-helm → ArgoCD：采纳现存 Helm release 的验证方法与三个陷阱

> 日期: 2026-07-31
> 状态: 已实施（kube-prometheus-stack / external-dns ×2）；otel-collector 待决

## 上下文

`docs/CONVENTIONS.md` 的「NOT managed by ArgoCD」曾列 6 项手动 Helm release。其中三项
（kube-prometheus-stack、external-dns、otel-collector）没有任何非 GitOps 的技术理由——
不像 Vault（需人工 init/unseal）、ESO（依赖 Vault）、Cilium（CNI，装它的时候还没有集群）。
把它们留在 manual-helm 的代价是：改 values 要人肉记得跑 `just deploy-*`，
而且集群与 Git 的偏离没人对账。

⚠️ 本仓库有过一次失败的 Helm 采纳先例：ArgoCD 自身从 stock-manifest 转 Helm 时
**原地采纳不可能**（stock 与 chart 的 `.spec.selector` 标签不同，而它不可变），
最终靠一次维护窗口重装完成。所以这次先建立可验证的前置检查，而不是直接 apply。

## 决策一：采纳前必须逐对象验证渲染等价性

方法（脚本见本文末）：把 `helm get manifest <release>`（集群里真实生效的那份）与
`helm template <release> <chart> --version X -f <values> --kube-version <server>`
（ArgoCD 将要渲染的那份）解析成对象集合逐个比对，看清三类结果：
**会被裁剪的 / 会被新建的 / 内容会变的**。只有确认「0 裁剪、变更可解释」才动手。

实测结论：

| 目标 | live | 渲染 | 结论 |
|---|---|---|---|
| external-dns @ homelab | 6 | 6 | ✅ 逐字节一致，采纳是 no-op |
| external-dns @ oracle | 5 | 5 | ✅ 逐字节一致（前提：`releaseName`，见决策三） |
| kube-prometheus-stack | 98 | 105 | 0 裁剪；+7 全是 Helm hook；1 处 live-only 字段 |

kube-prometheus-stack 那 7 个 `*-admission-*` 对象全带
`helm.sh/hook: pre/post-install,pre/post-upgrade` + `hook-delete-policy: hook-succeeded`，
ArgoCD 会当 PreSync/PostSync hook 跑完即删，不是常驻对象。
那 1 处差异是 Grafana PVC 的 `spec.volumeName`（绑定时由集群写入，git 侧本就不该有），
ArgoCD 的 diff 不把「live 有、desired 无」的字段算作变更。

## 决策二：CRD 陈旧必须与迁移解耦（`skipCrds: true`）

采纳 kube-prometheus-stack 时发现一个**既存**问题：

- 集群运行的 operator 是 **v0.92.1**（chart 87.6.0 自带）
- 但 10 个 `monitoring.coreos.com` CRD 停在 **v0.89.0**

根因是 Helm 的既知行为：**`helm upgrade` 从不升级 chart `crds/` 目录里的 CRD**
（只有首次 install 会装）。所以这个集群从某个更早的 chart 版本升上来之后，
CRD 就一直没动过，落后运行中的 operator 三个 minor 版本。

如果让 ArgoCD 接管 CRD，首次同步会**顺带**把 10 个 CRD 升到 v0.92.1。那是一次
独立变更（单个 CRD 近 1MB、可能影响既有 CR 的校验），不该被"迁 GitOps"夹带执行——
一次变更只解决一件事，出问题时才分得清是谁的错。故 Application 里显式
`skipCrds: true`，把采纳保持为纯 no-op。

**⏳ 待决（本次刻意不做）**：CRD v0.89.0 → v0.92.1。两条路——
把 `skipCrds` 去掉让 ArgoCD 接管（之后 CRD 随 chart 版本自动跟进，一劳永逸），
或 `kubectl apply --server-side` 手工升一次。建议前者，但要单独开窗口、单独验证。

## 决策三：`releaseName` 才是跨集群同 chart 的正解，`fullnameOverride` 不够

`docs/reference/argocd-app-patterns.md` 原先记载的坑 #2 说：同一 chart 部署到两个集群时，
两个 Application 不能重名（`foo` / `foo-oracle`），而 ArgoCD 拿 App 名当 Helm release 名，
所以 oracle 侧资源名会带后缀，修法是加 `fullnameOverride: foo`。

**这条修法不完整**。实测（external-dns，release 名 `external-dns-oracle`）：

| 配置 | 结果 |
|---|---|
| 什么都不加 | **5 删 5 建** —— 全部资源改名重建 |
| 只加 `fullnameOverride: external-dns` | 对象名对上了，但 5 个对象内容仍不符 |
| `helm.releaseName: external-dns` | ✅ 与 live 逐字节一致 |

原因：release 名不只影响对象名，还会渲染进 `app.kubernetes.io/instance` 标签，
而该标签在 Deployment 的 **`spec.selector.matchLabels`** 里——**不可变字段**。
`fullnameOverride` 只改对象名，管不到标签，于是采纳时必然撞上 selector 不匹配。

正解是 ArgoCD 的 `spec.sources[].helm.releaseName`，直接把 release 名与 Application 名解耦。

> 为什么 `opencost-oracle` 用 `fullnameOverride` 没出事？因为它是 **ArgoCD 全新部署**
> （资源由 ArgoCD 亲手创建），不存在"既有 selector"可撞。这个坑只在**采纳现存 release**
> 时才咬人——两种场景要分清。

## 决策四：otel-collector 不采纳（因为它根本不存在）

`just deploy-otel-collector` + `values/opentelemetry-collector.yaml` 看着像个活着的
manual-helm 组件，实测 homelab **既无 release 也无 pod**。连带发现两处失效断言：

- `docs/reference/observability-otel-logging.md` 声称 "homelab: App → OTel Collector → Tempo"
- Loki 里**只有 `cluster="oracle-k3s"`** 的日志（oracle 那份是 kustomize 管的裸 DaemonSet，
  经 Tailscale otlphttp 推到 homelab Loki）

即 **homelab 自己的容器日志完全没进 Loki**，包括 kube-bench CIS 结果、backup CronJob
输出这些"打 stdout 就以为能在 Loki 查"的东西（CONVENTIONS 里 `{namespace="kube-bench"}`
这类查询也查不到——顺带一提 label 名也变了，现在是 `k8s_namespace_name`）。

所以这一项不是"迁 GitOps"，而是"要不要新增一个日志采集 DaemonSet"：在 5600H 单节点
（idle ~74°C，硬约束见 CLAUDE.md）上要额外 CPU，还会让 Loki 的 5Gi PVC 增长。
这是容量与取舍决策，留给人定，不由本次重构夹带。配方与文档已就地标注实情。

## 后果

- `kube-prometheus-stack` / `external-dns` / `external-dns-oracle` 三个 Application 上线，
  改 values → `git push` → 3 分钟自动同步，不再需要人肉 `just deploy-*`。
- 对应 justfile 配方全部标 `⚠️ LEGACY` + 保留为逃生通道（**日常不要跑，selfHeal 会打架**），
  并写明 `helm rollback` 的紧急回滚路径（release 历史仍在，采纳不销毁它）。
- `AppProject.sourceRepos` 加了两个 chart repo。⚠️ AppProject **不在 root App 托管路径下**，
  必须手工 `kubectl apply -f argocd/projects/homelab.yaml`，否则新 App 报
  `repo ... is not permitted in project`。
- 遗留的 `sh.helm.release.v1.*` Secret 不动：它是 `helm rollback` 的依据，
  且 AppProject 的 `orphanedResources.ignore` 已豁免这类 Secret。

## 附：验证脚本

一次性工具，不入库；需要时按下述逻辑重建即可（约 60 行 Python）：

```
live     = parse(helm --kube-context CTX get manifest RELEASE -n NS)
rendered = parse(helm template RELEASE CHART --version V -n NS -f VALUES \
                   --kube-version SERVER [--include-crds])
# 以 apiVersion/kind/namespace/name 为键建字典，剥掉 meta.helm.sh/* 与
# argocd.argoproj.io/* 注解后比对，分别列出 只在live / 只在渲染 / 内容不同 三类。
```

两个实现细节：kube-prometheus-stack 的告警规则里有裸 `=`，PyYAML 会按 YAML 1.1 的
special value tag 解析失败，要注册 `tag:yaml.org,2002:value` 构造器；
`--kube-version` 要对齐服务端（本集群 v1.34.5），否则 chart 里的 Capabilities 分支会渲染不同。
