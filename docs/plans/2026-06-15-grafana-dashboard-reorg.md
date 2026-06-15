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
- Loki / Tempo 数据源补稳定 `uid: loki` / `uid: tempo` —— **经 `deleteDatasources` 删建实现**
  (直接改 uid 会崩，见"踩坑#1")，并据此配好 trace↔log↔metric 关联。

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

- `helm template` 渲染：FOLDER_ANNOTATION / foldersFromFilesStructure / home path 均存在；
  多集群 ON vs OFF → 内置面板 `cluster` 变量 `hide` 由 2 翻到 0（21 张面板）。
- 全部 dashboard 嵌入 JSON 合法、文件夹注解与 tag 正确。
- 部署后线上确认：Grafana Pod 3/3 Running、启动无 provisioning 报错；sidecar 在
  `/tmp/dashboards/` 下建出 `Platform` / `Logs` / `Hardware` / `Kubernetes Built-in` 四个目录。

## 踩坑与教训（部署阶段）

1. **给已存在的数据源赋 uid 必须用 `deleteDatasources`**。本集群 Grafana 用 NFS PVC 持久化，
   库里已有按 name 自动生成随机 uid 的 Loki/Tempo；直接在 provisioning 里改它们的 uid →
   Grafana 12.x 报 `Datasource provisioning error: data source not found` → **整个 Grafana
   Pod CrashLoop**。**最终方案**：`grafana.deleteDatasources`(按 name 先删旧记录)+
   `additionalDataSources`(以稳定 uid `loki`/`tempo` 重建)——删建同 uid、幂等。踩坑过程：先
   误判为"跨数据源前向引用"，逐步删引用仍崩(rev-10→12)，最终定位是 **uid 变更**本身；一度
   全量回退(不设 uid)恢复，再用 deleteDatasources 正解重新启用。
   - 关联只配**后向引用**：Tempo(排在 Loki/Prometheus 之后)配 `tracesToLogsV2`→loki /
     `tracesToMetrics`/`serviceMap`→prometheus；Loki 侧**不**配指向 Tempo 的前向引用。
2. **首次 `just deploy-prometheus` 挂起 1h+**：瞬时基础设施卡顿(本机是发热的 5600H 笔记本)
   让 helm `--wait` 卡在陈旧连接上、超过 `--timeout` 仍不退出。处理：停掉进程 →
   `helm rollback <release> <上一个 deployed revision>` 清除 `pending-upgrade` → 重试。
3. 重试时改用 **不带 `--wait`** 的 `helm upgrade`（应用即退出，避免长连接挂起），再单独
   `kubectl rollout status` 轮询。仅改 datasource ConfigMap **不会**触发 Pod 重建，需手动
   `kubectl delete pod` 让其重挂新配置。

## 提交

- `bef1f82` feat(grafana): folders + multi-cluster selectors（values + 文件夹注解 + 数据源固定，**含后被回退的 datasource uid**）
- `b2158cb` docs(grafana): 门户下钻链接 + 统一 tag + 文档
- fix 提交：回退 datasource uid + Loki 面板数据源变量改回自动选择 + 文档订正

## 注意

- folder / 多集群 / Home 在 values（Helm 管理，**非 ArgoCD**），改后必须 `just deploy-prometheus`。
- 新增 dashboard 的约定见 `docs/CONVENTIONS.md` › Conventions › **Grafana dashboards**。
