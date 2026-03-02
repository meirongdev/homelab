# Timeslot Deployment — 2026-03-02

## Overview

Deploy [timeslot](https://github.com/meirongdev/timeslot) — a self-hosted calendar visibility
system — onto the **oracle-k3s** cluster, accessible at `https://slot.meirong.dev`.

## Architecture

| Property | Value |
|----------|-------|
| Cluster | oracle-k3s |
| Namespace | `personal-services` |
| URL | `https://slot.meirong.dev` |
| SSO | **None** — timeslot uses its own HTTP Basic Auth on `/admin/`; `/api/*` is intentionally public |
| Storage | `local-path` StorageClass, 100Mi PVC at `/data` (SQLite) |
| Secret | Vault `secret/oracle-k3s/timeslot` → injected at `helm upgrade` time via `deploy-timeslot` |
| Image | `ghcr.io/meirongdev/timeslot:latest` |
| Helm chart | `deploy/helm` in [meirongdev/timeslot](https://github.com/meirongdev/timeslot), sparse-cloned at deploy time |

---

## GitOps 实现说明

Timeslot 采用**混合 GitOps 模式**：路由与基础设施声明在 Git 中，应用工作负载由 Helm 命令式部署。

### 什么在 Git 里（声明式，可审计）

| 文件 | 内容 | 触发方式 |
|------|------|----------|
| `cloud/oracle/manifests/personal-services/timeslot.yaml` | HTTPRoute（路由规则） | `just deploy-manifests` |
| `cloud/oracle/manifests/kustomization.yaml` | Kustomize 资源清单 | `just deploy-manifests` |
| `cloud/oracle/cloudflare/terraform.tfvars` | `slot.meirong.dev` DNS 记录 | `cd cloudflare && just apply` |
| `cloud/oracle/manifests/homepage/homepage.yaml` | Homepage 面板入口 | `just deploy-manifests` + pod restart |
| `cloud/oracle/manifests/uptime-kuma/provisioner.yaml` | Uptime Kuma 健康监控 | `just provision-uptime-kuma` |
| `cloud/oracle/justfile` | `deploy-timeslot` 部署配方 | 手动触发 |

### 什么不在 Git 里（命令式，有意为之）

| 内容 | 位置 | 原因 |
|------|------|------|
| Admin 密码 | Vault `secret/oracle-k3s/timeslot` | 敏感凭证不入 Git |
| Helm release 状态 | K8s `personal-services` namespace | Helm 管理 |
| Helm chart 源码 | GitHub `meirongdev/timeslot` | 应用自身的仓库 |

### 部署数据流

```
Git (HTTPRoute) ──→ kubectl apply -k ──→ Traefik 路由生效
Git (DNS)       ──→ terraform apply  ──→ slot.meirong.dev DNS 记录
Git (Homepage)  ──→ kubectl apply -k ──→ Homepage ConfigMap 更新 → pod restart
Vault (密码)    ──→ deploy-timeslot  ──→ helm upgrade (Deployment/PVC/Service/Secret)
                                         └─ init container sed 替换 config.json
```

### 与 homelab 服务的 GitOps 对比

| 维度 | homelab (ArgoCD) | oracle-k3s (本服务) |
|------|-----------------|---------------------|
| 触发方式 | `git push` → ArgoCD 自动 3 分钟内同步 | `git push` → 手动 `just deploy-manifests` |
| 应用负载 | ArgoCD 管理 K8s manifest | Helm 命令式部署 |
| 密钥管理 | ESO ExternalSecret (自动同步) | Vault 读取后 `helm --set` 注入 |
| 可审计性 | ArgoCD UI 可查历史 | Git log + Helm history |

### 为什么 timeslot 不用 ESO ExternalSecret？

Helm chart 自带一个 `Secret` 资源（含 `adminPassword`）。若同时存在 ESO 管理的同名 Secret，二者会产生 **Owner 冲突**，导致 ESO 持续报错。两种解法：

1. **本方案（已采用）**：绕开 ESO，直接在 `helm upgrade` 时用 `--set config.adminPassword=<value>` 注入，Vault 是唯一来源。
2. 备选方案：Patch Helm chart，删除其 `Secret` 模板，改由 ESO 管理——维护成本更高，不推荐。

---

## Troubleshooting

### Bug 1: Liveness Probe 401 → CrashLoopBackOff

**症状**：Pod 反复重启，`kubectl describe pod` 显示：

```
Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 401
Warning  BackOff    Back-off restarting failed container timeslot
```

**原因**：Helm chart `deployment.yaml` 硬编码 `livenessProbe.httpGet.path: /admin/`，该端点需要 HTTP Basic Auth，探针未携带凭证 → 始终返回 401 → pod 被 Kubernetes 重启。

### Bug 2: Init Container 密码注入失败（`$(ADMIN_PASSWORD)` 未替换）

**症状**：`cat /config/config.json` 显示 `"admin_password": "$(ADMIN_PASSWORD)"`，使用任何密码都无法登录。

**原因**：Chart `configmap.yaml` 以 `$(ADMIN_PASSWORD)` 作为占位符，init container 的 sed 命令是：

```sh
sed -e "s|$(ADMIN_PASSWORD)|$ADMIN_PASSWORD|g"
```

在 shell 双引号内，`$(ADMIN_PASSWORD)` 是**命令替换**语法——shell 尝试执行 `ADMIN_PASSWORD` 命令，失败后返回空字符串。sed 实际收到的是 `s|||g`，占位符永远无法匹配。

**修复**：改用 `awk`，通过 `-v` 参数传入密码，regex 模式在单引号中作为字面量处理：

```sh
awk -v pw="$ADMIN_PASSWORD" '{gsub(/\$\(ADMIN_PASSWORD\)/, pw)}1' \
  /config-template/config.json > /config/config.json
```

**持久化**：`deploy-timeslot` justfile 在 `helm upgrade` 后立即执行 `kubectl patch --type=json`，每次重新部署自动修复两个 bug：

```json
[
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path",
   "value":"/api/slots"},
  {"op":"replace","path":"/spec/template/spec/initContainers/0/command",
   "value":["sh","-c","awk -v pw=\"$ADMIN_PASSWORD\" '{gsub(/\\$\\(ADMIN_PASSWORD\\)/, pw)}1' /config-template/config.json > /config/config.json"]}
]
```

### Bug 3: `Authorization: Bearer` 被 SSO 中间件覆盖 → 401

**症状**：通过 `https://slot.meirong.dev` 访问 `/admin/`，输入正确的 Basic Auth 凭据仍返回 401；绕过 SSO 直连 pod（port-forward）时使用相同凭据返回 200。

**原因**：`sso-forwardauth` Traefik Middleware 中 `authResponseHeaders` 包含 `Authorization`，且 oauth2-proxy 以 `--pass-authorization-header=true` 运行。认证成功后，oauth2-proxy 在响应头中注入 `Authorization: Bearer <access_token>`，Traefik 将其复制到发往 timeslot 的请求，覆盖浏览器发出的 `Authorization: Basic <credentials>`。timeslot 收到的是 Bearer token 而非 Basic Auth，因此 `r.BasicAuth()` 失败，返回 401。

**修复**：从 timeslot HTTPRoute 移除 `sso-forwardauth` filter。timeslot 通过自身 Basic Auth 保护 `/admin/`，`/api/*` 端点设计上应对外公开（供博客嵌入）。无需 SSO 介入。

---

## Helm Chart 改进建议

基于本次部署实战，对 [meirongdev/timeslot](https://github.com/meirongdev/timeslot) Helm chart 提出以下改进：

### 1. Liveness Probe 默认路径错误（已验证 bug）

**问题**：`deployment.yaml` 硬编码 `livenessProbe.httpGet.path: /admin/`，而 `/admin/` 需要认证，探针始终返回 401 → CrashLoopBackOff。

**修复**：
```yaml
# deployment.yaml — 改为公开端点
livenessProbe:
  httpGet:
    path: {{ .Values.livenessProbe.path | default "/api/slots" }}
    port: 8080

# values.yaml — 新增可配置字段
livenessProbe:
  path: /api/slots        # 公开端点，无需认证
  initialDelaySeconds: 5
  periodSeconds: 30
readinessProbe:
  path: /api/slots
  initialDelaySeconds: 3
  periodSeconds: 10
```

### 2. 不支持外部 Secret（`existingSecret`）

**问题**：chart 无条件创建 `Secret` 资源，与 ESO / Vault Agent 等外部 Secret 管理器产生 **Owner 冲突**——二者争抢同名 Secret 的 ownership，导致 ESO 报错。

**修复**：增加 `existingSecret` 值，当设置时跳过 Secret 创建，复用外部管理的 Secret：

```yaml
# values.yaml
existingSecret: ""   # 若设置，使用该 Secret 而非自动创建
```

```yaml
# templates/secret.yaml
{{- if not .Values.existingSecret }}
apiVersion: v1
kind: Secret
...
{{- end }}
```

```yaml
# templates/deployment.yaml — init container env
- name: ADMIN_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.existingSecret | default (include "timeslot.fullname" .) }}-secrets
      key: admin_password
```

### 3. `resources` 字段层级错误（values.yaml bug）

**问题**：`limits` / `requests` 嵌套在 `service:` 下，但 deployment 模板引用 `.Values.resources`（顶层字段）——实际上容器没有任何资源限制。

```yaml
# 当前（错误）
service:
  type: ClusterIP
  port: 8080
  limits:       # ← 错误：位于 service 下
    memory: 128Mi
```

**修复**：
```yaml
# 修正后
service:
  type: ClusterIP
  port: 8080

resources:        # ← 顶层独立字段，与模板引用一致
  limits:
    memory: 128Mi
    cpu: 500m
  requests:
    memory: 64Mi
    cpu: 50m
```

### 4. Init Container `sed` 替换对特殊字符不安全

**问题**：`sed -e "s|$(ADMIN_PASSWORD)|$ADMIN_PASSWORD|g"` 使用 `|` 作为分隔符，如果密码本身含 `|`，sed 命令直接报错。

**修复方案 A（最小改动）**：改用不易出现在密码中的分隔符，或对密码做转义：
```sh
# 使用 @  作为分隔符并对密码内的 @ 转义
escaped=$(printf '%s\n' "$ADMIN_PASSWORD" | sed 's/@/\\@/g')
sed "s@__ADMIN_PASSWORD__@${escaped}@g" /config-template/config.json > /config/config.json
```

**修复方案 B（推荐）**：让应用直接从 Secret 挂载文件读取密码，彻底去掉 init container：
```yaml
# 将 Secret 挂载为文件，config.json 中密码字段留空
# 应用启动时从 /run/secrets/admin_password 读取
```

### 5. 缺少专用健康检查端点

**问题**：`/api/slots` 作为健康检查时，每次探针都会查询数据库。高频探针（`periodSeconds: 10`）会产生不必要的 DB 负载。

**建议**：增加轻量 `/healthz` 端点，只返回 `{"status":"ok"}` 不查 DB，供 liveness / readiness 使用：

```go
mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    w.Write([]byte(`{"status":"ok"}`))
})
```

---

## Files Changed

| File | Change |
|------|--------|
| `cloud/oracle/manifests/personal-services/timeslot.yaml` | **Created** — HTTPRoute only |
| `cloud/oracle/manifests/kustomization.yaml` | Added `personal-services/timeslot.yaml` |
| `cloud/oracle/manifests/homepage/homepage.yaml` | Added Timeslot entry in 个人服务 section |
| `cloud/oracle/manifests/uptime-kuma/provisioner.yaml` | Added Timeslot monitor (internal K8s DNS) |
| `cloud/oracle/cloudflare/terraform.tfvars` | Added `"slot"` ingress rule |
| `cloud/oracle/justfile` | Added `deploy-timeslot` recipe |
| `docs/plans/2026-03-02-timeslot-deployment.md` | This file |

---

## Deployment Steps

```bash
# 1. 在 Vault 存储密码
kubectl --context k3s-homelab exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN=\$VAULT_TOKEN vault kv put secret/oracle-k3s/timeslot admin_password=<pw>"

# 2. 部署 Helm chart（从 GitHub sparse-clone，注入密码）
cd cloud/oracle
just deploy-timeslot

# 3. 应用整个 cluster（HTTPRoute + Homepage + Uptime Kuma）
just deploy-manifests
kubectl --context oracle-k3s rollout restart deployment homepage -n homepage

# 4. 创建 DNS 记录
cd cloudflare && just apply

# 5. 更新 Uptime Kuma 监控
cd .. && just provision-uptime-kuma
```

---

## Verification

```bash
# Helm release 状态
helm --kube-context oracle-k3s list -n personal-services

# Pod 状态
kubectl --context oracle-k3s -n personal-services get pods -l app.kubernetes.io/name=timeslot

# HTTPRoute 已同步
kubectl --context oracle-k3s -n personal-services get httproute timeslot

# 本地连通性
kubectl --context oracle-k3s -n personal-services port-forward svc/timeslot 8080:8080
curl http://localhost:8080/api/slots

# 外部访问
curl -I https://slot.meirong.dev
```
