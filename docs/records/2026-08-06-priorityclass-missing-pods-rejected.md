# homelab 缺 `meirong-bulk` 定义：opencost 与 trivy 的新 pod 被拒，静默下线约 25 分钟

> 日期: 2026-08-06（21:57 起约 25 分钟，+08）
> 影响: homelab 的 opencost 与 trivy-operator / trivy-server 下线约 25 分钟，成本采样与镜像扫描中断，
>       用户可见服务不受影响。ArgoCD 全程显示 Synced，只有 health 是 Degraded
> 根因: 两集群的 values 同批给这两个组件标了 `priorityClassName: meirong-bulk`，但该 class 只在
>       oracle 的 `priorityclasses.yaml` 里定义过（08-05 随缩容加），homelab 那份没有。滚动更新删掉
>       旧 pod 后，API server 拒绝建新 pod（`no PriorityClass with name meirong-bulk was found`）
> 处置: homelab 补定义，与 oracle 逐字段对齐（`b2edc82`）；当晚把 `meirong-*` 改名为无前缀的
>       `critical`/`high`/`bulk`，按「加新 → 改引用 → 删旧」三步走

## 经过

| 时刻（+08，提交时间） | 事件 |
|------|------|
| 21:50 | `1e7c241`：opencost、trivy-operator 补 `priorityClassName: meirong-bulk`（两集群）。理由是它们落在默认档 0，比 `bulk` 的个人应用还高 |
| 21:57 | `4e3bd34`：补 trivy-server 的第三个键。homelab 侧滚动更新，旧 pod 已删、新 pod 建不出来 |
| 22:20 | `b2edc82`：homelab 补 `meirong-bulk`。恢复后 ReplicaSet 的失败退避又拖了几分钟，删掉卡住的 RS 可立即重置 |
| 22:29 | `061d173` 改名第①步：两集群加 `critical`/`high`/`bulk`，不动引用 |
| 22:33 | `8f64780` 第②步：33 处引用切到新名，约 30 个 pod 滚动重建 |
| 23:43 | `2e90f55` 第③步：删 `meirong-*`（前置条件见下） |

## 根因

PriorityClass 与引用它的工作负载分属不同的 ArgoCD App，两份 PriorityClass 清单也由不同 App 下发
（`k8s/helm/manifests/namespace-guardrails/` 与 `cloud/oracle/manifests/base/`），同步之间没有先后保证。
引用先于 class 生效时，API server 直接拒绝建 pod，而 Deployment 的旧 pod 已被滚动删除。

外观上什么都没坏：清单确实下发成功，所以 ArgoCD 是 Synced，只有 health 变 Degraded。
又一例「Synced ≠ 在跑」。

## 改名为什么要三步

同一机制决定了改名不能一步做完：先加新 class，再改引用，最后删旧 class。第③步之前逐项核过
两集群没有运行中的 pod 引用旧名。有三处不跟着 GitOps 滚，各自单独处理：

| 对象 | 为什么不滚 | 怎么切的 |
|---|---|---|
| `vault-0` + `vault-agent-injector` | Vault 是 manual-helm，且 STS 是 `OnDelete`：`helm upgrade` 只改 spec | `just deploy-vault` 后手动删 pod；lifecycle hook 从 `vault-auto-unseal` 自动解封（实测 Sealed=false） |
| ArgoCD 全家 | 刻意不自管 | `just deploy-argocd`（RollingUpdate，自动滚完） |
| `zitadel-pg-1` | CNPG 不把 `priorityClassName` 变更当作滚动理由 | 删 pod，operator 按当前 spec 重建 |

ArgoCD 那一行是第③步的硬前置：它是 GitOps 控制面，仍跑旧 class 时删掉旧 class，
pod 一旦被重新调度就建不出来。

## 留下的

- 改名前创建的 ReplicaSet 修订仍写着 `meirong-*`（删除时 homelab 5 个 / oracle 25 个，desired 均为 0）。
  对这些 Deployment 执行 `kubectl rollout undo` 回到那些修订会建不出 pod。往前修，别回滚；
  它们会随后续发布淘汰出 `revisionHistoryLimit` 窗口。
- 两份 `priorityclasses.yaml` 的文件头都写了「必须逐字段同步」。分档原则见
  [reference/k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md)。
