# Backstage 开发者门户（RHDH）实现计划 — Phase 1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 oracle-k3s 上部署 RHDH（Red Hat Developer Hub / Backstage 预构建发行版），经 ZITADEL OIDC 登录，连自管 PostgreSQL，纳入 ArgoCD GitOps，并能浏览 Software Catalog。

**Architecture:** 裸资源（namespace / 自管 PG / ExternalSecret）放进 oracle-k3s 既有 Kustomize 树；RHDH 本体由一个新的 **multi-source ArgoCD Application**（RHDH Helm chart + git values，参照 `argocd-image-updater`）部署到 oracle 外部集群（`https://100.107.166.37:6443`）；路由经 Cilium Gateway HTTPRoute + Cloudflare Tunnel；密钥经 Vault→ESO。

**Tech Stack:** RHDH Helm chart `redhat-developer/rhdh-chart`（chart `backstage`）、`postgres:15-alpine`、ArgoCD、Cilium Gateway API、Cloudflare Tunnel、HashiCorp Vault + ESO、ZITADEL OIDC、k3s v1.34。

**设计依据:** `docs/plans/2026-06-06-backstage-developer-portal-design.md`

**范围:** 本计划仅覆盖 **Phase 1（部署 + 登录 + Catalog 可用）**。Phase 2（GitHub 发现 + Scaffolder 模板 + TechDocs）与 Phase 3（Kubernetes + ArgoCD 运维插件 + RBAC）在 Phase 1 落地、可见真实插件版本/服务名后，各自另出计划。

**约定:** 所有提交直接到 `main`（仓库惯例）。GitOps 链路：`git push` → ArgoCD 3 分钟内 reconcile；用 `cd k8s/helm && just argocd-sync` 可立即触发，免等轮询。kubectl 统一加 `--context oracle-k3s`（裸资源在 oracle）与 `--context k3s-homelab`（ArgoCD / Vault 在 homelab）。

---

## 文件结构

| 操作 | 文件 | 职责 |
|------|------|------|
| Create | `cloud/oracle/manifests/backstage/namespace.yaml` | `backstage` 命名空间 |
| Create | `cloud/oracle/manifests/backstage/postgres.yaml` | 自管 PostgreSQL（Deployment + Service + PVC） |
| Create | `cloud/oracle/manifests/backstage/external-secret.yaml` | ESO 物化 `backstage-secrets` |
| Modify | `cloud/oracle/manifests/kustomization.yaml` | 注册 backstage/* |
| Modify | `cloud/oracle/manifests/base/gateway.yaml` | HTTPRoute + ReferenceGrant `allow-gateway-to-backstage` |
| Create | `cloud/oracle/backstage/values.yaml` | RHDH Helm values |
| Create | `catalog/all.yaml` | Phase 1 手动登记的 catalog 实体 |
| Create | `argocd/applications/backstage.yaml` | multi-source ArgoCD Application |
| Modify | `cloud/oracle/cloudflare/terraform.tfvars` | ingress_rules 加 `idp` |
| Modify | `cloud/oracle/manifests/uptime-kuma/provisioner.yaml` | MONITORS 加 Backstage |
| Modify | `CLAUDE.md` / `docs/plans/README.md` | 文档更新 |
| External | ZITADEL OIDC app；Vault `secret/oracle-k3s/backstage` | 手动一次性 |

---

## Task 1: 在 ZITADEL 建 OIDC 应用并写入 Vault

**Files:** 无（外部 + Vault）。

- [ ] **Step 1: 在 ZITADEL 创建 OIDC Web 应用**

登录 `https://auth.meirong.dev` → 选一个 Project（或新建 `homelab`）→ New Application：
- Type: **Web**
- Authentication Method: **CODE** (PKCE/Code flow with client secret)
- Redirect URI: `https://idp.meirong.dev/api/auth/oidc/handler/frame`
- Post Logout URI: `https://idp.meirong.dev`

保存后记下 **Client ID** 与 **Client Secret**。

- [ ] **Step 2: 创建 GitHub 细粒度 PAT**

GitHub → Settings → Developer settings → Fine-grained tokens：
- Repository access: `meirongdev/homelab`（Phase 2 可扩到 org all）
- Permissions: Contents=Read, Metadata=Read（Phase 2 加 Administration/Contents=Write 给 Scaffolder）

记下 token（`github_pat_...`）。

- [ ] **Step 3: 生成两个随机密钥**

Run:
```bash
echo "BACKEND_SECRET=$(openssl rand -base64 24)"
echo "POSTGRES_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
```
Expected: 打印两行随机值；记下备用（PG 口令避开特殊字符以简化连接串）。

- [ ] **Step 4: 写入 Vault**

Run（值替换为上面记录的真实值）:
```bash
kubectl --context k3s-homelab exec -n vault vault-0 -- \
  sh -c 'VAULT_TOKEN=$VAULT_TOKEN vault kv put secret/oracle-k3s/backstage \
    backend-secret="<BACKEND_SECRET>" \
    postgres-password="<POSTGRES_PASSWORD>" \
    zitadel-client-id="<CLIENT_ID>" \
    zitadel-client-secret="<CLIENT_SECRET>" \
    github-token="<GITHUB_PAT>"'
```
Expected: `Success! Data written to: secret/oracle-k3s/backstage`

- [ ] **Step 5: 校验写入**

Run:
```bash
kubectl --context k3s-homelab exec -n vault vault-0 -- \
  sh -c 'VAULT_TOKEN=$VAULT_TOKEN vault kv get -format=json secret/oracle-k3s/backstage' \
  | grep -o '"[a-z-]*":' | sort -u
```
Expected: 看到 `"backend-secret":` `"github-token":` `"postgres-password":` `"zitadel-client-id":` `"zitadel-client-secret":`

---

## Task 2: backstage 命名空间 + ExternalSecret

**Files:**
- Create: `cloud/oracle/manifests/backstage/namespace.yaml`
- Create: `cloud/oracle/manifests/backstage/external-secret.yaml`
- Modify: `cloud/oracle/manifests/kustomization.yaml`

- [ ] **Step 1: 写 namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: backstage
```

- [ ] **Step 2: 写 external-secret.yaml**

```yaml
# 复用 ClusterSecretStore vault-backend（token 在 rss-system，可被任意 ns 引用）
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: backstage-secrets
  namespace: backstage
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: backstage-secrets
    creationPolicy: Owner
  data:
    - secretKey: backend-secret
      remoteRef: { key: oracle-k3s/backstage, property: backend-secret }
    - secretKey: postgres-password
      remoteRef: { key: oracle-k3s/backstage, property: postgres-password }
    - secretKey: zitadel-client-id
      remoteRef: { key: oracle-k3s/backstage, property: zitadel-client-id }
    - secretKey: zitadel-client-secret
      remoteRef: { key: oracle-k3s/backstage, property: zitadel-client-secret }
    - secretKey: github-token
      remoteRef: { key: oracle-k3s/backstage, property: github-token }
```

- [ ] **Step 3: 注册到 kustomization.yaml**

在 `cloud/oracle/manifests/kustomization.yaml` 的 `resources:` 列表末尾（`personal-services/backup-cronjob.yaml` 之后）加：
```yaml
  # Backstage developer portal
  - backstage/namespace.yaml
  - backstage/external-secret.yaml
```

- [ ] **Step 4: 提交并触发同步**

Run:
```bash
git add cloud/oracle/manifests/backstage/namespace.yaml \
        cloud/oracle/manifests/backstage/external-secret.yaml \
        cloud/oracle/manifests/kustomization.yaml
git commit -m "feat(backstage): add namespace and ESO external-secret"
git push
cd k8s/helm && just argocd-sync && cd -
```
Expected: push 成功；argocd-sync 触发 oracle-k3s App 同步。

- [ ] **Step 5: 验证 namespace 与 Secret 物化**

Run:
```bash
kubectl --context oracle-k3s get ns backstage
kubectl --context oracle-k3s get externalsecret,secret -n backstage
```
Expected: ns `backstage` Active；ExternalSecret `backstage-secrets` STATUS=`SecretSynced`；Secret `backstage-secrets` 有 5 个 key。
排障：若 ExternalSecret 报 `SecretSyncedError`，确认 Task 1 的 property 名与此处完全一致。

---

## Task 3: 自管 PostgreSQL

**Files:**
- Create: `cloud/oracle/manifests/backstage/postgres.yaml`
- Modify: `cloud/oracle/manifests/kustomization.yaml`

- [ ] **Step 1: 写 postgres.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: backstage
  labels:
    app: postgres
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:15-alpine
          env:
            - name: POSTGRES_USER
              value: backstage
            - name: POSTGRES_DB
              value: backstage
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: backstage-secrets
                  key: postgres-password
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - containerPort: 5432
              name: postgres
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U backstage -d backstage"]
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: backstage-db
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: backstage
spec:
  type: ClusterIP
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
      name: postgres
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: backstage-db
  namespace: backstage
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

- [ ] **Step 2: 注册到 kustomization.yaml**

在 Task 2 加的两行之间补 `postgres.yaml`（顺序：namespace → postgres → external-secret 不强制，kustomize 不依赖顺序）：
```yaml
  - backstage/postgres.yaml
```

- [ ] **Step 3: 提交并同步**

Run:
```bash
git add cloud/oracle/manifests/backstage/postgres.yaml cloud/oracle/manifests/kustomization.yaml
git commit -m "feat(backstage): add self-managed postgres:15-alpine"
git push
cd k8s/helm && just argocd-sync && cd -
```
Expected: push 成功。

- [ ] **Step 4: 验证 PG 就绪**

Run:
```bash
kubectl --context oracle-k3s rollout status deploy/postgres -n backstage --timeout=120s
kubectl --context oracle-k3s exec -n backstage deploy/postgres -- pg_isready -U backstage -d backstage
```
Expected: `deployment "postgres" successfully rolled out`；`/var/run/postgresql:5432 - accepting connections`

---

## Task 4: HTTPRoute + ReferenceGrant

**Files:**
- Modify: `cloud/oracle/manifests/base/gateway.yaml`（追加到文件末尾）

- [ ] **Step 1: 追加 ReferenceGrant + HTTPRoute**

在 `cloud/oracle/manifests/base/gateway.yaml` 末尾追加：
```yaml
---
# ReferenceGrant: allow HTTPRoute in backstage to reference services
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-to-backstage
  namespace: backstage
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: backstage
  to:
    - group: ""
      kind: Service
---
# HTTPRoute: idp.meirong.dev -> backstage (RHDH backend :7007)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: backstage
  namespace: backstage
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: oracle-gateway
      namespace: kube-system
      port: 80
  hostnames:
    - "idp.meirong.dev"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: backstage
          port: 7007
          weight: 1
```

> 注：`backendRefs.name: backstage` 假定 RHDH Service 名为 `backstage`（release 名 = `backstage`）。Task 6 部署后用 Step「验证 Service 名」核对；若 chart 生成名不同（如 `backstage-developer-hub`），改这里再 push。

- [ ] **Step 2: 提交并同步**

Run:
```bash
git add cloud/oracle/manifests/base/gateway.yaml
git commit -m "feat(backstage): add HTTPRoute idp.meirong.dev + ReferenceGrant"
git push
cd k8s/helm && just argocd-sync && cd -
```
Expected: push 成功。

- [ ] **Step 3: 验证 HTTPRoute 已接受**

Run:
```bash
kubectl --context oracle-k3s get httproute backstage -n backstage -o jsonpath='{.status.parents[0].conditions[*].type}{"\n"}'
```
Expected: 含 `Accepted`（backend 解析此刻可能 `ResolvedRefs=False`，因 Service 尚未由 Task 6 创建，正常）。

---

## Task 5: RHDH Helm values

**Files:**
- Create: `cloud/oracle/backstage/values.yaml`

- [ ] **Step 1: 写 values.yaml**

```yaml
# RHDH (Backstage) values — 经 ArgoCD multi-source 的 $values 引用
global:
  dynamic:
    includes:
      - dynamic-plugins.default.yaml
    plugins: []          # Phase 1 仅 core；Phase 2/3 在此加 github/k8s/argocd 插件

route:
  enabled: false         # 关 OpenShift Route（我们用 Cilium Gateway HTTPRoute）

upstream:
  postgresql:
    enabled: false       # 关 chart 自带 PG，用自管的
  ingress:
    enabled: false       # 关 chart Ingress
  service:
    type: ClusterIP
    ports:
      backend: 7007
  backstage:
    replicas: 1
    image:
      registry: quay.io
      repository: rhdh-community/rhdh
      tag: "1.7"          # 部署时用 Step 2 核对的最新社区 tag 替换
    resources:
      requests:
        cpu: 250m
        memory: 1Gi
      limits:
        cpu: "1"
        memory: 1536Mi
    extraEnvVars:
      - name: BACKEND_SECRET
        valueFrom:
          secretKeyRef: { name: backstage-secrets, key: backend-secret }
      - name: POSTGRES_PASSWORD
        valueFrom:
          secretKeyRef: { name: backstage-secrets, key: postgres-password }
      - name: ZITADEL_CLIENT_ID
        valueFrom:
          secretKeyRef: { name: backstage-secrets, key: zitadel-client-id }
      - name: ZITADEL_CLIENT_SECRET
        valueFrom:
          secretKeyRef: { name: backstage-secrets, key: zitadel-client-secret }
      - name: GITHUB_TOKEN
        valueFrom:
          secretKeyRef: { name: backstage-secrets, key: github-token }
    appConfig:
      app:
        title: Homelab Developer Portal
        baseUrl: https://idp.meirong.dev
      signInPage: oidc
      backend:
        baseUrl: https://idp.meirong.dev
        listen:
          port: 7007
        cors:
          origin: https://idp.meirong.dev
          methods: [GET, HEAD, PATCH, POST, PUT, DELETE]
          credentials: true
        database:
          client: pg
          connection:
            host: postgres.backstage.svc.cluster.local
            port: 5432
            user: backstage
            database: backstage
            password: ${POSTGRES_PASSWORD}
        auth:
          externalAccess:
            - type: static
              options:
                token: ${BACKEND_SECRET}
                subject: admin-curl-access
      integrations:
        github:
          - host: github.com
            token: ${GITHUB_TOKEN}
      auth:
        environment: production
        providers:
          oidc:
            production:
              metadataUrl: https://auth.meirong.dev/.well-known/openid-configuration
              clientId: ${ZITADEL_CLIENT_ID}
              clientSecret: ${ZITADEL_CLIENT_SECRET}
              prompt: auto
              signIn:
                resolvers:
                  - resolver: emailMatchingUserEntityProfileEmail
                    dangerouslyAllowSignInWithoutUserInCatalog: true
      catalog:
        locations:
          - type: url
            target: https://github.com/meirongdev/homelab/blob/main/catalog/all.yaml
            rules:
              - allow: [Component, System, API, Resource, Location, User, Group]
```

- [ ] **Step 2: 不提交，先核对镜像 tag 与 chart 版本（Task 6 用）**

Run:
```bash
helm repo add rhdh https://redhat-developer.github.io/rhdh-chart 2>/dev/null; helm repo update rhdh >/dev/null
helm search repo rhdh/backstage --versions | head -5
```
Expected: 列出可用 chart 版本（如 `4.6.x`）。记下最新稳定版用于 Task 6 的 `targetRevision`；若该 chart 默认镜像 tag 与 values 里的 `1.7` 不符，以 chart 默认为准（可删掉 `image` 块让 chart 用自带默认）。

---

## Task 6: catalog 实体 + ArgoCD Application

**Files:**
- Create: `catalog/all.yaml`
- Create: `argocd/applications/backstage.yaml`

- [ ] **Step 1: 写 catalog/all.yaml（Phase 1 手动登记，验证 catalog 可用）**

```yaml
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: homelab
  description: Dual-cluster homelab infrastructure
spec:
  owner: matthew
---
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: backstage
  description: Developer portal (RHDH) on oracle-k3s
  annotations:
    backstage.io/source-location: url:https://github.com/meirongdev/homelab
spec:
  type: service
  lifecycle: production
  owner: matthew
  system: homelab
---
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: trends
  description: GitHub trends tracker
spec:
  type: service
  lifecycle: production
  owner: matthew
  system: homelab
```

- [ ] **Step 2: 写 argocd/applications/backstage.yaml（multi-source，参照 argocd-image-updater）**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: backstage
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: homelab
  sources:
    - repoURL: https://redhat-developer.github.io/rhdh-chart
      chart: backstage
      targetRevision: "4.6.3"          # 用 Task 5 Step 2 核对的版本替换
      helm:
        valueFiles:
          - $values/cloud/oracle/backstage/values.yaml
    - repoURL: https://github.com/meirongdev/homelab
      targetRevision: main
      ref: values
  destination:
    server: https://100.107.166.37:6443   # oracle 外部集群（Tailscale）
    namespace: backstage
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=false             # ns 由 Kustomize 树（Task 2）创建
```

- [ ] **Step 3: 校验 AppProject 允许该 chart 源与 oracle 目的地**

Run:
```bash
kubectl --context k3s-homelab get appproject homelab -n argocd \
  -o jsonpath='sourceRepos={.spec.sourceRepos}{"\n"}destinations={.spec.destinations}{"\n"}'
```
Expected: `sourceRepos` 含 `*`（或显式含 rhdh-chart 与 homelab 两个 repo）；`destinations` 含 server `https://100.107.166.37:6443`。
若 sourceRepos 不含 rhdh-chart 且非 `*`：在 `argocd/projects/homelab.yaml` 的 `sourceRepos` 加 `https://redhat-developer.github.io/rhdh-chart`，提交后再继续。

- [ ] **Step 4: 提交并同步**

Run:
```bash
git add catalog/all.yaml cloud/oracle/backstage/values.yaml argocd/applications/backstage.yaml
git commit -m "feat(backstage): deploy RHDH via multi-source ArgoCD Application"
git push
cd k8s/helm && just argocd-sync && cd -
```
Expected: push 成功；`root` App 在轮询内拉起新 `backstage` Application。

- [ ] **Step 5: 验证 Application 与 Pod**

Run:
```bash
kubectl --context k3s-homelab get application backstage -n argocd \
  -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
kubectl --context oracle-k3s get pods -n backstage
kubectl --context oracle-k3s get svc -n backstage
```
Expected: 最终 `Synced/Healthy`；`backstage-*` Pod `Running`（首次启动含 install-dynamic-plugins initContainer，可能 2–4 分钟）；Service 列表确认 backstage Service 名与端口（7007）。

- [ ] **Step 6: 核对 Service 名 == HTTPRoute backendRef**

Run:
```bash
kubectl --context oracle-k3s get svc -n backstage -o name
```
Expected: 含 `service/backstage`。若名字不同，改 Task 4 的 HTTPRoute `backendRefs.name` 为实际名 → `git commit -m "fix(backstage): correct HTTPRoute backendRef service name"` → push → `just argocd-sync`。

- [ ] **Step 7: 排障（如 Pod 未 Healthy）**

Run:
```bash
kubectl --context oracle-k3s logs -n backstage deploy/backstage -c backstage --tail=80
```
常见与对策：
- `getaddrinfo ... postgres` / DB 连接失败 → 确认 Task 3 PG Running、Service `postgres.backstage.svc` 可达。
- `auth ... backend keys` 报错 → 确认 `BACKEND_SECRET` 注入（`backstage-secrets` 含 `backend-secret`）。
- initContainer 拉插件失败 → `kubectl ... logs -c install-dynamic-plugins`；Phase 1 `plugins: []`，应仅装 default 集。
修正 values 后 `git commit && git push && just argocd-sync` 重试。

---

## Task 7: Cloudflare DNS + Tunnel ingress

**Files:**
- Modify: `cloud/oracle/cloudflare/terraform.tfvars`

- [ ] **Step 1: 在 ingress_rules 加 idp**

在 `cloud/oracle/cloudflare/terraform.tfvars` 的 `ingress_rules` map 内（`"trends"` 行后）加：
```hcl
  "idp"     = { service = "http://cilium-gateway-oracle-gateway.kube-system.svc:80" }
```

- [ ] **Step 2: 应用 Terraform**

Run:
```bash
cd cloud/oracle/cloudflare && just plan
```
Expected: plan 显示新增 1 个 DNS record（`idp.meirong.dev`）+ 更新 tunnel config。确认无意外删除后：
```bash
just apply && cd -
```
Expected: `Apply complete!`

- [ ] **Step 3: 提交**

Run:
```bash
git add cloud/oracle/cloudflare/terraform.tfvars
git commit -m "feat(backstage): expose idp.meirong.dev via Cloudflare Tunnel"
git push
```
Expected: push 成功（tfstate 不提交，已 gitignore / 本地）。

- [ ] **Step 4: 验证外部可达**

Run:
```bash
sleep 20; curl -sS -o /dev/null -w "%{http_code} -> %{redirect_url}\n" https://idp.meirong.dev/
```
Expected: `200`（RHDH 首页）或 `302 -> .../api/auth/oidc/start...`（跳登录）。两者都表示链路通。

---

## Task 8: Uptime Kuma 监控

**Files:**
- Modify: `cloud/oracle/manifests/uptime-kuma/provisioner.yaml`

- [ ] **Step 1: 在 MONITORS 加 Backstage**

在 `cloud/oracle/manifests/uptime-kuma/provisioner.yaml` 的外部 HTTPS 监控段（`ArgoCD` 行附近，约 line 35）加一行：
```python
        {"name": "Backstage",      "url": "https://idp.meirong.dev/",           "accepted_statuscodes": ["200-299", "300-399"]},
```

- [ ] **Step 2: 提交并同步**

Run:
```bash
git add cloud/oracle/manifests/uptime-kuma/provisioner.yaml
git commit -m "feat(backstage): add Uptime Kuma monitor for idp.meirong.dev"
git push
cd k8s/helm && just argocd-sync && cd -
```
Expected: push 成功；ArgoCD PostSync hook 重跑 provisioner Job（幂等，仅新增 Backstage 监控）。

- [ ] **Step 3: 验证监控已创建**

Run:
```bash
kubectl --context oracle-k3s get job -n personal-services | grep -i uptime
```
Expected: provisioner Job 新一次 Completed。（也可登录 `status.meirong.dev` 确认 Backstage 监控出现且 UP。）

---

## Task 9: 端到端验收

**Files:** 无。

- [ ] **Step 1: 浏览器登录**

打开 `https://idp.meirong.dev/` → 应被引导至 ZITADEL 登录 → 登录后回跳 Backstage 首页。
Expected: 成功进入 RHDH，无 OIDC 回调错误。
排障：若回调报 `redirect_uri_mismatch` → 核对 ZITADEL app 的 redirect URI 与 Task 1 完全一致；若登录后报 "user not found in catalog" → 确认 values 里 `dangerouslyAllowSignInWithoutUserInCatalog: true` 已生效（改后需 push + sync + Pod 重启）。

- [ ] **Step 2: 验证 Catalog**

在左侧 **Catalog** 页：
Expected: 看到 System `homelab` 及 Component `backstage`、`trends`（来自 `catalog/all.yaml`）。
排障：若为空 → 等一次 catalog 处理周期（~100s），或看 `kubectl ... logs deploy/backstage` 是否报 catalog location 拉取失败（确认 `catalog/all.yaml` 已 push 到 main）。

- [ ] **Step 3: 后端健康检查**

Run:
```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://idp.meirong.dev/healthcheck
```
Expected: `200`

---

## Task 10: 文档更新

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/plans/README.md`
- Modify: `docs/plans/2026-06-06-backstage-developer-portal-design.md`

- [ ] **Step 1: CLAUDE.md — Services 表加一行**

在 `## Services` 表（oracle-k3s 段）加：
```markdown
| Backstage (IDP) | oracle-k3s | `backstage` | `idp.meirong.dev` |
```

- [ ] **Step 2: CLAUDE.md — GitOps 段补 backstage Application**

在 "Managed by ArgoCD" 列表加：
```markdown
  - `backstage` App → RHDH Helm chart (`redhat-developer/rhdh-chart`, multi-source) on the **oracle-k3s external cluster**; values in `cloud/oracle/backstage/values.yaml`, secrets via Vault `secret/oracle-k3s/backstage` → ESO. Supporting resources (ns/PG/ExternalSecret) live in the oracle Kustomize tree under `cloud/oracle/manifests/backstage/`.
```

- [ ] **Step 3: design 文档置完成、plans README 改状态**

把 `docs/plans/2026-06-06-backstage-developer-portal-design.md` 文首状态由 `📐 Design` 改为 `✅ Phase 1 Implemented (2026-06-XX)`；
把 `docs/plans/README.md` 中 Backstage 行状态由 `📐 Design` 改为 `✅ Phase 1`。

- [ ] **Step 4: 提交**

Run:
```bash
git add CLAUDE.md docs/plans/README.md docs/plans/2026-06-06-backstage-developer-portal-design.md
git commit -m "docs(backstage): record Phase 1 deployment in conventions and plans"
git push
```
Expected: push 成功。

---

## Phase 1 完成定义（DoD）

- [ ] `https://idp.meirong.dev` 经 ZITADEL OIDC 可登录
- [ ] Catalog 显示 `catalog/all.yaml` 中的实体
- [ ] `backstage` Application 在 ArgoCD 为 Synced/Healthy
- [ ] Uptime Kuma 有 Backstage 监控且 UP
- [ ] 自管 PG 数据落在 `backstage-db` PVC（带 Prune=false）
- [ ] CLAUDE.md / 文档已更新

## 后续（另出计划）

- **Phase 2:** 启用 GitHub discovery 动态插件（org 内 `catalog-info.yaml` 自动入库）+ Scaffolder 黄金路径模板 + TechDocs（local builder）。
- **Phase 3:** 启用 Kubernetes + ArgoCD 动态插件 + 只读 RBAC（SA token / ArgoCD API token → Vault/ESO）+ 给 Component 加 k8s/ArgoCD 注解。
- **备份:** 把 backstage PG（`backstage-db` PVC）纳入 oracle-k3s Kopia 备份（编辑 `cloud/oracle/manifests/personal-services/backup-cronjob.yaml` 或新增 backstage 段，pg_dump `backstage` 库），并更新 `docs/runbooks/backup-recovery.md`（P1 数据）。
