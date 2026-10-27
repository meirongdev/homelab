# ClusterMesh 双向断开零告警：clustermesh-apiserver 卡死不自愈，根因先后判错三次

> 日期: 2026-08-05（升 OS、缩容、重启后逐项验收时发现，与这些变更无关）
> 影响: 两集群 Cilium 都报 `0/1 remote clusters ready` + `0 reconnections (last: never)`，
>       ClusterMesh 双向断开且**没有任何告警**。可证的断开窗口约 2 天（cilium-agent 容器
>       启动于 homelab 08-03 / oracle 08-05），更早无从查起：`cilium_kvstoremesh_*` 一条都没被抓。
>       实际业务影响为零：两集群 global Service 都是 0，遥测与 ArgoCD 走 Tailscale + NodePort 直连。
> 根因: clustermesh-apiserver 活着但卡住（up-but-stuck），Cilium 不会自己恢复。配置从未丢过：
>       helm release 历史显示 peer 条目自 oracle `cilium.v11`（2026-03-15）/ homelab `cilium.v10`
>       （2026-04-27）起直到断开时都正确。
> 处置: `just connect-clustermesh` 顺带触发的 helm upgrade 重建了 homelab 的 clustermesh-apiserver
>       pod（新 pod `restarts=0`，配置一字未改），双向恢复；当晚补 kvstoremesh 指标抓取 + 5 条告警、
>       在 oracle values 里固化 peer 条目、新增 `just oracle verify-node`。

## 经过

1. 验收时发现两集群 ClusterMesh 都是 `0/1 remote clusters ready`。
2. 跑 `cd k8s/helm && just connect-clustermesh 100.94.186.7:32379 100.107.166.37:32379`，双向恢复：
   `retrieved=true`，nodes/endpoints/identities/services 同步全 `true`；oracle 见 homelab
   33 endpoints / 33 identities，homelab 见 oracle 48 / 86。
3. 根因结论改了三次（下节），最后以 helm release 历史为准。
4. 补监测与配置固化（见「留下的东西」）。

## 三次判错

每一次都先写进了文档，后来更正：

| 当时的判断 | 为什么错 | 该看什么 |
|---|---|---|
| `cilium-clustermesh` secret 的 endpoint 写成了集群内 DNS 名 `clustermesh-apiserver.kube-system.svc:2379`，两边在连自己 | KVStoreMesh 下这是正常形态：agent 只读本地缓存，对端 endpoint 在 `cilium-kvstoremesh` secret，靠 clustermesh-apiserver Deployment 的 `hostAliases` 解析。connect 前后 `cilium-clustermesh` 字节级相同，变的只有 hostAliases 与该 Deployment 重建 | `cilium-kvstoremesh` + apiserver 的 `hostAliases` |
| 断了一个月：homelab cilium pod 的 `startTime` 是 2026-07-07（underlay 改造那天） | 节点重启后 DaemonSet pod 对象不变、只有容器重启，`(last: never)` 只覆盖当前容器进程 | `state.running.startedAt` |
| oracle 的 peer 配置没固化，升级（`--reset-values`）把它抹了 | helm release 历史里 peer 条目一直在。oracle 的 values 文件当时也存在，只是缺对端条目 | helm release 历史 |

## 为什么零告警

`cilium_kvstoremesh_*` 没被抓。补的是 clustermesh-apiserver 的 kvstoremesh 容器 `:9964`，
不是 cilium-agent：agent 只连本集群缓存，真正跨 Tailscale、也真正断掉的那一跳是 kvstoremesh；
agent 的同类指标还要对 Cilium 做 helm upgrade 才能打开。

## 留下的东西

- 指标：homelab `k8s/helm/manifests/monitoring/clustermesh-servicemonitor.yaml`，oracle 走
  otel-collector 的 `prometheus/clustermesh` receiver。
- 告警：`k8s/helm/manifests/monitoring/alerts/clustermesh-alerts.yaml`，按互不蕴含的故障分开写
  （连不上 / peer 配置整个消失 / 分集群看不见 ×2 / 抖动）。
- `cloud/oracle/values/cilium.yaml` 补 `clustermesh.config.clusters` 对端条目（此前只存在于
  live helm release 的 stored values 里，而 oracle 的 `deploy-cilium` 带 `--reset-values`）。
- `just oracle verify-node` 断言 ClusterMesh 双向 `retrieved=true`。
- 没做自愈：两集群 global Service 都是 0，ClusterMesh 是纯待命能力，不值得加探针。

## 教训

- 先查 helm release 历史确认配置有没有变过，再下根因结论；别从当前状态倒推。
- 判据是 `cilium-dbg status --all-clusters` 的 `retrieved=`，摘要行的 `N/1 ready` 不够。

## 后续

2026-08-10 ClusterMesh 又断过一次，成因不同：例行 `deploy-cilium` 的 `--reset-values` 冲掉了
`connect` 交换来的跨集群 CA 信任。经过写在 `cloud/oracle/values/cilium.yaml` 的 `clustermesh` 注释里。
