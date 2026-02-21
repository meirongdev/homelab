# Grafana Loki Dashboard 集成实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 Loki 日志系统创建 4 个 Grafana Dashboard（Pod 日志浏览器、全局搜索、日志量统计、错误日志聚合），通过 ConfigMap GitOps 方式持久化，ArgoCD 自动同步。

**Architecture:** Grafana 12.3.3 sidecar 已启用，自动 watch `monitoring` namespace 中 label `grafana_dashboard=1` 的 ConfigMap。新增 `k8s/helm/manifests/grafana-dashboards.yaml`（4 个 ConfigMap）+ `argocd/applications/monitoring-dashboards.yaml`（新 ArgoCD App，目标 namespace=monitoring）。

**Tech Stack:** Grafana 12.3.3（schemaVersion 40）、Loki 3.x、LogQL、Kubernetes ConfigMap、ArgoCD

**Loki 实际 Labels（已验证）：** `service_namespace`, `service_name`, `k8s_namespace_name`, `k8s_pod_name`, `k8s_container_name`, `k8s_deployment_name`, `stream`, `pod`

---

## 前置条件（已验证，无需操作）

- Grafana sidecar: `LABEL=grafana_dashboard`, `LABEL_VALUE=1`, `METHOD=WATCH` ✅
- 现有 25 个 dashboard ConfigMaps 正常加载 ✅
- Loki datasource 已配置（URL: `http://loki-gateway.monitoring.svc.cluster.local`）✅

---

## Task 1: 创建 grafana-dashboards.yaml（4 个 ConfigMap）

**Files:**
- Create: `k8s/helm/manifests/grafana-dashboards.yaml`

### Step 1: 创建文件

创建 `/Users/matthew/projects/homelab/k8s/helm/manifests/grafana-dashboards.yaml`，包含以下 4 个 ConfigMap。**每个 ConfigMap 的 data key 必须以 `.json` 结尾。**

```yaml
# Grafana Loki Dashboards
# 通过 kube-prometheus-stack grafana-sc-dashboard sidecar 自动加载
# 要求：namespace=monitoring, label grafana_dashboard=1
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-logs-overview
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  loki-logs-overview.json: |-
    {
      "annotations": {"list": []},
      "description": "各 namespace 日志量趋势与 error 率统计",
      "editable": true,
      "graphTooltip": 1,
      "links": [],
      "panels": [
        {
          "datasource": {"type": "loki", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"lineWidth": 1}},
            "overrides": []
          },
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 0},
          "id": 1,
          "options": {"legend": {"calcs": ["sum"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {
              "datasource": {"type": "loki", "uid": "${datasource}"},
              "expr": "sum by (service_namespace) (count_over_time({service_namespace=~\".+\"}[$__interval]))",
              "legendFormat": "{{service_namespace}}",
              "queryType": "range",
              "refId": "A"
            }
          ],
          "title": "日志量 by Namespace",
          "type": "timeseries"
        },
        {
          "datasource": {"type": "loki", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"lineWidth": 1}},
            "overrides": []
          },
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 8},
          "id": 2,
          "options": {"legend": {"calcs": ["sum"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {
              "datasource": {"type": "loki", "uid": "${datasource}"},
              "expr": "sum by (service_namespace) (count_over_time({service_namespace=~\".+\"} |~ \"(?i)(error|exception|fatal|panic)\" [$__interval]))",
              "legendFormat": "{{service_namespace}}",
              "queryType": "range",
              "refId": "A"
            }
          ],
          "title": "Error 日志量 by Namespace",
          "type": "timeseries"
        },
        {
          "datasource": {"type": "loki", "uid": "${datasource}"},
          "fieldConfig": {"defaults": {}, "overrides": []},
          "gridPos": {"h": 10, "w": 24, "x": 0, "y": 16},
          "id": 3,
          "options": {
            "dedupStrategy": "none",
            "enableLogDetails": true,
            "prettifyLogMessage": false,
            "showCommonLabels": false,
            "showLabels": true,
            "showTime": true,
            "sortOrder": "Descending",
            "wrapLogMessage": false
          },
          "targets": [
            {
              "datasource": {"type": "loki", "uid": "${datasource}"},
              "expr": "{service_namespace=~\".+\"} |~ \"(?i)(error|exception|fatal|panic)\"",
              "queryType": "range",
              "refId": "A"
            }
          ],
          "title": "最近 Error 日志",
          "type": "logs"
        }
      ],
      "refresh": "30s",
      "schemaVersion": 40,
      "tags": ["kubernetes", "logs", "loki", "otel"],
      "templating": {
        "list": [
          {
            "current": {},
            "hide": 0,
            "includeAll": false,
            "label": "Data Source",
            "name": "datasource",
            "options": [],
            "query": "loki",
            "refresh": 1,
            "type": "datasource"
          }
        ]
      },
      "time": {"from": "now-3h", "to": "now"},
      "timepicker": {},
      "timezone": "browser",
      "title": "Kubernetes / Logs / Overview",
      "uid": "k8s-logs-overview",
      "version": 1
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-logs-pod-browser
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  loki-logs-pod-browser.json: |-
    {
      "annotations": {"list": []},
      "description": "按 namespace / pod / container 过滤的日志浏览器",
      "editable": true,
      "graphTooltip": 0,
      "links": [],
      "panels": [
        {
          "datasource": {"type": "loki", "uid": "${datasource}"},
          "fieldConfig": {"defaults": {}, "overrides": []},
          "gridPos": {"h": 30, "w": 24, "x": 0, "y": 0},
          "id": 1,
          "options": {
            "dedupStrategy": "none",
            "enableLogDetails": true,
            "prettifyLogMessage": true,
            "showCommonLabels": false,
            "showLabels": true,
            "showTime": true,
            "sortOrder": "Descending",
            "wrapLogMessage": true
          },
          "targets": [
            {
              "datasource": {"type": "loki", "uid": "${datasource}"},
              "expr": "{service_namespace=~\"${namespace:pipe}\", k8s_pod_name=~\"${pod:pipe}\"} |~ \"${search}\"",
              "queryType": "range",
              "refId": "A"
            }
          ],
          "title": "Pod Logs",
          "type": "logs"
        }
      ],
      "refresh": "30s",
      "schemaVersion": 40,
      "tags": ["kubernetes", "logs", "loki", "otel"],
      "templating": {
        "list": [
          {
            "current": {},
            "hide": 0,
            "includeAll": false,
            "label": "Data Source",
            "name": "datasource",
            "options": [],
            "query": "loki",
            "refresh": 1,
            "type": "datasource"
          },
          {
            "current": {},
            "datasource": {"type": "loki", "uid": "${datasource}"},
            "definition": "label_values(service_namespace)",
            "hide": 0,
            "includeAll": true,
            "allValue": ".+",
            "label": "Namespace",
            "multi": true,
            "name": "namespace",
            "query": {"label": "service_namespace", "stream": "", "type": 1},
            "refresh": 2,
            "sort": 1,
            "type": "query"
          },
          {
            "current": {},
            "datasource": {"type": "loki", "uid": "${datasource}"},
            "definition": "label_values({service_namespace=~\"${namespace:pipe}\"}, k8s_pod_name)",
            "hide": 0,
            "includeAll": true,
            "allValue": ".+",
            "label": "Pod",
            "multi": true,
            "name": "pod",
            "query": {"label": "k8s_pod_name", "stream": "{service_namespace=~\"${namespace:pipe}\"}", "type": 1},
            "refresh": 2,
            "sort": 1,
            "type": "query"
          },
          {
            "current": {"selected": false, "text": "", "value": ""},
            "hide": 0,
            "label": "搜索",
            "name": "search",
            "options": [{"selected": true, "text": "", "value": ""}],
            "query": "",
            "type": "textbox"
          }
        ]
      },
      "time": {"from": "now-1h", "to": "now"},
      "timepicker": {},
      "timezone": "browser",
      "title": "Kubernetes / Logs / Pod Browser",
      "uid": "k8s-logs-pod",
      "version": 1
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-logs-error-aggregation
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  loki-logs-error-aggregation.json: |-
    {
      "annotations": {"list": []},
      "description": "聚合展示 ERROR / WARN / FATAL 日志，按 namespace 过滤",
      "editable": true,
      "graphTooltip": 0,
      "links": [],
      "panels": [
        {
          "datasource": {"type": "loki", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"lineWidth": 2}},
            "overrides": []
          },
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 0},
          "id": 1,
          "options": {"legend": {"calcs": ["sum"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {
              "datasource": {"type": "loki", "uid": "${datasource}"},
              "expr": "sum by (service_namespace) (count_over_time({service_namespace=~\"${namespace:pipe}\"} |~ \"(?i)(error|exception|fatal|panic)\" [$__interval]))",
              "legendFormat": "{{service_namespace}} errors",
              "queryType": "range",
              "refId": "A"
            },
            {
              "datasource": {"type": "loki", "uid": "${datasource}"},
              "expr": "sum by (service_namespace) (count_over_time({service_namespace=~\"${namespace:pipe}\"} |~ \"(?i)(warn|warning)\" [$__interval]))",
              "legendFormat": "{{service_namespace}} warnings",
              "queryType": "range",
              "refId": "B"
            }
          ],
          "title": "Error / Warn 趋势",
          "type": "timeseries"
        },
        {
          "datasource": {"type": "loki", "uid": "${datasource}"},
          "fieldConfig": {"defaults": {}, "overrides": []},
          "gridPos": {"h": 25, "w": 24, "x": 0, "y": 8},
          "id": 2,
          "options": {
            "dedupStrategy": "exact",
            "enableLogDetails": true,
            "prettifyLogMessage": false,
            "showCommonLabels": false,
            "showLabels": true,
            "showTime": true,
            "sortOrder": "Descending",
            "wrapLogMessage": true
          },
          "targets": [
            {
              "datasource": {"type": "loki", "uid": "${datasource}"},
              "expr": "{service_namespace=~\"${namespace:pipe}\"} |~ \"(?i)(error|exception|fatal|panic|warn)\"",
              "queryType": "range",
              "refId": "A"
            }
          ],
          "title": "Error / Warn 日志",
          "type": "logs"
        }
      ],
      "refresh": "1m",
      "schemaVersion": 40,
      "tags": ["kubernetes", "logs", "loki", "otel", "errors"],
      "templating": {
        "list": [
          {
            "current": {},
            "hide": 0,
            "includeAll": false,
            "label": "Data Source",
            "name": "datasource",
            "options": [],
            "query": "loki",
            "refresh": 1,
            "type": "datasource"
          },
          {
            "current": {},
            "datasource": {"type": "loki", "uid": "${datasource}"},
            "definition": "label_values(service_namespace)",
            "hide": 0,
            "includeAll": true,
            "allValue": ".+",
            "label": "Namespace",
            "multi": true,
            "name": "namespace",
            "query": {"label": "service_namespace", "stream": "", "type": 1},
            "refresh": 2,
            "sort": 1,
            "type": "query"
          }
        ]
      },
      "time": {"from": "now-1h", "to": "now"},
      "timepicker": {},
      "timezone": "browser",
      "title": "Kubernetes / Logs / Errors",
      "uid": "k8s-logs-errors",
      "version": 1
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-logs-cluster-search
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  loki-logs-cluster-search.json: |-
    {
      "annotations": {"list": []},
      "description": "跨 namespace 全文搜索，适合排查跨服务问题",
      "editable": true,
      "graphTooltip": 0,
      "links": [],
      "panels": [
        {
          "datasource": {"type": "loki", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"lineWidth": 1}},
            "overrides": []
          },
          "gridPos": {"h": 6, "w": 24, "x": 0, "y": 0},
          "id": 1,
          "options": {"legend": {"calcs": [], "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {
              "datasource": {"type": "loki", "uid": "${datasource}"},
              "expr": "sum by (service_namespace) (count_over_time({service_namespace=~\"${namespace:pipe}\"} |~ \"${search}\" [$__interval]))",
              "legendFormat": "{{service_namespace}}",
              "queryType": "range",
              "refId": "A"
            }
          ],
          "title": "匹配日志量",
          "type": "timeseries"
        },
        {
          "datasource": {"type": "loki", "uid": "${datasource}"},
          "fieldConfig": {"defaults": {}, "overrides": []},
          "gridPos": {"h": 28, "w": 24, "x": 0, "y": 6},
          "id": 2,
          "options": {
            "dedupStrategy": "none",
            "enableLogDetails": true,
            "prettifyLogMessage": false,
            "showCommonLabels": false,
            "showLabels": true,
            "showTime": true,
            "sortOrder": "Descending",
            "wrapLogMessage": true
          },
          "targets": [
            {
              "datasource": {"type": "loki", "uid": "${datasource}"},
              "expr": "{service_namespace=~\"${namespace:pipe}\"} |~ \"${search}\"",
              "queryType": "range",
              "refId": "A"
            }
          ],
          "title": "搜索结果",
          "type": "logs"
        }
      ],
      "refresh": "30s",
      "schemaVersion": 40,
      "tags": ["kubernetes", "logs", "loki", "otel", "search"],
      "templating": {
        "list": [
          {
            "current": {},
            "hide": 0,
            "includeAll": false,
            "label": "Data Source",
            "name": "datasource",
            "options": [],
            "query": "loki",
            "refresh": 1,
            "type": "datasource"
          },
          {
            "current": {},
            "datasource": {"type": "loki", "uid": "${datasource}"},
            "definition": "label_values(service_namespace)",
            "hide": 0,
            "includeAll": true,
            "allValue": ".+",
            "label": "Namespace",
            "multi": true,
            "name": "namespace",
            "query": {"label": "service_namespace", "stream": "", "type": 1},
            "refresh": 2,
            "sort": 1,
            "type": "query"
          },
          {
            "current": {"selected": false, "text": "", "value": ""},
            "hide": 0,
            "label": "搜索关键词",
            "name": "search",
            "options": [{"selected": true, "text": "", "value": ""}],
            "query": "",
            "type": "textbox"
          }
        ]
      },
      "time": {"from": "now-1h", "to": "now"},
      "timepicker": {},
      "timezone": "browser",
      "title": "Kubernetes / Logs / Cluster Search",
      "uid": "k8s-logs-search",
      "version": 1
    }
```

### Step 2: 验证 YAML 语法

```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('k8s/helm/manifests/grafana-dashboards.yaml')))" && echo "YAML OK"
```

期望：`YAML OK`

### Step 3: 验证每个 ConfigMap 的 JSON 合法

```bash
python3 -c "
import yaml, json
docs = list(yaml.safe_load_all(open('k8s/helm/manifests/grafana-dashboards.yaml')))
for d in docs:
    name = d['metadata']['name']
    for k, v in d['data'].items():
        json.loads(v)
        print(f'{name}/{k}: JSON OK')
"
```

期望：4 行 `JSON OK`，无异常。

### Step 4: Commit

```bash
cd /Users/matthew/projects/homelab
git add k8s/helm/manifests/grafana-dashboards.yaml
git commit -m "feat: add 4 Loki log dashboards for Grafana (OTel labels)

Dashboards: Overview, Pod Browser, Error Aggregation, Cluster Search.
All use OTel semantic labels (service_namespace, k8s_pod_name etc.)
Provisioned via grafana-sc-dashboard sidecar ConfigMap mechanism.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 2: 创建 monitoring-dashboards ArgoCD Application

**Files:**
- Create: `argocd/applications/monitoring-dashboards.yaml`

### Step 1: 创建文件

创建 `/Users/matthew/projects/homelab/argocd/applications/monitoring-dashboards.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring-dashboards
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: homelab
  source:
    repoURL: https://github.com/meirongdev/homelab
    targetRevision: main
    path: k8s/helm/manifests
    directory:
      include: "grafana-dashboards.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
```

### Step 2: 手动 apply ArgoCD Application（立即注册，不等 git push 自动发现）

```bash
kubectl apply -f /Users/matthew/projects/homelab/argocd/applications/monitoring-dashboards.yaml
```

期望：`application.argoproj.io/monitoring-dashboards created`

### Step 3: Commit

```bash
cd /Users/matthew/projects/homelab
git add argocd/applications/monitoring-dashboards.yaml
git commit -m "feat: add monitoring-dashboards ArgoCD Application

Deploys grafana-dashboards.yaml ConfigMaps to monitoring namespace.
Grafana sidecar auto-loads dashboards with label grafana_dashboard=1.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 3: 部署并验证 Dashboard 加载

**Files:** 无新增

### Step 1: git push 触发 ArgoCD 同步

```bash
cd /Users/matthew/projects/homelab
git push origin main
```

### Step 2: 等待 ArgoCD 同步（或手动触发）

```bash
# 方式一：等待自动同步（约 3 分钟）
kubectl get application monitoring-dashboards -n argocd -w

# 方式二：手动触发立即同步
kubectl annotate application monitoring-dashboards -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite
sleep 10
kubectl get application monitoring-dashboards -n argocd
```

期望：`STATUS: Synced`，`HEALTH: Healthy`

### Step 3: 验证 ConfigMaps 已部署到 monitoring namespace

```bash
kubectl get configmap -n monitoring -l grafana_dashboard=1 | grep loki
```

期望：看到 4 个新 ConfigMap：
```
loki-logs-cluster-search     1    ...
loki-logs-error-aggregation  1    ...
loki-logs-overview           1    ...
loki-logs-pod-browser        1    ...
```

### Step 4: 验证 sidecar 已加载 dashboard 文件

```bash
kubectl exec -n monitoring deploy/kube-prometheus-stack-grafana \
  -c grafana-sc-dashboard -- ls /tmp/dashboards/ | grep loki
```

期望：4 个 `.json` 文件出现在 sidecar 挂载目录。

### Step 5: 验证 Grafana API 已注册 Dashboard

```bash
# 获取 Grafana admin 密码
PASS=$(kubectl get secret -n monitoring grafana-admin-credentials \
  -o jsonpath="{.data.admin-password}" | base64 -d)

# 通过 API 查询 loki dashboard
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3001:80 &
PF_PID=$!
sleep 2
curl -s -u "admin:${PASS}" "http://localhost:3001/api/search?query=Kubernetes+%2F+Logs" \
  | python3 -m json.tool | grep '"title"'
kill $PF_PID 2>/dev/null
```

期望：输出包含 4 个 dashboard 标题：
```
"title": "Kubernetes / Logs / Overview"
"title": "Kubernetes / Logs / Pod Browser"
"title": "Kubernetes / Logs / Errors"
"title": "Kubernetes / Logs / Cluster Search"
```

### 如果 Dashboard 未出现（排查步骤）

```bash
# 检查 sidecar 日志
kubectl logs -n monitoring deploy/kube-prometheus-stack-grafana \
  -c grafana-sc-dashboard --tail=30 | grep -i "loki\|error\|load"

# 检查 grafana 主容器日志
kubectl logs -n monitoring deploy/kube-prometheus-stack-grafana \
  -c grafana --tail=20 | grep -i "dashboard\|error"
```

---

## 回滚方案

```bash
# 删除 ArgoCD Application（会同时删除受管的 ConfigMaps）
kubectl delete application monitoring-dashboards -n argocd

# 或只删除 ConfigMaps
kubectl delete configmap -n monitoring -l grafana_dashboard=1 \
  loki-logs-overview loki-logs-pod-browser \
  loki-logs-error-aggregation loki-logs-cluster-search
```

---

## Grafana 访问地址

Dashboard 加载后，在 Grafana → Dashboards 菜单中搜索 "Kubernetes / Logs" 即可找到。

- **URL**：https://grafana.meirong.dev（外网）
- **本地**：`kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3001:80`
