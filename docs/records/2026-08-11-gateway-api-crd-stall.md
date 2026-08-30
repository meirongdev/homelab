# Cilium 1.20 升级漏配 Gateway API CRD → 两集群「加不了新路由」静默瘫痪 30 小时

> 日期: 2026-08-11（故障始于 2026-08-10）
> 影响: 两集群的 Gateway API 控制器**完全未初始化**。**已有域名全部正常**，
>       但期间任何新增/修改的 HTTPRoute 都不会被调和 → 新服务上线即 503
> 结果: 升级 Gateway API CRD v1.2.1 → **v1.6.1** + 重启 cilium-operator，两集群恢复；
>       CRD 版本已收进 `just deploy-gateway-api-crds`（此前是带外手工装的，不在任何配方里）
> 触发: 部署 BentoPDF（本仓库自 08-10 以来的**第一条新 HTTPRoute**）时 `pdf.meirong.dev` 503

## 一句话根因

**Cilium 1.20 的 operator 在启动时硬性检查 `TLSRoute` / `BackendTLSPolicy` /
`ReferenceGrant(必须提供 v1)` 三个 CRD 是否齐备，缺任何一个就整个 Gateway API 控制器
不初始化。** 集群装的 Gateway API 还是 **v1.2.1**，三项全缺。

```
level=error msg="Required GatewayAPI resources are not found"
  customresourcedefinitions "tlsroutes.gateway.networking.k8s.io" not found
  CRD "referencegrants.gateway.networking.k8s.io" does not have version "v1"
  customresourcedefinitions "backendtlspolicies.gateway.networking.k8s.io" not found
```

| 集群 | Cilium | GW API bundle | 控制器挂掉时刻 |
|---|---|---|---|
| homelab | v1.20.0 | v1.2.1 | 2026-08-10 07:08:37Z |
| oracle-k3s | v1.20.0 | v1.2.1 | 2026-08-10 19:07:08Z |

## 为什么 30 小时没人发现

**已建路由的 datapath 早就编程好了，会一直生效。** 死掉的只是「**调和新路由**」的能力。
所以：

- 所有旧域名照常 200 —— 从外部完全看不出异常
- 没有任何告警会响：Pod 健康、Deployment 可用、ArgoCD `Synced + Healthy`
- 只有**新建一条 HTTPRoute** 才会撞上：它拿不到 `.status`（连
  `ResolvedRefs=False` 都没有，是**整个 status 字段不存在**），域名 503

## 最该记住的一条：升级评审时判错了，而"验证"恰好看不见它

`k8s/helm/justfile` 里 1.19.1 → 1.20.0 的升级注释**明确考虑过**这条 breaking change，
结论是不命中：

> TLSRoute 0 个（那条「Gateway API 需 ≥v1.6.1」的实质就是 TLSRoute v1alpha2→v1，
> 本仓库只用 HTTPRoute，**实测 1.20 + Gateway API v1.2.1 入口全部 200**）

两处都错：

1. **它不只关乎 TLSRoute。** 那是一项**启动期前置检查**，缺 CRD 就整个控制器不启动 ——
   哪怕你一条 TLSRoute 都没有、永远不打算用。把「我不用这个资源」等同于
   「这个 CRD 可以不装」，是本次的核心误判。
2. **「入口全部 200」这个验证方法恰恰对该故障免疫。** 它测的是既有 datapath，
   而坏掉的是控制面的调和能力。**用一个必然通过的测试去验证一个它测不到的假设**，
   比不验证更危险 —— 它把「没验证」写成了「已实测」。

## 正确的验收方式

不要只 curl 旧域名。至少查这两项：

```bash
# 1. 控制器是否初始化（有输出 = 坏了）
kubectl -n kube-system logs deploy/cilium-operator --tail=300 \
  | grep "Required GatewayAPI resources are not found"

# 2. 新建路由能否拿到 status（比 curl 旧域名强得多）
kubectl -n <ns> get httproute <name> \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
```

## 修复步骤（已收进配方）

```bash
cd k8s/helm     && just deploy-gateway-api-crds   # homelab
cd cloud/oracle && just deploy-gateway-api-crds   # oracle-k3s
```

配方做三件事：apply 7 个 v1.6.1 CRD → 重启 cilium-operator（**该检查只在启动时做**）
→ 自动验收（发现 "Required GatewayAPI resources" 就退出非零）。

两个必须知道的细节：

- **必须 `--server-side --force-conflicts`**：`httproutes` 的 CRD 有 **429KB**，
  客户端 apply 会撑爆 `last-applied-configuration` 注解的大小上限。
  首次从客户端 apply 迁移时会打印一条 `failed to migrate ... last-applied-configuration`
  警告，**非致命**，下次 apply 自愈。
- **TLSRoute 只在 `experimental` 频道发布**，standard 频道没有；Cilium 仍要求它存在。

## 升级安全性（升级前逐个核对过，无破坏）

| CRD | v1.6.1 served 版本 | 现用版本是否保留 |
|---|---|---|
| gatewayclasses / gateways / httproutes | `v1` + `v1beta1` | ✅ |
| grpcroutes | `v1` | ✅ |
| **referencegrants** | **`v1` + `v1beta1`（v1beta1 仍是 storage）** | ✅ |
| backendtlspolicies / tlsroutes | 新增 | —— |

升级后对象计数不变：oracle 1 gateway / 14 httproute / 4 referencegrant，
homelab 1 / 4 / 3。恢复后两集群全部路由 `Accepted=True, ResolvedRefs=True`。

⚠️ **顺带纠正一处仓库共识**：`docs/reference/manifest-safety-checks.md` 的 H3 原写
「ReferenceGrant 至今未晋升到 v1」—— 不成立，它早已有 `v1`，且 Cilium 1.20 *要求*
CRD 提供 v1。**H3 规则本身不变**（继续写 `v1beta1`，因为它仍 served 且是 storage），
但理由要改成「以集群实际提供的版本为准」。

## 遗留 / 后续

- `oracle-gateway` 的 `Programmed=False (AddressNotAssigned)` 是**既有且无害**的：
  OCI 没有 LB provisioner，流量经 Cloudflare 隧道进来，路由实测正常。homelab 侧为 `True`。
- ~~目前**没有任何告警**覆盖「Gateway API 控制器未初始化」~~ —— **本条建议后来已实施**：
  `cloud/oracle/manifests/monitoring/loki-rules.yaml` 的 `cilium-gateway-api` 组对
  `cilium-operator` 日志里那句 `Required GatewayAPI resources are not found` 做了日志告警。
  ⚠️ 它是**负向探测**（出现该串才报警）；健康时 operator 什么都不打，
  所以「grep 不到」不能反过来当健康证据 —— 正向判据仍是新建路由能否拿到 `.status`。
