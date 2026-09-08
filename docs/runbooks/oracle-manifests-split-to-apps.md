# 把 oracle 的单体 kustomize 树拆成一目录一个 ArgoCD App

> Last updated: 2026-09-08
> **触发条件**：想让 oracle 侧的清单布局与 homelab 对齐（一目录 ↔ 一个 App）。
> 不是故障处置，**需要一个维护窗口 + 有人盯着**，不要随手合并触发。
> **成功判定**：每个新 App `Synced/Healthy`；`oracle-k3s` App 的资源树只剩 `base/` 与
> 各 `namespace.yaml`；全部 11 个 ns 仍在；`kubectl get pod -A` 无新增重启。
> **回滚**：见文末，每一步都可单独回退，不触碰任何 PVC。

## 为什么要做

`cloud/oracle/manifests/` 是一棵 140 个对象的单体 kustomize 树，由**一个** ArgoCD App
（`oracle-k3s`）同步，涵盖 ZITADEL、共享数据库、Uptime Kuma、个人服务等十二组东西。两个后果：

- **任一文件坏掉，整个集群的同步一起停**（渲染失败是 App 级的，不是对象级的）。
- `kustomization.yaml` 是一份**显式登记清单**，新文件漏登记就静默不生效 ——
  [manifests-directory-per-app](../decisions/manifests-directory-per-app.md) 里把这个坑
  记为「第 3 坑换个马甲」，homelab 侧 2026-07-31 已经改掉，oracle 侧当时没跟。

## ☠️ 拆之前必须理解的机制

ArgoCD 按 **tracking 注解**（v3.x 是 `argocd.argoproj.io/tracking-id`）判断一个对象归谁管。
`prune` 只删「带我的 tracking-id、但已经不在我的渲染结果里」的对象。于是：

**如果一个文件从旧树里删掉、同时出现在新 App 的目录里，而旧 App 先同步**，
它看到的就是「我的对象没了」→ **prune**。新 App 随后会把它建回来。

对不同对象，这个瞬间的代价差别极大：

| 对象 | 被 prune 再重建的后果 |
|---|---|
| Deployment / Service / HTTPRoute | 几十秒不可用，无数据损失 |
| PersistentVolumeClaim | **本树 6 个 PVC 全部带 `Prune=false`**（2026-09-02 核对），不会被删 |
| **Namespace** | ☠️ **级联删光该 ns 下的一切**，`Prune=false` 拦不住（被 prune 的是 ns）。2026-08-03 真这样删过一次（[复盘](../records/2026-08-03-namespace-prune-cascade.md)）|

**所以本 runbook 的第一条纪律是：`namespace.yaml` 一律不动。**11 个 Namespace 全部留在
`oracle-k3s` App 里，新 App 只接管工作负载，并且 `CreateNamespace=false`。
这样最坏情况退化成「某个无状态服务几十秒不可用」，级联删除这条路直接不存在。

## 拆分边界

`base/` 与全部 `namespace.yaml` **留在 `oracle-k3s`**（网关、cloudflared、ClusterSecretStore、
CoreDNS 扩展、PriorityClass —— 它们是集群级地基，且 `base/` 里就内嵌着两个 Namespace）。

以下五组各拆一个 App。`calibre-metadata/` 早就是独立 App，不在此列。

| 新 App | 目录 | 目标 ns | 对象数 | 备注 |
|---|---|---|---|---|
| `oracle-personal-services` | `personal-services/` | `personal-services` | 52 | 最大的一组，含 5 个 PVC（均 `Prune=false`）|
| `oracle-monitoring` | `monitoring/` | `monitoring` | 22 | 含 otel-collector 的 `configMapGenerator`，**必须留 kustomize**（见下）|
| `oracle-rss` | `rss-system/` | `rss-system` | 10（+ns） | ✅ **2026-09-08 已拆完**。⚠️ 它的 HTTPRoute 与 ReferenceGrant 不在本目录里、而在 `base/gateway.yaml`，所以仍归 `oracle-k3s`，拆分不影响 `rss.meirong.dev` |
| `oracle-uptime-kuma` | `uptime-kuma/` | `personal-services` | 7 | ⚠️ 它的 `namespace.yaml` 声明的是 **personal-services**，不是同名 ns |
| `oracle-zitadel` | `zitadel/` | `zitadel` | 7 | 身份面，单独放到最后做 |

☠️ **`monitoring/` 那组不能改成目录源**：otel-collector 的配置走 `configMapGenerator`
（名字带内容哈希 → 配置一变 DaemonSet 自动滚动）。改成目录源就退回「ConfigMap 变了
pod 根本不重启」，那正是 2026-08-02 踩过的坑。它的新 App 要指向一个**新建的
`monitoring/kustomization.yaml`**，把 generator 一起搬过去。

## 执行

每组**独立走一遍**下面五步（第 2 与第 4 步是同一个 prune 窗口的两端，连着拆多组时
可以只开一次）。先拿 `oracle-rss`（最小、纯无状态、无 PVC）练手 —— 2026-09-08 已完成，
本文的实测数字都出自那一轮。

### 1. 建新 App，但**先不动旧树**

```bash
cd /Users/matthew/projects/homelab
# 写 argocd/applications/oracle-rss.yaml：
#   project: oracle-k3s
#   destination.server: https://kubernetes.default.svc
#   source.path: cloud/oracle/manifests/rss-system
#   syncOptions: CreateNamespace=false + ServerSideApply=true
git add argocd/applications/oracle-rss.yaml && git commit && git push
```

此刻两个 App 渲染出**完全相同**的对象集合，短暂共管。ArgoCD 会在资源树上标 shared，
这是预期的，不是故障。

**判据（必须全部满足才继续）**：

```bash
kubectl --context oracle-k3s -n argocd get app oracle-rss \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'   # 期望 Synced Healthy
kubectl --context oracle-k3s -n rss-system get pod                     # 无新增重启
```

### 2. 临时关掉 `oracle-k3s` 的 prune

> ☠️ **本节 2026-09-08 重写。原来写的是「新 App 同步一次就会抢到 tracking，
> 这是第 3 步安全的前提」——那是错的，照着做会死锁。** 实测（ArgoCD v3.4.5）：
> ArgoCD **不会**把已被别的 App 拥有的对象让出去，新 App 只会挂
> `SharedResourceWarning: Deployment/miniflux is part of applications
> argocd/oracle-rss and oracle-k3s` 并**永久 OutOfSync**。
> 判据：`generation` 全程不变（本次 10 个对象均如此），说明两边**没有**互相改写，
> 是新 App 在拒绝接管 —— 不是「还没同步」，手动 Sync 多少次都不会翻。
>
> 所以交接只可能发生在「旧 App 不再渲染这些对象」的那一刻，也就是第 3 步。
> 而那一刻若 prune 开着，旧 App 看到的是「我的对象没了」→ **先删除**，
> 再由新 App 重建：无状态对象也会有几十秒到几分钟不可用（两个 App 的轮询不同步）。

```bash
# 把 argocd/applications/oracle-k3s.yaml 的 automated.prune 改成 false，push
git commit && git push
# 确认已生效（root App 同步后）
kubectl --context oracle-k3s -n argocd get app oracle-k3s \
  -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'      # 期望 {"prune":false,"selfHeal":true}
```

关掉之后第 3 步变成**零停机**：旧 App 只是不再管这些对象，对象原地不动，
新 App 接管注解。2026-09-08 拆 rss 实测：4 个 pod 的名字/重启数/age 全部不变。

⚠️ `prune: false` 期间旧 App 的误删护栏是关着的，窗口越短越好；
拆完立刻改回 `true`（第 5 步）。⚠️ 别顺手连 `selfHeal` 一起关，没必要。

### 3. 从旧树摘掉

```bash
# 编辑 cloud/oracle/manifests/kustomization.yaml，删掉该组的工作负载那几行
# ☠️ **保留 `<组>/namespace.yaml` 那一行**
just check          # kustomize build 仍要通过
just check-render   # 两个 App 都要渲染成功；oracle-k3s 的 objects 数应下降
git commit && git push
```

⏱ **交接不是一瞬间的**（2026-09-08 实测，从 push 到稳定约 1.5 分钟）：
旧 App 要先轮询到新 revision，两个 App 各自 sync 一轮，`tracking-id` 会**分批**翻转
（观察到 2/8 → 4/8 → 8/8）。中途两个 App 都短暂 `OutOfSync`，是预期。
判据是**全部**对象都翻完 + 两个 App 都回到 `Synced`：

```bash
for t in deploy/miniflux svc/miniflux ...; do
  kubectl --context oracle-k3s -n <ns> get $t \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
done | cut -d: -f1 | sort | uniq -c      # 期望全是新 App 名
```

**判据**：

```bash
kubectl --context oracle-k3s -n argocd get app oracle-k3s oracle-rss   # 两个都 Synced/Healthy
kubectl --context oracle-k3s get ns rss-system                          # ⚠️ ns 必须还在
kubectl --context oracle-k3s -n rss-system get pod                      # 无重启、无 Terminating
curl -sS -o /dev/null -w '%{http_code}\n' https://rss.meirong.dev       # 有对外路由的组才查
```

### 4. 恢复 `oracle-k3s` 的 prune

```bash
# 把 automated.prune 改回 true，push，确认生效
kubectl --context oracle-k3s -n argocd get app oracle-k3s \
  -o jsonpath='{.spec.syncPolicy.automated.prune}{"\n"}'    # 期望 true
```

⚠️ 连着拆多组时可以只开一次窗口（关一次、拆几组、再开回来），但**每组仍各自一个
commit**，这样任一组出问题可以单独 revert；窗口期内旧 App 的误删护栏是关着的。

### 5. 更新文档

- `cloud/oracle/manifests/README.md`（若还没有就照 `k8s/helm/manifests/README.md` 建一份所有权地图）
- [reference/argocd-app-patterns.md](../reference/argocd-app-patterns.md) 的 Application 清单
- `argocd/projects/oracle-k3s.yaml` 的 `sourceRepos` 不用改（同一个仓库）

## 回滚

任何一步出问题，回滚都不触碰 PVC：

| 卡在哪 | 回滚 |
|---|---|
| 第 1-2 步 | `git revert` 掉新 App 的 commit。旧树从未改动，对象仍由 `oracle-k3s` 管 |
| 第 3 步后发现问题 | `git revert` 那个 commit，把条目加回 `kustomization.yaml`。两个 App 回到共管状态，再决定往哪边收 |
| 对象被误 prune 了 | 不用回滚，让新 App 同步即可重建（内容一模一样）。⚠️ 若被删的是 **ns**，停下来照 [namespace-prune-cascade 复盘](../records/2026-08-03-namespace-prune-cascade.md) 从 restic 恢复 —— 但按本 runbook 的纪律 ns 不该被动到 |

## 做完之后

`oracle-k3s` App 只剩 `base/` 与 11 个 `namespace.yaml`，可以考虑改名成
`oracle-base`。⚠️ **改 Application 名 = ArgoCD 删旧建新**（tracking 变更），
对一个还管着全部 Namespace 的 App 来说风险远大于收益 —— 和 `monitoring-dashboards`
当年的判断同源，建议**不改名**，在注释里说明历史名即可。
