# oracle otel-collector 改配置静默不生效：ConfigMap 变了，DaemonSet 不滚动

> 日期: 2026-08-02（同一症状 2026-07-30 OpenCost、KRR 上线时各出现一次，当时靠手动重启绕过）
> 影响: Loki/Tempo 迁到 oracle 当天，oracle collector 的 exporter 改成集群内直达后实际未生效：
>       日志仍发往 homelab 的旧 NodePort，oracle 侧 Loki 里只有 `cluster=homelab` 一个标签值。
>       在此之前，任何对 oracle collector 配置的修改都同样静默不生效，ArgoCD 全程 Synced/Healthy
> 根因: oracle collector 是手写清单，DaemonSet 的 pod template 没有 config checksum 注解。
>       ConfigMap 内容变了而 DaemonSet spec 不变，pod 不重启（实测 age 2d5h / 0 restart），
>       collector 又只在启动时读一次配置。ArgoCD 只比对对象本身，看不出这一层。
>       homelab 侧没有这个问题：Helm chart 会在 pod template 上打 checksum 注解
> 处置: 配置抽成 `cloud/oracle/manifests/monitoring/otel-collector-config.yaml`，改由 kustomize
>       `configMapGenerator` 生成带内容哈希后缀的 ConfigMap，并自动重写 DaemonSet 的 volume
>       引用：内容一变名字就变，DaemonSet 随之滚动（提交 `9e63269`）

## 经过

| 日期 | 事件 |
|------|------|
| 2026-07-30 | OpenCost 上线：给 oracle collector 加 receiver 后无数据，`kubectl rollout restart daemonset/otel-collector -n monitoring` 后恢复。方案里留了「后续给 DaemonSet 加 checksum 注解」的建议（[plan](../plans/2026-07-30-opencost-multicluster.md)） |
| 2026-07-30 | KRR 给 oracle 加 `prometheus/cadvisor`：同一问题，方案把手动重启写成不可省的部署步骤（[plan](../plans/2026-07-30-krr-rightsizing.md)） |
| 2026-08-02 | Loki/Tempo 迁 oracle。提交里把 collector 的 logs/traces exporter 改成集群内直达，实测无效：pod 仍挂着旧配置，日志继续发往 homelab 旧 NodePort。定位为通用的潜伏缺陷而不是这次的个例，当天改成 `configMapGenerator`。渲染实测生成名 `otel-collector-config-8645t6kbfb`，DaemonSet 引用同步改写 |
| 2026-08-06 | 复核：新增 `prometheus/readlist` receiver 后 ConfigMap 名变成 `otel-collector-config-2g4gm5979k`，DaemonSet 自动滚动、Pod age 归零、新指标立即到货 |
| 2026-09-08 | generator 随 monitoring 组从根 `cloud/oracle/manifests/kustomization.yaml` 搬到 `cloud/oracle/manifests/monitoring/kustomization.yaml`（ROADMAP 开放项 #13）。搬家前后生成名一致，DaemonSet 未滚动 |

## 为什么一直没被发现

失败的外观和「没有新数据可采」完全一样：ArgoCD 显示 Synced/Healthy，ConfigMap 内容也确实是新的，
collector 没有报错（它根本没读到新配置）。只有去看 pod age，或者核对新 receiver 的指标是否到货，
才看得出来。两次手动重启都只修了当次，没有人把它当成通用缺陷处理，直到迁移时整条日志链路
没切过去才被逼出来。

## 要守住的不变量

配置必须留在 `configMapGenerator` 里。改回普通 ConfigMap 资源，或把 monitoring 组改成 ArgoCD
目录源，这个静默失败立刻回来，而且照样是 Synced/Healthy。理由写在
`cloud/oracle/manifests/monitoring/kustomization.yaml` 文件头。

现状与核对命令见 [reference/observability-multicluster.md](../reference/observability-multicluster.md#otel-collector-配置改了不生效)。
