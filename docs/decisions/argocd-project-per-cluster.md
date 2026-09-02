# ArgoCD 每集群一个 AppProject：让「装错集群」由服务端拒绝，而不只靠 CI

> 日期: 2026-09-02
> 状态: ✅ 已实施（现网 cutover 顺序见文末，第 3 步随合并到 main 自动完成）
> 关联：[reference/argocd-app-patterns.md](../reference/argocd-app-patterns.md) ·
> [reference/manifest-safety-checks.md（H2）](../reference/manifest-safety-checks.md) ·
> [runbooks/argocd-control-plane-on-oracle.md](../runbooks/argocd-control-plane-on-oracle.md)

## Context

- 2026-08-02 控制面迁到 oracle-k3s 后，32 个 Application 全挂在一个 `homelab` AppProject 下，
  `destinations` 三条（in-cluster / homelab Tailscale / oracle Tailscale）且 namespace 全 `*`。
  其中 oracle Tailscale 那条自控制面迁移起就没有任何 Application 引用，是死配置。
- 「Application 写错 destination 把 homelab 全套装到 oracle」只有 CI 的 H2（path ↔ destination）
  能拦，而 chart 型 source 没有 `path`，H2 对 13 个 chart App 完全没网可兜
  （manifest-safety-checks.md 自己写着这一句）。
- AppProject 不在 root App 的托管路径下：改 `sourceRepos` 必须手工 `kubectl apply`，
  四篇 runbook / ADR 各自提醒一遍，还是漏过（opencost 落地时踩过）。
- 安全面：公网集群上的 ArgoCD 持有 homelab（Vault 所在）的 cluster-admin 凭据，
  而 project 这层权限边界是通配的。security.md 此前没有记录这条。

## Options

1. **维持单 project，靠 CI**（现状）。chart 型 App 永远没有静态兜底。
2. **每集群一个 project，destination 只一条；root / projects 两个元 App 挂内置 `default`。** ← 采纳。
3. 再细一层：按 namespace 拆 platform / app project，这样才能开 `orphanedResources.warn`。
   收益要等有人消费那条告警时才成立，先不做；拆法写在 `homelab.yaml` 的注释里，触发条件见文末。

## Decision

- `argocd/projects/homelab.yaml`：destination 只留 `https://100.94.186.7:6443`；
  新建 `argocd/projects/oracle-k3s.yaml`：只留 `https://kubernetes.default.svc`。
  `sourceRepos` 按各集群 Application 实际用到的 chart 源列（`argo-helm` 删除：ArgoCD 本体是
  manual-helm，没有 App 引用它）。`orphanedResources.ignore` 按集群拆：kyverno TLS 与 Vault PVC
  只在 homelab，CNPG 的 `cnpg-default-monitoring` 只在 oracle。
- 新 Application `projects`（project `default`，source `argocd/projects`）托管两个 AppProject，
  `prune: false`：AppProject 带 `resources-finalizer`，误删文件不该级联到该 project 下的 App。
  root 也改挂 `default`：元 App 若挂业务 project，会出现「App 管理自己所属 project」的自引用。
- H2 扩展三条：Application 的 `project` 必须与 destination 对应；source 在 `argocd/` 下的元 App
  必须挂 `default`，其它 App 禁用 `default`；AppProject 必须且只能有一条 destination。
- `just deploy-argocd` 第 2 步改为 apply 整个 `argocd/projects/`，只作全新装机的 bootstrap。

## Consequences

- 写错 destination 现在是两道网：服务端 `destination server ... is not permitted in project`
  （响亮，sync 直接失败）+ CI 的 H2。chart 型 App 首次有了静态兜底（project ↔ destination）。
- 新加 chart 源：改对应集群的 project 文件并 `git push`，不再手工 apply。相关 runbook 已改。
  ⚠️ **但同一个 commit 里同时改 Application 的 `repoURL` 与 project 的 `sourceRepos` 时，
  中间有个窗口**：`projects` App 与消费方 App 是两个独立的同步单元，消费方可能先刷新，
  于是报 `application repo … is not permitted in project`（App 变 `Unknown`，不 prune、不动
  工作负载）。2026-09-03 换 cnpg chart 源时实测到。**处置**：手工推一次 `projects` 先行 ——
  `kubectl --context oracle-k3s -n argocd annotate app projects argocd.argoproj.io/refresh=hard --overwrite`，
  然后再刷消费方；或者干脆等下一轮 3 分钟轮询，它会自愈。
- 新集群 = 新 project 文件 + 登记进 `scripts/check-manifests.py` 的 `PROJECT_FOR_SERVER`，
  否则 H2 报「不在已知集群表里」。这是刻意的：集群表只该有一份。
- `default` project 全放行，只给 root / projects 用；其它 App 用它会被 H2 拦。
- **残余风险**（已记入 security.md §11）：oracle 上的 ArgoCD 仍持有 homelab 的 cluster-admin。
  拆 project 只收窄「误投」，不收窄凭据本身的权限；真收窄要给 homelab 侧 `argocd-manager` SA 降权，
  成本与收益另评。

## 现网 cutover 顺序（2026-09-02）

顺序不能反：root 不自管（root.yaml 改了得手工 apply），而 `projects` App 一旦建立就会立刻
把 homelab project 的 in-cluster destination 删掉，届时任何还挂在 homelab project 下、
目标为 in-cluster 的 App 都会失效。

1. `kubectl --context oracle-k3s apply -f argocd/projects/oracle-k3s.yaml`：新建，无副作用。✅ 已做
2. `kubectl --context oracle-k3s apply -f argocd/applications/root.yaml`：root 改挂 `default`。✅ 已做
3. 合并到 main → root 同步：9 个 oracle App 改挂 `oracle-k3s`，`projects` App 建立并收敛两个 project
   文件。homelab project 到这一步才失去 in-cluster destination，而此时已没有 App 依赖它。
4. 验收：`kubectl --context oracle-k3s -n argocd get app` 全 Synced；
   `kubectl --context oracle-k3s -n argocd get appproject homelab -o jsonpath='{.spec.destinations[*].server}'`
   只剩 homelab 那一条。

回滚：把旧版 `homelab.yaml` apply 回去、App 的 project 改回 `homelab`、删掉 `oracle-k3s` project。
整个过程不触碰任何工作负载对象。

## 重评触发条件

- 有人要消费 `orphanedResources` 的 warning 时 → 做 Option 3，把 kube-system / monitoring /
  external-secrets / argocd 四个 manual-helm ns 的 App 拆到 platform project。
- 第三个集群入编时 → 直接照 `oracle-k3s.yaml` 复制一份，并登记 `PROJECT_FOR_SERVER`。
