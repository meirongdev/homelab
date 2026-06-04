# oracle-k3s 纳入 ArgoCD GitOps 实现计划

> **状态:** 📝 Draft / 待 review
> **结论:** 可行。采用 hub-and-spoke(复用 homelab ArgoCD),经 Tailscale `100.107.166.37:6443` 连接 oracle API。先手动同步验证,确认无 drift 后再开 selfHeal + prune。

**Goal:** 将 `cloud/oracle/manifests/`(目前 `kubectl apply -k` 手动部署)纳入 GitOps,由 homelab 现有 ArgoCD 持续校准 oracle-k3s,实现 `git push` 即部署。

**Architecture:** Hub-and-spoke 单一控制面 —— homelab ArgoCD 把 oracle-k3s 注册为外部集群,新增一个 Application 指向 `cloud/oracle/manifests`(Kustomize),destination 走 Tailscale。连接凭据(SA token + CA)存 Vault,经 ESO 物化为 ArgoCD cluster Secret,不进 Git。

**Tech Stack:** ArgoCD(`argo/argo-cd` 9.4.9,已在 homelab 运行)、Kustomize、Tailscale、HashiCorp Vault + ESO、k3s v1.34。

---

## 现状盘点(已核实 2026-06-04)

| 项 | 状态 |
|---|---|
| `cloud/oracle/manifests/` | 单一 Kustomize 树(根 `kustomization.yaml`),手动 `kubectl --context oracle-k3s apply -k` |
| 命名空间覆盖 | `rss-system` / `homepage` / `uptime-kuma` / `monitoring` / `personal-services` + 集群级资源(`ClusterSecretStore`、Gateway) |
| `secrets.yaml`(rss-system / uptime-kuma) | **全是 `ExternalSecret`**,无明文 → 进 GitOps 安全 |
| oracle-k3s ESO | 已运行,`ClusterSecretStore vault-backend` 经 Tailscale 连 homelab Vault `100.94.186.7:31952` |
| homelab `AppProject homelab` | **已预留** `https://152.69.195.151:6443` 作为合法 destination |
| homelab ArgoCD 集群注册 | ❌ 尚无 oracle cluster secret(`argocd.argoproj.io/secret-type=cluster` 为空) |
| oracle API 端点 | 公网 `152.69.195.151:6443` / Tailscale `100.107.166.37:6443` / 内网 `10.0.0.26` |
| oracle 节点 | internal `10.0.0.26`,Tailscale `100.107.166.37`,public `152.69.195.151` |
| ArgoCD ExternalSecret ignoreDifferences | 已在 `argocd-values.yaml` 全局配置(复用,oracle 的 ExternalSecret 不会误报 drift) |

---

## ⚠️ 两个必须先解决的 Blocker

### Blocker 1 — Tailscale IP 不在 API 证书 SAN 里

`cloud/oracle/ansible/playbooks/setup-k3s.yaml:157` 中 `tls-san` 只有 `{{ ansible_host }}` = `152.69.195.151`。ArgoCD 若用 `https://100.107.166.37:6443` 连接,TLS 校验会因 SAN 不匹配失败。

**方案 A(推荐,codify 进 Git):** 给 `tls-san` 补 `100.107.166.37`(可顺带补 `10.0.0.26`),然后在节点上轮换 serving 证书 —— 见 Task 1。

**方案 B(fallback):** cluster secret 里设 `tlsClientConfig.insecure: true`。Tailscale 本身是 WireGuard 加密+认证,风险可接受,但非最佳。仅在无法轮换证书时使用。

### Blocker 2 — homelab ArgoCD Pod → tailnet 出口连通性

ArgoCD `application-controller` Pod 必须能访问 `100.107.166.37:6443`。已知反向(oracle Pod → homelab Tailscale `100.94.186.7:31952`,即 ESO 连 Vault)是通的,说明节点对 tailnet 的 Pod 出口路由可用;但本方向需实测确认(可能需 Cilium masquerade 覆盖 tailnet CIDR)—— 见 Task 5。

---

## 关键文件路径

| 操作 | 文件 |
|------|------|
| 修改 | `cloud/oracle/ansible/playbooks/setup-k3s.yaml` — `tls-san` 添加 `100.107.166.37` |
| 修改 | `argocd/projects/homelab.yaml` — destinations 添加 `https://100.107.166.37:6443` |
| 新建 | `k8s/helm/manifests/argocd-oracle-cluster-external-secret.yaml` — ESO 物化 cluster Secret |
| 修改 | `argocd/applications/vault-eso.yaml` — include 上面的 ExternalSecret |
| 新建 | `argocd/applications/oracle-k3s.yaml` — 指向 `cloud/oracle/manifests` 的 Application |
| 修改 | `cloud/oracle/manifests/**`(多处)— 给有状态资源加 `Prune=false`、HTTPRoute 补 group/kind |
| 修改 | `CLAUDE.md` / `docs/CONVENTIONS.md` — 更新 oracle-k3s GitOps 段落 |
| 修改 | `docs/plans/README.md` — 登记本计划 |

---

## Task 0：保存计划(本文档)

已置于 `docs/plans/2026-06-04-oracle-k3s-argocd-gitops.md`。

---

## Task 1：给 k3s API 证书补 Tailscale SAN 并轮换

1. 编辑 `cloud/oracle/ansible/playbooks/setup-k3s.yaml`:
   ```yaml
   tls-san:
     - {{ ansible_host }}      # 152.69.195.151
     - 100.107.166.37          # Tailscale
     - 10.0.0.26               # 内网(可选)
   ```
2. 在 oracle 节点轮换 serving 证书(k3s 重启时按新 SAN 重新签发):
   ```bash
   ssh -i ~/.ssh/<key> root@100.107.166.37 \
     'rm -f /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt \
            /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key && \
      systemctl restart k3s'
   ```
   > 注:仅删除 `serving-kube-apiserver.*`,**不要**动 CA。重启 k3s 会用 `/etc/rancher/k3s/config.yaml` 里的新 tls-san 重新生成。
3. 验证 SAN 已生效:
   ```bash
   echo | openssl s_client -connect 100.107.166.37:6443 2>/dev/null \
     | openssl x509 -noout -ext subjectAltName
   # 预期:看到 IP Address:100.107.166.37
   ```

---

### Task 1 执行记录 + 事故复盘(2026-06-04)

**结果:** SAN 轮换成功(serving 证书已含 `IP Address:100.107.166.37`)。但执行过程中触发一次 oracle 路由中断,已完全恢复。

**事故经过:**
1. 编辑 playbook `tls-san` 加 `100.107.166.37`(✅)。
2. 选择用 ansible 重推 config(`--start-at-task="Write /etc/rancher/k3s/config.yaml"`)。playbook 里 `disable: [servicelb, traefik]` 因此同步进 live —— 而 live 此前**有意**只 disable `servicelb`(保留 traefik 来托管 Gateway API CRD),属既存漂移。
3. 删 serving 证书 + `systemctl restart k3s` 轮换证书。重启后 k3s 检测到 traefik 新被禁用 → 跑 `helm-delete-traefik-crd` job → **删除了 k3s-traefik 包安装的标准 Gateway API CRD**(gateways/httproutes/gatewayclasses/grpcroutes/referencegrants)。
4. CRD 删除级联回收所有 Gateway/HTTPRoute CR + `cilium` GatewayClass → Cilium 失去 LB service → cloudflared 无后端 → **8 个服务全部 502**。业务 Pod 未受影响(仅路由层)。

**根因:** playbook 的 `disable: traefik` 是埋雷 —— k3s 内置 traefik 包同时安装 Gateway API CRD,Cilium Gateway 依赖这些 CRD。live 之前不 disable traefik 正是为保住 CRD。playbook 与 live 的这处漂移从未被发现。

**恢复步骤(已执行):**
1. `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml`(对齐 homelab 的 v1.2.1 standard,且**从上游独立安装,不再归 traefik helm 管**)。
2. `kubectl apply -k cloud/oracle/manifests/` 重建 Gateway + 8 条 HTTPRoute。
3. `kubectl rollout restart deploy/cilium-operator`(CRD 删除后 operator 丢失 watcher,需重启重新注册)。
4. 重建 `cilium` GatewayClass(Cilium helm 管理的资源,也被级联删了,operator 只查找不自建;重建时带 `meta.helm.sh/release-name=cilium` 注解以便将来 helm upgrade 接管)。
5. 验证:GatewayClass Accepted=True、8 服务全部恢复(rss/home/tool/squoosh/status=200,keep=307,slot=302,pdf=401 均符合预期)、ESO 全 SecretSynced、Cilium OK。

**关键认知:**
- 恢复后 oracle 与 homelab 配置**完全一致**:traefik 禁用 + Gateway API CRD 由 `kubectl apply` 上游 v1.2.1 standard 独立安装 + `cilium` GatewayClass 由 Cilium helm 管理。homelab 的 Gateway CRD 同样带 `last-applied-configuration` 注解、无 helm label,证明也是手动 apply 的。
- `Programmed=False (AddressNotAssigned)` 是**两集群的正常稳态**(无云 LB,servicelb 禁用;cloudflared 走 service ClusterIP 不依赖 external IP)。homelab gateway 同样 False。
- **遗留 IaC 缺口:** Gateway API CRD 安装未写进 ansible(homelab 也没有,是手动步骤)。fresh rebuild 时 `just setup-k3s` 会禁用 traefik 但不装 CRD → Gateway 不工作。建议补一个 ansible 任务或 runbook 固化此依赖(见待办)。

---

## Task 2：在 oracle-k3s 创建 argocd-manager ServiceAccount

ArgoCD 需要一个能访问 oracle API 的凭据。k8s 1.24+ 不再自动签发长期 SA token,故显式创建一个 `kubernetes.io/service-account-token` 类型的 Secret 拿不过期 token。

```yaml
# 仅 bootstrap 用,kubectl --context oracle-k3s apply,不进 GitOps
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin          # 可后续收窄,起步用 cluster-admin 省事
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
```

取出 token 与 CA:
```bash
kubectl --context oracle-k3s -n kube-system get secret argocd-manager-token \
  -o jsonpath='{.data.token}' | base64 -d   # → bearerToken
kubectl --context oracle-k3s -n kube-system get secret argocd-manager-token \
  -o jsonpath='{.data.ca\.crt}'              # → tlsClientConfig.caData(已是 base64)
```

---

## Task 3：凭据存 Vault + ESO 物化为 ArgoCD cluster Secret

不把 token 写进 Git。存 Vault:
```bash
kubectl exec -n vault vault-0 -- vault kv put secret/homelab/argocd-oracle-cluster \
  bearerToken=<TOKEN> \
  caData=<CA_BASE64>
```

新建 `k8s/helm/manifests/argocd-oracle-cluster-external-secret.yaml`,ESO 生成带 `cluster` 标签的 Secret(ArgoCD 据此识别外部集群):
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: oracle-k3s-cluster
  namespace: argocd
spec:
  secretStoreRef:
    name: vault-backend            # homelab 侧 ClusterSecretStore
    kind: ClusterSecretStore
  target:
    name: oracle-k3s-cluster
    template:
      metadata:
        labels:
          argocd.argoproj.io/secret-type: cluster
      data:
        name: oracle-k3s
        server: https://100.107.166.37:6443
        config: |
          {
            "bearerToken": "{{ .bearerToken }}",
            "tlsClientConfig": { "caData": "{{ .caData }}" }
          }
  data:
    - secretKey: bearerToken
      remoteRef: { key: secret/homelab/argocd-oracle-cluster, property: bearerToken }
    - secretKey: caData
      remoteRef: { key: secret/homelab/argocd-oracle-cluster, property: caData }
```

把该文件加入 `argocd/applications/vault-eso.yaml` 的 include 列表(由 `vault-eso` Application 管理,destination 为 homelab in-cluster `argocd` namespace)。

> 若 Blocker 1 走 fallback(insecure),`config` 改为 `"tlsClientConfig": { "insecure": true }`,并去掉 caData。

---

## Task 4：AppProject 放行 Tailscale destination

`argocd/projects/homelab.yaml` 的 `destinations` 已有公网 `152.69.195.151:6443`,**追加** Tailscale 端点(三处必须严格一致:cluster secret `server` / Application `destination.server` / project 白名单):
```yaml
  destinations:
    - server: https://kubernetes.default.svc
      namespace: "*"
    - server: https://152.69.195.151:6443       # 保留作 fallback
      namespace: "*"
    - server: https://100.107.166.37:6443        # 新增,canonical
      namespace: "*"
```

---

## Task 5：预检 —— 连通性 + 集群注册

1. 实测 ArgoCD Pod 能否经 Tailscale 到达 oracle API(Blocker 2):
   ```bash
   kubectl -n argocd exec deploy/argocd-server -- \
     sh -c 'wget -qO- --no-check-certificate https://100.107.166.37:6443/version || echo FAIL'
   ```
   失败则排查节点对 tailnet CIDR 的 Pod 出口 masquerade(对照 ESO 反向已通的配置)。
2. 确认集群已注册:
   ```bash
   cd k8s/helm && argocd cluster list   # 或 kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster
   # 预期:oracle-k3s / https://100.107.166.37:6443 / Successful
   ```

---

## Task 6：创建 oracle-k3s Application —— 先手动同步,**不开 prune**

新建 `argocd/applications/oracle-k3s.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: oracle-k3s
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: homelab
  source:
    repoURL: https://github.com/meirongdev/homelab
    targetRevision: main
    path: cloud/oracle/manifests        # Kustomize 树
  destination:
    server: https://100.107.166.37:6443
    namespace: default                  # 仅作无 namespace 资源的兜底;manifests 各自声明 ns
  syncPolicy:
    # 起步阶段故意不写 automated —— 先人工对账
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=false           # namespace 已在 kustomize 树内
```

操作:
1. 提交后 `kubectl apply -f argocd/applications/oracle-k3s.yaml`(首次)。
2. `argocd app diff oracle-k3s` 审查 git 与实集群差异(CLAUDE.md 明确警告此处 **expect drift**)。
3. 修掉 diff 来源:
   - HTTPRoute 补全 `parentRefs` 的 `group`/`kind`、`backendRefs` 的 `group`/`kind`/`weight`(防 Gateway 控制器默认值导致 OutOfSync)。
   - ExternalSecret 的 SSA 漂移已被全局 ignoreDifferences 吸收,无需额外处理。
4. 手动 `argocd app sync oracle-k3s --dry-run` → 确认无意外删除后再真 sync(**此时仍无 prune**)。
5. 直至 `Synced / Healthy`。

---

## Task 7：开启 selfHeal + prune(带有状态保护)

确认手动同步干净后,给 Application 加:
```yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=false
```

**Prune 安全护栏** —— 以下含 PVC 的 manifest 必须给 PVC(及关键有状态对象)加 `argocd.argoproj.io/sync-options: Prune=false`(当前 oracle 侧 0 处标注):
- `cloud/oracle/manifests/rss-system/miniflux.yaml`(含 PostgreSQL,P1 数据)
- `cloud/oracle/manifests/rss-system/karakeep.yaml`
- `cloud/oracle/manifests/uptime-kuma/uptime-kuma.yaml`
- `cloud/oracle/manifests/personal-services/stirling-pdf.yaml`
- (`rss-system/n8n.yaml` 已从 kustomization 移除,无需处理)

**Bootstrap 依赖,勿纳管/勿 prune:** `rss-system` 的 `vault-token` Secret 由 `kubectl create secret` 手动创建(见 `base/vault-store.yaml` 注释),不在 kustomize 树内,ArgoCD 不会触碰 —— 保持现状即可,ESO 自举靠它。

> `oracle-k3s.yaml` 落在 `argocd/applications/`,会被 `root`(App-of-Apps,recursive watch)自动纳管,后续改它 `git push` 即可,无需再手动 apply。

---

## Task 8：验证 + 文档收尾

1. `cd k8s/helm && just argocd-status` —— oracle-k3s App 应为 `Synced / Healthy`。
2. 抽查 oracle 资源:`kubectl --context oracle-k3s get externalsecrets,httproute,deploy -A`。
3. 改一处 oracle manifest → `git push` → 3 分钟内自动同步,验证闭环。
4. 更新 `CLAUDE.md` / `docs/CONVENTIONS.md`:
   - 把 "oracle-k3s manifests ... currently hand-applied ... no ArgoCD ... expect drift" 段落改为"由 homelab ArgoCD 经 Tailscale 纳管"。
   - GitOps 章节的 "Managed by ArgoCD" 列表新增 `oracle-k3s` App。
   - "New Services" 流程补充 oracle 侧服务的 GitOps 路径。
5. `docs/plans/README.md` 登记本计划,状态置 Complete。

---

## 风险 / 回滚

| 风险 | 缓解 |
|------|------|
| prune 误删有状态数据 | Task 7 的 `Prune=false` 护栏;且 Task 6 先无 prune 对账 |
| oracle reconcile 依赖 homelab ArgoCD + Tailscale 链路 | **工作负载不受影响**(ArgoCD 挂只是暂停校准);链路断时人工 `apply -k` 仍可用 |
| SA token 过期 | 用 `service-account-token` 类型 Secret(不过期);如收窄 RBAC 另行评估 |
| API 公网暴露 | 走 Tailscale;稳定后可考虑从 `tls-san` / NSG 移除公网 6443 |
| 单一大 Application sync 粒度粗 | 起步用单 App(对应现状单 kustomize);后续如需按 namespace 拆分,可加 sync waves 或拆多 App |

## 回滚步骤

1. 删 Application:`kubectl delete app oracle-k3s -n argocd`(finalizer 默认会连带 prune,**回滚时改用** `--cascade=orphan` 保留实集群资源)。
2. 删 cluster secret ExternalSecret,从 `vault-eso.yaml` include 移除。
3. 恢复手动流程:`kubectl --context oracle-k3s apply -k cloud/oracle/manifests/`。

---

## 待决策(留给 review)

- RBAC 是否一步到位收窄(非 cluster-admin)?起步建议 cluster-admin,稳定后按需收窄。
- 单 Application vs 按 namespace 拆多 Application —— 本计划默认单 App,简单且贴合现状。
- 是否最终从 `tls-san` 移除公网 IP、彻底只走 Tailscale —— 视外部访问需求,本计划暂保留双端点。
