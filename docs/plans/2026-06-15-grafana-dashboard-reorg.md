# Grafana 监控面板整改

**日期：** 2026-06-15
**状态：** ✅ 已实施
**范围：** homelab Grafana（kube-prometheus-stack chart 86.2.x，Grafana sidecar）

## 背景 / 问题

面板平铺在一个列表里，难以查看和分析，根因：

1. **内置 mixin 面板无 `cluster` 选择器** —— 指标已带 `cluster` 标签
   （`homelab` / `oracle-k3s` / `dgx-spark`），但 `multicluster.global.enabled=false`，
   导致三集群指标在同一张图里被求和叠加。
2. **无文件夹分层** —— ~26 张面板（内置 mixin + 自定义）全平铺在 General；
   自定义面板标题里的 `/` 不会生成文件夹（需 sidecar folder 注解）。
3. **数据源变量 `${datasource}` 无默认值** —— 每次打开要手选。
4. **职责重叠、无统一入口** —— 自定义 `multicluster-overview` 与内置
   `k8s-resources-cluster` 重叠；无 Home 门户。

## 方案与实施

### values（`k8s/helm/values/kube-prometheus-stack.yaml`，Helm，需 `just deploy-prometheus`）

- `grafana.sidecar.dashboards.multicluster.global.enabled: true`
  → ~21 张内置面板的 `cluster` 变量从 `hide:2` 变为 `hide:0`（可见下拉）。
- `folderAnnotation: grafana_folder` + `provider.foldersFromFilesStructure: true`
  → 按 ConfigMap 注解分文件夹。
- `sidecar.dashboards.annotations.grafana_folder: "Kubernetes Built-in"`
  → chart 自带的 24 张内置面板统一归档到该文件夹。
- `grafana.ini` `dashboards.default_home_dashboard_path: /tmp/dashboards/Platform/multicluster-overview.json`
  → 登录直达多集群总览。
- Loki / Tempo 数据源补显式 `uid: loki` / `uid: tempo`
  → 修复 `tracesToLogs` / `derivedFields` 等悬空的 uid 引用。

### manifests（ArgoCD `monitoring-dashboards` App 自动同步）

- 自定义 dashboard ConfigMap 加注解 `grafana_folder`：
  `multicluster-overview` → `Platform`（Home）；4 个 Loki → `Logs`；DGX Spark → `Hardware`。
- 各 dashboard 的 `datasource` 模板变量固定并隐藏（`hide:2`，值 `loki`/`prometheus`）。
- `Platform` 总览顶部加 4 个按 **tag** 的 dashboard 链接
  （`kubernetes-mixin` / `node-exporter-mixin` / `loki` / `dgx-spark`）—— 用 tag 而非 UID。
- 统一 tag：自定义面板加 `curated`，metrics 面板加 `metrics`。

## 最终文件夹布局

| 文件夹 | 内容 |
|--------|------|
| `Platform` | Kubernetes / Multi-Cluster / Resource Overview（Home，含下钻链接） |
| `Logs` | Loki / Overview · Pod Browser · Errors · Cluster Search |
| `Hardware` | DGX Spark / Node Exporter |
| `Kubernetes Built-in` | 24 张 chart 自带 mixin 面板（带 `cluster` 选择器） |

## 验证

- `helm template` 渲染：FOLDER_ANNOTATION / foldersFromFilesStructure / home path /
  datasource uid 均存在；多集群 ON vs OFF → cluster 变量 `hide` 由 2 翻到 0（21 张面板）。
- 全部 dashboard 嵌入 JSON 合法、文件夹注解与 tag 正确。
- 部署后在 Grafana 确认：4 个文件夹、内置面板出现 `cluster` 下拉、登录直达总览。

## 提交

- `bef1f82` feat(grafana): organize dashboards into folders + multi-cluster selectors（values + 文件夹注解 + 数据源固定）
- 后续提交：门户下钻链接 + 统一 tag + 文档

## 注意

- folder/多集群/Home/datasource-uid 在 values（Helm 管理，**非 ArgoCD**），改后必须 `just deploy-prometheus`。
- 新增 dashboard 的约定见 `docs/CONVENTIONS.md` › Conventions › **Grafana dashboards**。
