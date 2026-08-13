# ArgoCD 控制面运行在 oracle-k3s

> Last updated: 2026-08-06
> Status: 生效事实 + 迁移 SOP
> 触发条件：重装/升级 ArgoCD、集群凭据过期、需要回滚到 homelab 控制面、
> 或要完成 2026-08-02 迁移的收尾步骤。
> 成功判定：`just argocd-status`（在 `k8s/helm/`）列出 28 个 App 全部 Synced/Healthy，
> 且 `argocd.meirong.dev` 可登录。

## 现状（一句话）

**ArgoCD 装在 oracle-k3s，经 Tailscale 纳管 homelab。** 2026-08-02 之前正好相反。

| 项 | 值 |
|---|---|
| 控制面所在 | `oracle-k3s` / ns `argocd`，chart `argo/argo-cd` **10.1.4**（manual-helm，不自管） |
| 部署命令 | `cd k8s/helm && just deploy-argocd`（`argocd_ctx := "oracle-k3s"`） |
| values | `values/argocd.yaml` + `values/argocd-oracle.yaml`（后者只覆盖 `crds.install=true`） |
| 被纳管的外部集群 | homelab `https://100.94.186.7:6443`（Tailscale） |
| 集群凭据 | ESO ← Vault `secret/homelab/argocd-homelab-cluster`，见 `cloud/oracle/manifests/argocd/homelab-cluster-external-secret.yaml` |
| 入口 | `argocd.meirong.dev` → oracle 隧道 → `oracle-gateway` → `argocd-server:80` |

### ☠️ 最容易踩的一条

`destination.server: https://kubernetes.default.svc` 的意思是**「ArgoCD 自己所在的集群」**，
不是「homelab」。控制面搬家之后同一个字符串的所指跟着变。所以：

- homelab 的负载**必须**写 `https://100.94.186.7:6443`（19 个）
- oracle 自己的负载写 `https://kubernetes.default.svc`（7 个）
- `root` 跟着控制面走，保持 in-cluster
  （2026-08-02 迁移当时这里是 2 个——另一个是 `argocd-image-updater`，已于
  2026-08-03 退役，其残留的两个 ExternalSecret 也在 2026-08-06 一并清除）

在 destination 尚未重写时对新控制面 `kubectl apply -f argocd/applications/`，
会把整套 homelab 负载（Vault/Kyverno/Prometheus/personal-services…）**部署到 oracle 上**。
`just deploy-argocd` 因此**不含** Application 注册，那一步单独放在 `just deploy-argocd-apps`。

---

## 日常操作

```bash
cd k8s/helm
just argocd-status        # 28 个 App 的 Sync/Health
just argocd-sync          # 触发全量 refresh
just argocd-password      # 初始 admin 密码
just deploy-argocd        # 重装/升级 chart（幂等）
```

改配置仍然是 `git push` → 3 分钟轮询。`root` App 自管 Application 对象，
新增 App 只需往 `argocd/applications/` 放文件。

### bootstrap 依赖（不在 Git，重建时要手工做）

homelab 侧的 `kube-system/argocd-manager` SA + ClusterRoleBinding(cluster-admin) +
`argocd-manager-token` Secret。刻意不进 GitOps —— 否则 ArgoCD 要靠自己创建
自己纳管 homelab 所需的凭据，成环。重建：

```bash
# 1. 建 SA/CRB/token（内容见 cloud/oracle/manifests/argocd/homelab-cluster-external-secret.yaml 头注）
kubectl --context k3s-homelab apply -f <上述三件套>

# 2. 取出并写进 Vault
BEARER=$(kubectl --context k3s-homelab -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
CADATA=$(kubectl --context k3s-homelab -n kube-system get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}')
VT=$(kubectl --context k3s-homelab -n external-secrets get secret vault-token -o jsonpath='{.data.token}' | base64 -d)
printf '{"bearerToken":"%s","caData":"%s"}' "$BEARER" "$CADATA" \
  | kubectl --context k3s-homelab exec -i -n vault vault-0 -- \
      env VAULT_TOKEN="$VT" vault kv put secret/homelab/argocd-homelab-cluster -

# 3. ESO 1 小时内物化；要立刻生效就删 Secret 让它重建
kubectl --context oracle-k3s -n argocd delete secret homelab-cluster
```

homelab k3s 的 apiserver 证书 SAN **已含** `100.94.186.7`（实测确认），故 `caData` 可正常校验，
不需要 `insecure`。若日后重建节点导致 SAN 丢失，症状是 ArgoCD 报 x509 而非超时。

---

## 域名切换（`argocd.meirong.dev` 在两个集群之间搬）

⚠️ **只加 HTTPRoute 不会把域名切过来，而且会制造重复 CNAME。**

两个集群各跑一个 external-dns，都是 `--policy=upsert-only`（永不删记录），
owner TXT 分别是 `homelab-externaldns` / `oracle-externaldns`。一旦目标集群出现同名
HTTPRoute，它的 external-dns 因为「看不到自己拥有的同名记录」会把它当作需要**新建**，
去 Cloudflare 建一条重复 CNAME。

正确顺序：

```bash
# 1. 先摘掉源集群的路由（homelab 侧路由在 gateway App 的目录里）
git rm k8s/helm/manifests/gateway/route-argocd.yaml && git commit && git push
#    等 gateway App 同步完成，确认 HTTPRoute 已消失
kubectl --context k3s-homelab get httproute -n argocd

# 2. 手工删 Cloudflare 上的 CNAME + owner TXT（upsert-only 不会自己删）
#    两条记录同名，都要删：argocd.meirong.dev 的 CNAME 与 TXT
#    验证：dig +short TXT argocd.meirong.dev @1.1.1.1  → 应为空

# 3. 再把目标集群的路由挂进 kustomization
#    取消 cloud/oracle/manifests/kustomization.yaml 里 argocd/route-argocd.yaml 那一行的注释
git commit && git push

# 4. 验证（1-2 分钟后）
dig +short TXT argocd.meirong.dev @1.1.1.1   # owner 应变成 oracle-externaldns
curl -sI https://argocd.meirong.dev | head -1
```

ZITADEL 侧**不需要改**：回调地址仍是 `https://argocd.meirong.dev/auth/callback`，
域名没变，只是背后换了集群。

---

## 回滚到 homelab 控制面

迁移后到「删掉 homelab argocd」之前的任何时刻都可回滚，代价是几分钟不同步。

```bash
# 1. 停 oracle 控制面
kubectl --context oracle-k3s scale sts -n argocd argocd-application-controller --replicas=0

# 2. 回滚 git（destination 重写那个提交）
git revert <destination 重写的 commit> && git push

# 3. 恢复 homelab 控制面
kubectl --context k3s-homelab scale sts -n argocd argocd-application-controller --replicas=1

# 4. homelab 上的 Application 对象在冻结期间从未被改写，会直接按旧 destination 恢复工作
kubectl --context k3s-homelab get application -n argocd
```

若域名已切走，回滚时同样要按上面「域名切换」的顺序反向做一遍。

---

## ☠️ 退役 homelab ArgoCD 的地雷：Application 的 finalizer

**直接 `kubectl delete ns argocd` 或 `helm uninstall` 会删掉 homelab 上的一切。**

每个 Application 都带 `finalizers: [resources-finalizer.argocd.argoproj.io]`，
它的语义就是**级联删除该 App 管理的全部资源**。homelab 上那 21 个残留 Application 对象
的 destination 仍指向 `kubernetes.default.svc`（= homelab 自己），删它们 =
删掉 Vault、Kyverno、Prometheus、personal-services……

正确做法是**先摘 finalizer 再删**：

```bash
# 1. 摘掉所有 Application 的 finalizer（此后删除不再级联）
kubectl --context k3s-homelab get application -n argocd -o name \
  | xargs -I{} kubectl --context k3s-homelab patch {} -n argocd \
      --type=merge -p '{"metadata":{"finalizers":null}}'

# 2. 确认已摘干净（应无输出）
kubectl --context k3s-homelab get application -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.finalizers}{"\n"}{end}' | grep -v ' $'

# 3. 删 Application 与 AppProject（此时只删对象本身）
kubectl --context k3s-homelab delete application -n argocd --all
kubectl --context k3s-homelab delete appproject -n argocd --all   # AppProject 同样带 finalizer

# 4. 卸载 chart 并删 ns
helm uninstall argocd -n argocd --kube-context k3s-homelab
kubectl --context k3s-homelab delete ns argocd

# 5. CRD 留着还是删？homelab 上已无 CR，可删；但留着无害且便于回滚，建议观察期内先留。
```

**做完第 1 步之前不要执行任何删除。** 摘 finalizer 是幂等的，多做一次没有副作用。

---

## 相关

- 迁移的通盘取舍：[../plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md](../plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md)
- 反方向（homelab 纳管 oracle）的原始设计：[../plans/networking/2026-06-04-oracle-k3s-argocd-gitops.md](../plans/networking/2026-06-04-oracle-k3s-argocd-gitops.md)
- Application 写法约定：[../reference/argocd-app-patterns.md](../reference/argocd-app-patterns.md)
