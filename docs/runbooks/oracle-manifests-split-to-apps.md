# 把 oracle 的单体 kustomize 树拆成一目录一个 ArgoCD App

> Last updated: 2026-09-03
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
| `oracle-rss` | `rss-system/` | `rss-system` | 11 | 纯无状态，库在 `apps-pg` |
| `oracle-uptime-kuma` | `uptime-kuma/` | `personal-services` | 7 | ⚠️ 它的 `namespace.yaml` 声明的是 **personal-services**，不是同名 ns |
| `oracle-zitadel` | `zitadel/` | `zitadel` | 7 | 身份面，单独放到最后做 |

☠️ **`monitoring/` 那组不能改成目录源**：otel-collector 的配置走 `configMapGenerator`
（名字带内容哈希 → 配置一变 DaemonSet 自动滚动）。改成目录源就退回「ConfigMap 变了
pod 根本不重启」，那正是 2026-08-02 踩过的坑。它的新 App 要指向一个**新建的
`monitoring/kustomization.yaml`**，把 generator 一起搬过去。

## 执行

每组**独立走一遍**下面四步，一次只做一组，做完观察 10 分钟再做下一组。
先拿 `oracle-rss`（最小、纯无状态、有 Deployment 但无 PVC 无路由）练手。

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

### 2. 让新 App 抢到 tracking

新 App 同步一次就会把 `tracking-id` 改写成自己的。**这一步是第 3 步安全的前提** ——
旧 App 之后看到的就是「不是我的对象」，不会 prune。

```bash
kubectl --context oracle-k3s -n argocd annotate app oracle-rss \
  argocd.argoproj.io/refresh=hard --overwrite
# 等同步完成后核对归属（应打印 oracle-rss:...，不再是 oracle-k3s:...）
kubectl --context oracle-k3s -n rss-system get deploy miniflux \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
```

☠️ **归属没翻过来就不要做第 3 步**。翻不过来通常是新 App 还没真正同步过
（Synced 也可能是「没有差异所以什么都没做」），先手动 Sync 一次。

### 3. 从旧树摘掉

```bash
# 编辑 cloud/oracle/manifests/kustomization.yaml，删掉 rss-system/ 那几行
just check          # kustomize build 仍要通过
just check-render   # 两个 App 都要渲染成功；oracle-k3s 的 objects 数应下降
git commit && git push
```

**判据**：

```bash
kubectl --context oracle-k3s -n argocd get app oracle-k3s oracle-rss   # 两个都 Synced/Healthy
kubectl --context oracle-k3s get ns rss-system                          # ⚠️ ns 必须还在
kubectl --context oracle-k3s -n rss-system get pod                      # 无重启、无 Terminating
curl -sS -o /dev/null -w '%{http_code}\n' https://rss.meirong.dev       # 有对外路由的组才查
```

### 4. 更新文档

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
