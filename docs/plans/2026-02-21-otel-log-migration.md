# OTel 日志迁移实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 Promtail DaemonSet 替换为 OpenTelemetry Collector DaemonSet，日志继续写入 Loki，Grafana 查询体验不变。

**Architecture:** OTel Collector 以 DaemonSet 运行，通过 `filelog` receiver 读取节点 `/var/log/pods` 下所有容器日志，经 `k8sattributes` 注入 K8s 元数据后，由 `loki` exporter 推送至 Loki Gateway。Promtail 随后从 Loki Helm values 中禁用。

**Tech Stack:** `open-telemetry/opentelemetry-collector` Helm chart (mode=daemonset)，`otel/opentelemetry-collector-contrib` 镜像（含 filelog receiver、k8sattributes processor、loki exporter），Loki Gateway（现有）

---

## 前置条件检查

在开始前确认：
- `kubectl get pods -n monitoring` — Loki、Promtail、Grafana 均 Running
- `kubectl get helmrelease -n monitoring` 或 `helm list -n monitoring` — 确认现有 Helm release 名称
- Grafana Explore → Loki 数据源能正常查询到近期日志

---

## Task 1: 在 justfile 中添加 OTel Helm repo 和部署命令

**Files:**
- Modify: `k8s/helm/justfile`

### Step 1: 在 `add-repos` 中追加 open-telemetry repo

在 `k8s/helm/justfile` 的 `add-repos` recipe 末尾（`helm repo update` 之前），添加：

```
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
```

最终 `add-repos` 结尾如下：
```
add-repos:
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo add hashicorp https://helm.releases.hashicorp.com
    helm repo add external-secrets https://charts.external-secrets.io
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    helm repo update
```

### Step 2: 在 justfile 中追加 OTel 部署命令

在 `deploy-all` recipe 之前插入以下两条命令（放在 `deploy-tempo` 之后）：

```
# 部署 OpenTelemetry Collector (DaemonSet 模式，替换 Promtail)
deploy-otel-collector: add-repos
    helm upgrade --install opentelemetry-collector open-telemetry/opentelemetry-collector \
        --namespace {{namespace}} \
        --values values/opentelemetry-collector.yaml \
        --wait \
        --timeout 5m

# 删除 OTel Collector
remove-otel-collector:
    helm uninstall opentelemetry-collector -n {{namespace}} || true
```

### Step 3: 运行验证（语法检查）

```bash
just --list 2>&1 | grep otel
```

期望输出（含新命令）：
```
deploy-otel-collector
remove-otel-collector
```

### Step 4: Commit

```bash
cd /path/to/homelab
git add k8s/helm/justfile
git commit -m "chore: add OTel Collector helm repo and justfile commands"
```

---

## Task 2: 创建 OTel Collector values 文件

**Files:**
- Create: `k8s/helm/values/opentelemetry-collector.yaml`

### Step 1: 检查可用的 chart 版本

```bash
helm repo update
helm search repo open-telemetry/opentelemetry-collector
```

记录最新版本号（后续如需 pin 版本使用）。

### Step 2: 创建 values 文件

创建 `k8s/helm/values/opentelemetry-collector.yaml`，内容如下：

```yaml
# OTel Collector — DaemonSet 模式，替换 Promtail
# Chart: open-telemetry/opentelemetry-collector
# Image: otel/opentelemetry-collector-contrib (含 filelog, k8sattributes, loki exporter)

mode: daemonset

image:
  repository: otel/opentelemetry-collector-contrib

# Presets 处理：挂载 /var/log/pods、filelog receiver、k8sattributes processor 所需 RBAC 和环境变量
presets:
  logsCollection:
    enabled: true
    includeCollectorLogs: false   # 不采集 collector 自身日志，避免循环
  kubernetesAttributes:
    enabled: true
    extractAllPodLabels: false    # 只提取 app label，避免高基数
    extractAllPodAnnotations: false

# 仅覆盖 pipeline 和 exporter 配置
# presets 已自动注入 filelog receiver 和 k8sattributes processor
config:
  processors:
    # 将 OTel resource attributes 映射为 Loki labels（控制基数）
    resource:
      attributes:
        - action: insert
          key: loki.resource.labels
          value: k8s.namespace.name, k8s.pod.name, k8s.container.name, k8s.deployment.name, app

    batch:
      send_batch_size: 10000
      timeout: 5s

  exporters:
    loki:
      endpoint: http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push

  service:
    pipelines:
      logs:
        receivers: [filelog]
        processors: [k8sattributes, resource, batch]
        exporters: [loki]

# 资源限制（单节点 homelab）
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 250m
    memory: 256Mi

# 部署到 monitoring namespace（与 Loki 同 namespace，避免跨 namespace 网络问题）
namespaceOverride: monitoring
```

### Step 3: Commit

```bash
git add k8s/helm/values/opentelemetry-collector.yaml
git commit -m "feat: add OTel Collector values (DaemonSet, loki exporter)"
```

---

## Task 3: 部署 OTel Collector DaemonSet

**Files:** 无新增文件

### Step 1: 更新 Helm repo 并部署

```bash
cd k8s/helm
just deploy-otel-collector
```

期望输出：
```
Release "opentelemetry-collector" has been upgraded. Happy Helming!
...
STATUS: deployed
```

### Step 2: 验证 DaemonSet Pod 运行

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=opentelemetry-collector
```

期望：Pod 状态为 `Running`，READY 为 `1/1`。

如果 Pod CrashLoop，查看日志定位问题：
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=50
```

常见问题：
- `loki exporter: connection refused` — 检查 Loki Gateway Service 名称：`kubectl get svc -n monitoring | grep loki`
- `permission denied /var/log/pods` — 检查 DaemonSet securityContext：`kubectl describe daemonset -n monitoring opentelemetry-collector`

### Step 3: 检查 OTel Collector 日志无 ERROR

```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=30 | grep -i error
```

期望：无输出（无错误）。

### Step 4: 验证日志已到达 Loki

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
```

打开浏览器 → `http://localhost:3000` → Explore → 数据源选 Loki → 执行查询：

```logql
{k8s_namespace_name="monitoring"} | limit 20
```

期望：能看到近期日志条目，且 labels 包含 `k8s_namespace_name`、`k8s_pod_name`、`k8s_container_name`。

> **注意：** OTel Loki exporter 会将属性名中的 `.` 转换为 `_`，Loki label 查询时使用下划线形式（`k8s_namespace_name` 而非 `k8s.namespace.name`）。

### Step 5: 与 Promtail 日志做对比（确认双写正常）

此时 Promtail 和 OTel Collector 都在采集，日志会有重复，属正常现象（切换期间）。

---

## Task 4: 禁用 Promtail

> **前提：** Task 3 Step 4 确认 OTel 日志正常写入 Loki 后，才执行此 Task。

**Files:**
- Modify: `k8s/helm/values/loki.yaml`

### Step 1: 在 loki.yaml 中禁用 Promtail

找到文件底部的 Promtail 配置块（约第 103 行）：

```yaml
# Promtail（日志收集器）
promtail:
  enabled: true
  ...
```

修改为：

```yaml
# Promtail 已由 OTel Collector DaemonSet 替代
promtail:
  enabled: false
```

删除 promtail 下的其他配置行（resources、config 等），因为 enabled: false 时它们无效。

### Step 2: 重新部署 Loki（禁用 Promtail）

```bash
cd k8s/helm
just deploy-loki
```

期望：Helm upgrade 成功，Promtail DaemonSet 被删除。

### Step 3: 验证 Promtail Pod 已消失

```bash
kubectl get pods -n monitoring | grep promtail
```

期望：无输出。

### Step 4: 验证 OTel Collector 仍正常运行

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=opentelemetry-collector
```

期望：仍为 `Running 1/1`。

### Step 5: 等待 2 分钟后再次验证日志

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
```

在 Grafana Explore → Loki，查询最近 5 分钟的日志：

```logql
{k8s_namespace_name="personal-services"} | limit 10
```

```logql
{k8s_namespace_name="homepage"} | limit 10
```

期望：有新日志出现，说明切换后采集正常。

### Step 6: Commit

```bash
git add k8s/helm/values/loki.yaml
git commit -m "feat: disable promtail, OTel Collector takes over log collection"
```

---

## Task 5: 更新 Homepage dashboard（可选）

如果 Homepage 的 services.yaml 中 Loki 条目有相关说明，可以更新描述。通常不需要，跳过。

---

## Task 6: 端到端验证与收尾

### Step 1: 全面验证所有命名空间的日志

在 Grafana Explore → Loki，逐一验证各命名空间有日志：

```logql
{k8s_namespace_name="monitoring"} | limit 5
{k8s_namespace_name="personal-services"} | limit 5
{k8s_namespace_name="homepage"} | limit 5
{k8s_namespace_name="argocd"} | limit 5
{k8s_namespace_name="vault"} | limit 5
{k8s_namespace_name="kopia"} | limit 5
```

### Step 2: 验证 Grafana 现有 Dashboard 不受影响

打开 Grafana → Dashboards，检查原有使用 Loki 数据源的 panel 仍正常显示。

> **注意：** 如果原有 Dashboard 使用了 Promtail 特有的 label（如 `{job="monitoring/loki"}`），需要更新为 OTel 格式的 label（如 `{k8s_namespace_name="monitoring"}`）。

### Step 3: 检查资源使用

```bash
kubectl top pods -n monitoring
```

OTel Collector Pod 应在 50-128Mi 内存范围内。

### Step 4: Final commit

```bash
git add .
git commit -m "feat: complete OTel log pipeline migration (Promtail → OTel Collector)"
```

---

## 回滚方案

如需回滚到 Promtail：

```bash
# 1. 恢复 loki.yaml 中 promtail.enabled: true
# 2. 重新部署 Loki（恢复 Promtail）
cd k8s/helm && just deploy-loki

# 3. 删除 OTel Collector
just remove-otel-collector
```

---

## 常见问题排查

| 症状 | 排查步骤 |
|------|---------|
| OTel Pod CrashLoop | `kubectl logs -n monitoring <pod>` 查看启动错误；检查 loki endpoint 是否可达 |
| Loki 中无新日志 | `kubectl logs -n monitoring <otel-pod> \| grep -i "loki\|error\|drop"` |
| label 格式不对 | OTel 使用 `.` 分隔，Loki 存储时转为 `_`；查询时用 `k8s_namespace_name` |
| 日志重复 | 确认 Promtail 已禁用：`kubectl get pods -n monitoring \| grep promtail` |
| Grafana Loki 数据源报错 | `kubectl get svc -n monitoring \| grep loki-gateway` 确认 Service 存在 |
