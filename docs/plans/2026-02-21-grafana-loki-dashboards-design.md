# Grafana Loki Dashboard 集成设计文档

**日期：** 2026-02-21
**状态：** 已批准，待实施
**依赖：** OTel 日志迁移（`2026-02-21-otel-log-migration-design.md`）已完成

## 背景

完成 Promtail → OTel Collector 迁移后，Loki 中的日志 label 格式变为 OTel 语义标准（`service_name`、`service_namespace`、`k8s_namespace_name` 等）。Grafana 中虽已配置 Loki 数据源，但尚无可用 Dashboard，日志只能通过 Explore 手动查询。

本文档设计将 Grafana Labs 官方 `k8s-monitoring-helm` Dashboard 集成到 homelab，通过 GitOps + Grafana sidecar 方式持久化部署。

## 方案选型与 Tradeoff

### 选项 A：Grafana Labs 官方 k8s-monitoring Dashboard（选定）

来源：`grafana/k8s-monitoring-helm` GitHub 仓库（Apache 2.0）

**优点：**
- Grafana Labs 官方维护，专为 OTel + Loki 3.x OTLP 设计
- 使用 `service_name` / `service_namespace` 等 OTel 语义标签，与当前 Loki label 集完全兼容
- 无需手写 JSON，复用成熟设计

**缺点：**
- 需要从 GitHub 获取最新 JSON，后续升级需手动同步
- 部分面板可能针对多节点集群设计，homelab 单节点场景某些面板不适用（如 node-per-node 对比）

---

### 选项 B：自定义 Dashboard

手写 JSON，完全针对当前 label 集定制。

**未选原因：** OTel label 兼容性问题已被选项 A 解决，重复造轮子意义不大。若官方 Dashboard 有不适用的面板，通过删减处理更高效。

---

### 选项 C：Grafana App Plugin（Logs App）

Grafana 11.x 提供 Logs App plugin，交互体验优于静态 Dashboard。

**未选原因：** Plugin 部署和持久化配置复杂（需 ConfigMap 注册 plugin），且 homelab 规模下静态 Dashboard 完全够用。Explore 界面已满足临时查询需求。

## 目标架构

```
grafana/k8s-monitoring-helm (GitHub, Apache 2.0)
  ↓ 获取 Dashboard JSON（实施时 fetch）
k8s/helm/manifests/grafana-dashboards.yaml
  ├── ConfigMap: loki-logs-overview       (namespace: monitoring, label: grafana_dashboard=1)
  ├── ConfigMap: loki-logs-pod            (namespace: monitoring, label: grafana_dashboard=1)
  ├── ConfigMap: loki-logs-cluster        (namespace: monitoring, label: grafana_dashboard=1)
  └── ConfigMap: loki-logs-node           (namespace: monitoring, label: grafana_dashboard=1)
  ↓ git push → ArgoCD auto-sync（3 分钟内）
argocd/applications/monitoring-dashboards.yaml
  (destination: namespace=monitoring)
  ↓
Grafana sidecar 热重载（无需重启 Pod）
  ↓
Grafana → Dashboards → Kubernetes / Logs / *
```

## Dashboard 清单

| Dashboard 名称 | 场景 | 主要 Label |
|----------------|------|-----------|
| Kubernetes / Logs / Overview | 各 namespace 日志量趋势、error 率统计 | `service_namespace` |
| Kubernetes / Logs / Pod | 按 namespace/pod 过滤的日志浏览器 | `service_namespace`, `service_name`, `k8s_pod_name` |
| Kubernetes / Logs / Cluster | 全局日志搜索、跨 namespace 关键词过滤 | `service_namespace` |
| Kubernetes / Logs / Node | 按 K8s 节点过滤（K3s 单节点可用） | `k8s_node_name` |

## Grafana Sidecar 工作原理

kube-prometheus-stack 默认启用 `grafana.sidecar.dashboards`，sidecar 容器持续 watch `monitoring` namespace 下带有 `grafana_dashboard: "1"` label 的 ConfigMap：

- ConfigMap 新增/更新 → sidecar 自动热加载，无需重启 Grafana Pod
- ConfigMap 删除 → Dashboard 从 Grafana 中移除
- data key 必须以 `.json` 结尾

## 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `k8s/helm/manifests/grafana-dashboards.yaml` | 新增 | 4 个 ConfigMap，含 dashboard JSON |
| `argocd/applications/monitoring-dashboards.yaml` | 新增 | 新 ArgoCD Application，目标 namespace=monitoring |
| `k8s/helm/values/kube-prometheus-stack.yaml` | 视情况修改 | 若 sidecar 未启用则添加配置 |

## 关键技术约束

1. **Namespace 匹配**：Dashboard ConfigMaps 必须部署到 `monitoring` namespace，与 Grafana Pod 同 namespace，sidecar 才能发现
2. **不能复用 personal-services app**：该 app 目标 namespace 为 `personal-services`，需单独创建 `monitoring-dashboards` ArgoCD Application
3. **label 兼容性已验证**：Task 6 验证报告确认 Loki 中存在 `service_name`、`service_namespace`、`k8s_namespace_name` 等标签，与 k8s-monitoring Dashboard 变量一致
4. **sidecar 默认启用**：kube-prometheus-stack Chart 默认 `sidecar.dashboards.enabled=true`，实施时需确认当前集群状态

## 后续演进路径

- 增加 Tempo traces Dashboard（`Kubernetes / Traces / *`）——与 Loki Dashboard 风格统一
- 配置 Loki → Tempo 的 TraceID 跳转（`derivedFields` 已在 datasource 中配置，等待有 traceID 的应用）
- 增加 Alerting rules for log error rate spike（基于 Loki ruler）
