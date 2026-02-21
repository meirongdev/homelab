# OTel 日志迁移设计文档

**日期：** 2026-02-21
**状态：** 已批准，待实施
**范围：** 仅日志管道（Metrics/Traces 不变）

## 背景

当前日志采集使用 Promtail DaemonSet，直接将容器日志推送至 Loki。本次迁移目标是将日志采集层替换为 OpenTelemetry Collector，引入 OTel 标准，为后续统一三种遥测信号（Logs/Metrics/Traces）奠定基础。

## 现有架构

```
/var/log/containers/*.log
    ↓ Promtail DaemonSet (grafana/loki Helm chart 内置)
Loki Gateway → Loki SingleBinary → Grafana
```

- Loki：SingleBinary，5Gi NFS，7 天保留，无认证
- Promtail：随 `grafana/loki` Helm chart 一同部署（`promtail.enabled: true`）
- Grafana 数据源：Loki + Tempo，已配置 TraceID 关联

## 目标架构

```
/var/log/containers/*.log (每个节点 hostPath 挂载，只读)
    ↓ filelog receiver（解析 CRI/containerd 格式）
OTel Collector DaemonSet（monitoring namespace）
    ↓ k8sattributes processor（注入 K8s 元数据）
    ↓ resource processor（规范化 resource attributes）
    ↓ batch processor
    ↓ loki exporter（OTLP → Loki push API）
Loki Gateway → Loki SingleBinary → Grafana（不变）
```

Promtail 从 Loki Helm values 中禁用（`promtail.enabled: false`）。

## 方案选型与 Tradeoff

### 方案 A：单层 OTel Collector DaemonSet（选定）

**架构：** DaemonSet 直接读取节点日志，推送 Loki。

| 维度 | 评估 |
|------|------|
| 复杂度 | 低——与 Promtail 一对一替换 |
| 资源消耗 | 与 Promtail 相当，每节点约 64-128Mi |
| 可扩展性 | 单节点 homelab 完全够用；多节点需加 Gateway 层 |
| OTel 标准化程度 | 完全符合，filelog + loki exporter |
| 风险 | 低——Loki、Grafana 无需改动 |

**选定原因：** 单节点 K3s 无需聚合层，改动最小，风险最低。

---

### 方案 B：两层架构（Agent DaemonSet + Gateway Deployment）

**架构：** DaemonSet 采集 → 中央 Gateway Deployment 聚合 → Loki。

| 维度 | 评估 |
|------|------|
| 复杂度 | 高——两个独立的 Helm release 或 mode |
| 资源消耗 | 更高，额外一个 Deployment |
| 可扩展性 | 优秀——Gateway 可做 filter/transform/fan-out |
| OTel 标准化程度 | 完全符合 |
| 风险 | 中——多一层网络跳转，故障点更多 |

**未选原因：** homelab 单节点场景过度设计，资源浪费。日后扩展至多节点时可迁移至此方案。

---

### 方案 C：Promtail + OTel 并存

**架构：** 保留 Promtail，额外部署 OTel Collector 接收 OTLP。

| 维度 | 评估 |
|------|------|
| 复杂度 | 中——两套系统并存 |
| 资源消耗 | 翻倍 |
| 可扩展性 | 有限——需要同时维护两套配置 |
| OTel 标准化程度 | 部分 |
| 风险 | 低——渐进式，但不是真正的迁移 |

**未选原因：** 不符合"迁移"目标，增加长期维护负担。

---

## 关键技术决策

### 1. Helm Chart 选择

使用 `open-telemetry/opentelemetry-collector`（官方 chart），而非 `grafana/opentelemetry-collector`。

**理由：**
- 官方维护，版本与 OTel Collector 核心同步
- 支持 `mode: daemonset`，声明式配置完整
- Grafana 的 chart 主要针对 Grafana Agent，不是纯 OTel Collector

### 2. 日志格式解析

containerd（K3s 默认运行时）的日志格式为 CRI 格式：
```
2024-01-01T00:00:00.000000Z stdout F {"key":"value"}
```

`filelog` receiver 使用 `cri` parser 自动解析，无需手动正则。

### 3. Loki Label 映射

OTel resource attributes → Loki labels 映射：

| OTel Attribute | Loki Label |
|---|---|
| `k8s.namespace.name` | `namespace` |
| `k8s.pod.name` | `pod` |
| `k8s.container.name` | `container` |
| `k8s.deployment.name` | `deployment` |
| `app` (from pod labels) | `app` |

**设计约束：** Loki 的 label 数量需控制（高基数问题），日志正文内容保留在 log body，不映射为 label。

### 4. 切换顺序（避免日志断档）

1. 先部署 OTel Collector DaemonSet
2. 确认日志出现在 Grafana
3. 再禁用 Promtail（更新 loki.yaml + `just deploy-loki`）

此顺序确保两者短暂并存，不丢失日志。

### 5. RBAC 需求

`k8sattributes` processor 需要通过 K8s API 查询 Pod/Namespace 元数据，DaemonSet 的 ServiceAccount 需要以下权限：

```yaml
resources: [pods, namespaces, nodes]
verbs: [get, list, watch]
```

Helm chart 通过 `clusterRole.rules` 配置，自动创建 ClusterRole + ClusterRoleBinding。

## 不变组件

| 组件 | 状态 |
|------|------|
| Loki (SingleBinary) | 不变 |
| Grafana + 数据源 | 不变 |
| Tempo | 不变 |
| Prometheus / kube-prometheus-stack | 不变 |
| 所有应用服务 | 不变（无需修改代码） |

## 后续演进路径

本次迁移完成后，可选的下一步：
1. **Traces 统一**：应用通过 OTLP 发送 traces 到 OTel Collector，Collector 转发至 Tempo（Tempo 已有 OTLP receiver）
2. **Metrics 统一**：OTel Collector 开启 Prometheus receiver 接管部分 scrape，或向 Prometheus 推送 (remote write)
3. **多节点扩展**：加入 Gateway Deployment，各节点 Agent 聚合到中心 Gateway 后再转发

## 文件变更清单

| 文件 | 变更类型 | 说明 |
|------|---------|------|
| `k8s/helm/values/loki.yaml` | 修改 | `promtail.enabled: false` |
| `k8s/helm/values/opentelemetry-collector.yaml` | 新增 | DaemonSet 完整配置 |
| `k8s/helm/justfile` | 修改 | 新增 `deploy-otel-collector`、`remove-otel-collector`，更新 `add-repos` |
