# manifests/ 目录化：一个 ArgoCD App 一个目录，废除 directory.include 清单

> 日期: 2026-07-31
> 状态: ✅ 已实施

## 上下文

`k8s/helm/manifests/` 曾是 ~40 个文件的平铺目录，11 个 ArgoCD Application 各自用
`directory.include` glob 从中"认领"文件（`monitoring-dashboards` 的 glob 膨胀到 23 个文件名）。
2026-07-30 OpenCost/KRR 落地时连踩三坑（记录在 `docs/reference/argocd-app-patterns.md`），
其中第 3 坑——**新文件不加进 glob 就静默不生效**——纯属这个布局自找的：
文件归属只存在于 glob 字符串里，目录树上看不出来，每次扩展都要动两处、漏一处就白部署。

评估过的替代方案：

- **ApplicationSet + Git generator**（argocd-app-patterns.md Pattern A）：消灭的是 Application
  yaml 样板，解决不了文件归属问题；template 一处改错全体 App 遭殃，调试也从"逐 App 对账"
  变成"追 generator 渲染"。双集群异构（单节点 x86 笔记本 vs ARM free tier）用不上它的强项。
  **维持不采用**，条件不变：若 Helm 应用继续膨胀再评估。
- **整树 kustomize**（照搬 oracle 侧）：`kustomization.yaml` 的 `resources:` 又是一份显式清单，
  第 3 坑换个马甲回来（2026-07 calibre-metadata 漏登记 `metadata-enrich.yaml` 是现成先例）。

## 决策

1. `k8s/helm/manifests/` 重组为**一个子目录 ↔ 一个 ArgoCD Application**（11 个目录，根下不留散文件），
   App 的 source 从 `path: k8s/helm/manifests` + `directory.include` 改为直接指向子目录。
   `monitoring-dashboards` 因有 `dashboards/`、`alerts/` 子目录带 `directory.recurse: true`；
   其余 App 用平目录默认行为——**不要显式写 `recurse: false`**（默认值会被 live 对象规范化删除，
   导致 root App 对该 Application 永久 OutOfSync，同 kyverno-policies 的既有注释）。
2. `values/` 命名统一为 `<app>.yaml`（oracle 变体 `<app>-oracle.yaml`），终结一半文件带
   `-values` 后缀一半不带的状态；空孤儿 `calibre-values.yaml`（0 字节、零引用）删除。
3. `monitoring-dashboards` App **不改名**（尽管它管的早已不止 dashboards）：Application 改名
   = tracking 变更 = ArgoCD 删旧建新，告警链路短暂中断，收益只是名字好看。目录名用 `monitoring/`
   表达真实语义，App 名在注释里标注为历史名。
4. 所有权地图固化在 `k8s/helm/manifests/README.md`；`add-service` 技能同步改写
   （homelab 侧"登记 include"步骤删除，改为"放进目录即生效"）。

## 迁移安全性（为什么敢一个 commit 完成）

- 每个 App 的文件**整组**搬进自己的目录，同一 commit 改该 App 的 `path`——任一 revision 上，
  生效的那份 spec 渲染出的对象集合与迁移前完全一致；tracking 注解不变，同步 diff 为零。
- 竞态窗口（子 App 先于 root 拿到新 revision 刷新，旧 glob 匹配为空）被 ArgoCD 默认
  `automated.allowEmpty=false` 挡住：自动同步拒绝"渲染为空 → 全量裁剪"。
- 数据兜底：bifrost / calibre-web 的 PVC 本就带 `argocd.argoproj.io/sync-options: Prune=false`。

## 后果

- 新增 dashboard / 告警 / 共享 ExternalSecret / 个人服务：把 yaml 放进对应目录即生效，
  不再改任何清单文件；文件归属从目录树一眼可见。
- 新增一组资源：建目录 + 在 `argocd/applications/` 加一个指向它的 Application。
- 显式清单只剩 kustomize 树（`cloud/oracle/manifests/` 全树 + `calibre-metadata/`），
  那里的登记纪律仍然适用。
- 历史文档（`docs/plans/`、`docs/records/`）里的旧路径**不回改**；现行文档
  （reference / runbooks / guides / CONVENTIONS / 各 README / add-service 技能）已全部更新。
- justfile 遗留的 `kubectl apply` 逃生配方路径已同步更新（仅应急用，日常一律走 GitOps）。
