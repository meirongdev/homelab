# Runbook — 新增一个服务

> Last updated: 2026-09-06
>
> **触发条件**：要往 homelab 或 oracle-k3s 部署一个新的自研 / 自托管服务（会带一个新子域名）。
> **成功判定**：五条同时成立——① `rollout status` 完成且 pod `Running`；② 该 HTTPRoute 的
> `.status.parents[].conditions` 里 `Accepted=True` **且 `ResolvedRefs=True`**；
> ③ `dig +short <sub>.meirong.dev` 返回 CNAME；④ `curl` 公网地址返回 200/302（**不是 503**）；
> ⑤ homepage 卡片与 Uptime Kuma 监控各多一条并显示 up。
> **回滚**：`git revert` 那一个提交并 push，ArgoCD 会 prune 掉负载。☠️ 两样东西**不会**跟着回滚：
> **DNS 记录**（external-dns 是 `upsert-only`，删 HTTPRoute 不删记录，得手删）和
> **PVC**（`Prune=false` 只保证不 prune，备份归属见步骤 2 的 H4；数据要自己清）。
> **本文不复制实测数值**（requests 余量、内存 available 都会漂）——数值真相源是集群本身与
> [reference/k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md)。

本仓库是 ArgoCD GitOps：`git push` 后 3 分钟内自动同步，**服务清单一律不要 `kubectl apply`**
（selfHeal 会拉回）。⚠️ 只有 manual-helm 四件套（Cilium / Vault / ESO / ArgoCD 本体）是
「提交 ≠ 部署」，新增服务不属于这一类。

**新子域名不需要动 DNS**：两条隧道各有一条 `*.meirong.dev` 通配路由，external-dns 从 HTTPRoute
建 CNAME。**写 HTTPRoute 就是改 DNS**，不要动 `cloudflare/terraform`。

## 步骤 1 — 定落点与素材

| 要问清的字段 | 例 |
|---|---|
| 集群 / 资源画像 | 见下方判据 |
| 服务名（小写 kebab）· 子域名 | `my-app` → `myapp.meirong.dev` |
| 镜像（☠️ 有没有 `linux/arm64`）· 容器端口 · Service 端口 | `ghcr.io/author/my-app:1.2.3` · `8080` |
| Namespace（默认 `personal-services`）· 要不要 PVC · 要不要 ExternalSecret | — |
| homepage 分组 / 中文描述 / 图标 | `个人服务` · `我的应用` · `my-app.png` |

**落点看资源画像，不看「云端优先」**——判据、被否决项与取舍在
[decisions/cluster-placement-for-new-services.md](../decisions/cluster-placement-for-new-services.md)，
容量数值去那里或现测，别在本文维护。速记：

- **homelab**：持续吃 CPU（转码 / 索引 / 构建 / 推理 / 批处理）、公网大流量、要 LAN 或本地数据、
  **只有 amd64 镜像**。⚠️ 控制面是热笔记本且同机跑 Prometheus/Grafana/Alertmanager/Vault，
  计算型 pod **必须带显式 CPU limit**，否则跑飞会连累监控栈。
- **oracle-k3s**（轻量无状态的默认落点）：☠️ **不是随便塞**——requests 按实测填，
  别照搬上游 manifest 常见的 50m–100m；非核心服务挂 `priorityClassName: bulk`。
  ⚠️ 公网服务**不要**挂 `bulk`（被先驱逐的不是该有优先级的东西）。
- ☠️ oracle 是 **arm64**：先确认镜像有 `linux/arm64`。按 digest pin 时钉**多架构 manifest-list
  digest**，不是单架构 digest——钉错的表现是调度上去才 `Exec format error`。

两集群的文件规矩不同，先对一眼：

| | homelab | oracle-k3s |
|---|---|---|
| 清单 | `k8s/helm/manifests/<app>/<service>.yaml` | `cloud/oracle/manifests/<app>/<service>.yaml` |
| HTTPRoute 放哪 | **单独一个** `k8s/helm/manifests/gateway/route-<service>.yaml` | 与服务清单同一个文件 |
| Gateway parentRef | `homelab-gateway` @ `kube-system`，**port 80** | `oracle-gateway` @ `kube-system`，**port 80** |
| 注册 | 无——目录即 App，推上去自动同步 | ☠️ 必须登记进 `cloud/oracle/manifests/kustomization.yaml` |
| 密钥 | `secret/homelab/<service>` | `secret/oracle-k3s/<service>` |

## 步骤 2 — Deployment + Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <service-name>
  namespace: <namespace>
  labels:
    app: <service-name>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <service-name>
  template:
    metadata:
      labels:
        app: <service-name>
    spec:
      containers:
        - name: <service-name>
          image: <image>
          ports:
            - containerPort: <container-port>
---
apiVersion: v1
kind: Service
metadata:
  name: <service-name>
  namespace: <namespace>
spec:
  selector:
    app: <service-name>
  ports:
    - protocol: TCP
      port: <service-port>
      targetPort: <container-port>
```

- **requests/limits 要显式写**。homelab 有 LimitRange 兜底 + Kyverno 审计，
  oracle-k3s **两者都没有**——那里不写就是真的不设限。
- **PVC 一律 `local-path`**（两集群唯一的 StorageClass；`nfs-client` provisioner 已于
  2026-07-11 卸载，写它的 PVC 会永远 `Pending`）。sqlite 类应用尤其不能用 NFS。
  唯一例外是只读媒体的静态 NFS PV，边界见
  [decisions/multimedia-repository-nfs-readonly.md](../decisions/multimedia-repository-nfs-readonly.md)。
- ☠️ **新建 PVC 必须同时加进备份白名单**：restic 是**显式白名单**，不加进去就静默不备份
  （CI 规则 H4 会拦，但「加了豁免条目」和「真在备份」是两回事）。
  改 [`backup/overlays/<cluster>/backup-script.yaml`](../../backup/overlays)，
  程序见 [reference/storage.md](../reference/storage.md)。
- 数据不可再生时给 PVC 加 `argocd.argoproj.io/sync-options: Prune=false`——它只挡 prune，
  **不代替备份**。
- 若服务需要**新 Namespace**：☠️ `namespace.yaml` 必须独占文件（H1）且**显式写 PSA 等级标签**
  （H5）——漏写不是「没定级」，是静默吃内置默认 `privileged`。

## 步骤 3 — HTTPRoute（= 这一步就是改 DNS）

```yaml
---
# HTTPRoute: <subdomain>.meirong.dev -> <service-name>
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <service-name>
  namespace: <namespace>
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: <homelab-gateway|oracle-gateway>
      namespace: kube-system
      port: 80          # 两集群的 listener 都是 80，TLS 在 Cloudflare 边缘终止
  hostnames:
    - "<subdomain>.meirong.dev"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: <service-name>
          port: <service-port>
          weight: 1
```

所有字段都显式写出来，否则 ArgoCD 会因为 live/declared 差异长期 OutOfSync。

**Gateway 在 `kube-system`，跨 ns 引用后端必须要 ReferenceGrant**（写在**目标** ns）。
已有的 grant：homelab `personal-services` / `monitoring` / `vault` / `argocd`，
oracle `personal-services` / `homepage` / `rss-system`。先查一遍再决定要不要新建：

```bash
kubectl --context <k3s-homelab|oracle-k3s> get referencegrant -A
```

```yaml
---
apiVersion: gateway.networking.k8s.io/v1beta1   # ☠️ 必须是 v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-to-<namespace>
  namespace: <namespace>
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: <namespace>
  to:
    - group: ""
      kind: Service
```

⚠️ 用 `v1beta1` 的理由**不是**「`v1` 不存在」——`v1` 早就有了，而是本仓库现装的 Gateway API
CRD 里 `v1beta1` 仍是 **storage 版本**，写 `v1` 属于无谓 churn 且历史上报过
`ComparisonError` 让整个 App 不可用。判据永远是
`kubectl get crd referencegrants.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}'`
（全文见 [manifest-safety-checks.md 的 H3](../reference/manifest-safety-checks.md)）。

☠️ **首次部署必查 `ResolvedRefs`（路由与负载的排序竞态，2026-08-01 实测）**：路由与工作负载由
不同 App 同步，无先后保证。路由先落地时 Cilium 记 `ResolvedRefs=False / BackendNotFound`，
且 **Service 后来建好也不会自动重算**（`observedGeneration` 停在 1），表现为 `gateway` App 长期
Degraded + 域名 503。碰一下路由强制 reconcile：

```bash
CTX=<k3s-homelab|oracle-k3s>
kubectl --context $CTX -n <namespace> get httproute <service-name> \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}{"\n"}'   # 期望 True
kubectl --context $CTX -n <namespace> annotate httproute <service-name> reconcile-nudge="$(date +%s)" --overwrite
kubectl --context $CTX -n <namespace> annotate httproute <service-name> reconcile-nudge-  # 生效后删掉，别留 git 之外的漂移
```

## 步骤 4 — 注册进 GitOps

**homelab**：什么都不用做。`personal-services` App 同步整个目录（一目录 ↔ 一 App，
所有权地图见 [manifests/README.md](../../k8s/helm/manifests/README.md)），推上去自动接手。

**oracle-k3s**：☠️ 它的 kustomize 树仍是**显式列表**，没登记的文件静默不生效：

```bash
cd /Users/matthew/projects/homelab
# 编辑 cloud/oracle/manifests/kustomization.yaml，在 resources: 下加一行
#   - personal-services/<service-name>.yaml
```

换逻辑分组（比如基础设施）就放进对应的 `k8s/helm/manifests/<app>/`；全新的一组则要新建目录
**加** `argocd/applications/<app>.yaml`（`root` App-of-Apps 推上去自动发现）。新建 App 时
☠️ `path` 与 `destination` 必须同集群（H2），且 chart 型 App 的 `$values` 只能引用**本集群那棵
values 树**：homelab → `k8s/helm/values/`，oracle → `cloud/oracle/values/`。

## 步骤 5 — homepage 卡片

homepage 跑在 oracle-k3s，改
[`cloud/oracle/manifests/homepage/homepage.yaml`](../../cloud/oracle/manifests/homepage/homepage.yaml)
里 ConfigMap 的 `services.yaml:` 对应分组：

```yaml
        - <Display Name>:
            icon: <icon>.png
            href: https://<subdomain>.meirong.dev
            description: <中文描述>
            kubernetes:
              namespace: <namespace>
              container: <service-name>
              label_selector: app=<service-name>
```

⚠️ 该 ConfigMap 用 `subPath` 挂载，**同步它不会重启 pod**——卡片不会出现，必须手动
`kubectl --context oracle-k3s -n homepage rollout restart deploy/homepage`。

## 步骤 6 — Uptime Kuma 监控

在 [`cloud/oracle/manifests/uptime-kuma/provisioner.yaml`](../../cloud/oracle/manifests/uptime-kuma/provisioner.yaml)
的 `MONITORS` 列表加一条：

```python
    {"name": "My Service", "url": "https://<subdomain>.meirong.dev"},
```

oracle 内的服务用集群内地址 `http://<service>.<namespace>.svc:<port>`，homelab 的用公网域名。
会重定向到登录页的加 `"accepted_statuscodes": ["300-399"], "maxredirects": 0`。
⚠️ provisioner 是声明式的，**会删掉不在列表里的监控**——所以退役服务也在这里删条目。

## 步骤 7 — 提交并自查

```bash
cd /Users/matthew/projects/homelab
just check                       # 与 CI 同一批脚本（pre-push 也会跑）
git add <本次涉及的文件>
git commit -m "feat: add <service-name> service"
git push origin main
```

`just check` 里最常拦到新建服务的是：**H1**（Namespace 没独占文件）·
**H2**（App 的 path / `$values` / project 与 destination 不同集群）·
**H4**（新 PVC 没有备份归属）· **H5**（新 ns 没写 PSA 等级）。

## 步骤 8 — 验收（对照文首的成功判定）

```bash
CTX=<k3s-homelab|oracle-k3s>
kubectl --context $CTX -n <namespace> get pods -l app=<service-name>
kubectl --context $CTX -n <namespace> rollout status deployment/<service-name> -n <namespace>
kubectl --context $CTX -n <namespace> get httproute <service-name> -o jsonpath='{.status.parents[0].conditions}'
dig +short <subdomain>.meirong.dev
curl -sS -o /dev/null -w '%{http_code}\n' https://<subdomain>.meirong.dev
```

external-dns 按自己的周期收敛，记录可能比同步晚一分钟；`https://argocd.meirong.dev` 上该
Application 应是 `Synced + Healthy`。

⚠️ **503 + `ResolvedRefs=True` + 路由有 `.status`** 通常是 Gateway API CRD 与 Cilium 版本不配对
（旧路由照常 200、新路由静默 503），跑 `cd k8s/helm && just deploy-gateway-api-crds`；
判据与「为什么 curl 旧域名不算证据」见
[reference/networking-ingress.md](../reference/networking-ingress.md)。

## 退役一个服务

1. 删清单与 `route-<service>.yaml`（或该服务的 HTTPRoute），oracle 侧同时从
   `kustomization.yaml` 摘掉；push，ArgoCD prune。
2. ☠️ **PVC 不会被 prune**（`Prune=false` + `Prune` 语义），要手工清；备份里的数据按
   [backup-recovery.md](backup-recovery.md) 处理。
3. **DNS 记录手删**：external-dns 是 `upsert-only`。
4. Uptime Kuma 从 `MONITORS` 删条目（provisioner 会 prune）。
5. 若它的 ns 里已无别的负载，最后删 `namespace.yaml`（H1：它会带走整个 ns）。
