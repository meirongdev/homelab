# Namespace prune 级联删除 open-notebook 数据

> 日期: 2026-08-03
> 影响: `open-notebook` 全部数据被删（notebooks/sources/向量/对话状态），
>       `notebook.meirong.dev` 不可用约 50 分钟
> 结果: **数据已从 restic 完整恢复**，仅丢失最后一次夜备（2026-08-02 03:00 CST）之后的改动
> 触发: calibre 从 homelab 迁往 oracle-k3s 的退役步骤

## 一句话根因

`personal-services` 的 **Namespace 资源内嵌在 `calibre-web.yaml` 顶部**。
迁移收尾时 `git rm` 掉这个文件 → ArgoCD `prune: true` 删掉 Namespace →
**级联删除了同 namespace 下毫不相关的 open-notebook 的一切**，包括它的两个 PVC。

## 为什么护栏没拦住

calibre 的两个 PVC 都带 `argocd.argoproj.io/sync-options: Prune=false`。
**这条护栏对本次完全无效** —— 被 prune 的是 *Namespace*，PVC 是被 Kubernetes
的 namespace 级联删除机制清掉的，根本没走 ArgoCD 的 prune 路径。

> 教训：`Prune=false` 只保护「该对象自身被 ArgoCD prune」。它不保护
> 「承载它的 namespace 被删」。**namespace 才是真正的爆炸半径边界。**

## 时间线

| 时刻 | 事件 |
|---|---|
| T+0 | `git rm k8s/helm/manifests/personal-services/calibre-web.yaml`（含 Namespace 资源）并推送 |
| T+2min | ArgoCD prune Namespace → open-notebook / surrealdb / 两个 PVC / PV 全部消失 |
| T+3min | 发现：`kubectl get all,pvc -n personal-services` 返回空，namespace AGE 只有 19s（已被重建） |
| T+5min | 确认 restic 里有 `open-notebook.surql`（9.8MB，2026-08-02 03:00 CST 夜备） |
| T+20min | ArgoCD 陷入死锁：PostSync hook Job 先于其 ConfigMap 创建 → Job 失败 → 同步卡在 PostSync 阶段 |
| T+30min | 打破死锁（见下），手工 apply 清单，PVC/Deployment 重建 |
| T+38min | `restic restore` 取出 surql，POST 到 `/import` 导入新库 |
| T+45min | 数据校验通过：2 notebooks / 2 sources / **192 条 source_embedding** / 5 models / 12 transformations |
| T+50min | `notebook.meirong.dev` 恢复（还需触碰 HTTPRoute，见下） |
| T+75min | ArgoCD `personal-services` 回到 Synced/Healthy |

## 恢复过程中踩到的三个次生问题

### 1. ArgoCD PostSync hook 死锁

namespace 被删后重建，ArgoCD 的同步卡在
`waiting for completion of hook batch/Job/open-notebook-provisioner`，
而该 Job 的 pod 起不来：`configmap "open-notebook-provisioner-script" not found`。
普通资源始终没被应用 → ConfigMap 永远不存在 → hook 永远失败 → 死循环。

**打破方法**（按序）：

```bash
# a) hook Job 卡在 argocd 的 finalizer 上删不掉（终止 operation 后没人来摘）
kubectl patch job -n personal-services open-notebook-provisioner \
  --type merge -p '{"metadata":{"finalizers":null}}'

# b) 手工 apply 常规清单，让资源先存在
kubectl apply -f k8s/helm/manifests/personal-services/open-notebook.yaml

# c) operationState 是**持久化在 CR status 里的僵尸**，控制器重启也清不掉；
#    注意 Application CRD 没启用 status 子资源，不能加 --subresource=status
kubectl patch application personal-services -n argocd --type merge \
  -p '{"status":{"operationState":{"phase":"Failed","finishedAt":"<now>"}}}'

# d) 清掉后自动同步仍不动 —— auto-sync 对「同一 revision 上次失败」有退避。
#    必须手工写 spec.operation 触发一次
kubectl patch application personal-services -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"manual"},"sync":{"revision":"<sha>","prune":true,"syncStrategy":{"hook":{}}}}}'
```

### 2. SurrealDB `/import` 返回 415 但数据其实进去了

```
curl: (22) The requested URL returned error: 415
```
415 出在响应阶段的 content-type 协商，**导入本身成功**。
不要据此重试（会重复导入）—— 先查计数再决定：

```bash
curl -sS -u "root:$PW" -H "Surreal-NS: open_notebook" -H "Surreal-DB: open_notebook" \
  -H 'Accept: application/json' -X POST --data-binary 'SELECT count() FROM notebook GROUP ALL;' \
  http://open-notebook-surrealdb.personal-services.svc:8000/sql
```

⚠️ 另注意：`curl ... | head` 会用 `head` 的退出码掩盖 curl 的失败，
本次就是这样一度误判成功。校验要看数据，不要看 `if curl`。

### 3. Cilium 网关缓存陈旧 → HTTPRoute `BackendNotFound`

Service 明明存在（4 分钟前重建），HTTPRoute 却报
`ResolvedRefs=False / BackendNotFound: Service "open-notebook" not found`，
`notebook.meirong.dev` 返回 500。namespace 删除重建后网关控制器没有重新解析。

```bash
kubectl annotate httproute -n personal-services open-notebook reconcile-ts=$(date +%s) --overwrite
```
触碰一下即恢复 `ResolvedRefs=True`。

## 已做的修复

**全仓库扫描同类地雷**，把 Namespace 从共享清单里拆成专职文件（渲染出的资源集合
139 → 139，对集群零变化）：

| 原文件 | 拆出 |
|---|---|
| `k8s/helm/manifests/kube-bench/kube-bench.yaml` | `kube-bench/namespace.yaml` |
| `cloud/oracle/manifests/base/cloudflare-tunnel.yaml` | `base/namespace-cloudflare.yaml` |
| `cloud/oracle/manifests/base/external-dns.yaml` | `base/namespace-external-dns.yaml` |
| `cloud/oracle/manifests/zitadel/zitadel.yaml` | `zitadel/namespace.yaml` ← 最危险，那是全站 SSO |

每个新文件头部都带警告注释，防止有人再塞回去。

## 本可以更早发现的信号

迁移前我已经检查过「删 homelab calibre 清单会不会影响 open-notebook」，并且**确实
发现并修复了一处隐藏耦合**（`route-open-notebook.yaml` 依赖 `route-calibre-web.yaml`
里定义的 ReferenceGrant）。但那次检查只看了 *gateway* 目录的交叉引用，
**没有检查被删文件里是否含有 namespace 级资源**。

正确的检查应该是：**删任何清单文件前，先看它包含哪些 kind**——
凡是 Namespace / CRD / ClusterRole 这类「作用域大于文件本身」的资源，
删除影响都远超该文件所属的应用。

```bash
# 删文件前必做
grep "^kind:" <要删的文件>
```

## 备份表现（唯一让这次没变成灾难的东西）

`backup/overlays/homelab/backup-script.yaml` 的设计经受住了考验：

- **SurrealDB 走 HTTP `/export` 逻辑导出**而非拷 rocksdb 文件 —— 拷文件在活进程下必然不一致，
  逻辑导出让这次恢复变成一条 curl
- 9.8MB 的 `open-notebook.surql` 里含 notebooks/sources/**192 条向量**/模型凭据/transformations
- 向量是最贵的部分（重新嵌入要 Mac OMLX 在线跑很久），全部完好

**刻意未备份、因而真丢的**：`/app/data` 里的播客音频与 UI 直传原件
（书库里有的书不受影响）。这是备份脚本注释里早就写明的取舍，符合预期。

## 相关

- [calibre 迁移方案](../plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md)
- [备份与恢复 runbook](../runbooks/backup-recovery.md)（本次用的 SurrealDB 恢复命令就在里面）
- [Open Notebook 架构事实](../reference/open-notebook.md)
