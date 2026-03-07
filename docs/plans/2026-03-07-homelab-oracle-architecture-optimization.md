# Homelab + Oracle K3s 最优架构优化方案（Cilium Mesh + Tailscale）

> 日期: 2026-03-07
> 状态: Proposed
> 目标: 给出不为现状妥协的目标架构、替换路径和执行计划。

## 1. 执行摘要

当前状态是“混合网络面”:

1. homelab: Cilium
2. oracle-k3s: Flannel
3. 跨集群: Tailscale 子网路由（Pod CIDR only）
4. Gateway API 控制器: Traefik

这套架构可用，但不是最优。

最优目标态（建议）:

1. 双集群统一 Cilium
2. 启用 Cilium ClusterMesh（跨集群服务发现与策略）
3. Tailscale 从“业务数据通道”降级为“管理与应急通道”
4. Gateway API 控制器收敛为单实现（优先 Cilium Gateway）

## 2. 现状评估结论

### 2.1 可简化点

1. **双 CNI 异构**（Cilium + Flannel）增加排障复杂度
2. **跨集群业务流量依赖 Tailscale 子网路由**，策略可观测与策略一致性不足
3. **Gateway API 绑定 Traefik ExtensionRef**（`traefik.io/Middleware`）形成控制器锁定
4. **Uptime Kuma 对 SSO 服务直接跟随重定向**，导致 400 误报

### 2.2 运行态证据（2026-03-07）

- homelab 与 oracle-k3s 节点均 Ready
- Uptime Kuma 失败项集中在受 SSO 保护的 homelab 域名:
  - `book.meirong.dev`
  - `grafana.meirong.dev`
  - `vault.meirong.dev`
  - `notify.meirong.dev`
  - `backup.meirong.dev`
- 最新失败信息均为 `Request failed with status code 400`

## 3. 最优目标架构（Target State）

## 3.1 网络与服务通信

1. 双集群 Cilium（统一 dataplane）
2. Cilium ClusterMesh 建立跨集群服务发现与身份
3. 服务间互访优先使用 ClusterMesh 能力，不再依赖 Tailscale 子网路由
4. Tailscale 保留给:
   - 运维入口（SSH / debug）
   - 控制面应急旁路

## 3.2 Gateway 与入口

1. 短期维持 Traefik（保障稳定）
2. 中期将 HTTPRoute 从 `ExtensionRef: traefik.io/Middleware` 迁移到网关无关策略
3. 长期切换到 Cilium Gateway（Envoy）并移除 Traefik 控制面

## 3.3 可观测与健康检查

1. 外部可达性监控与后端可用性监控分离
2. SSO 保护域名以 3xx 作为“入口健康”
3. 后端真实可用性由集群内探测/Prometheus 指标承担

## 4. Uptime Kuma 修复计划（针对当前 Fail）

## 4.1 根因

当前受保护域名监控会跟随重定向进入 oauth2 流程，最终落在 400，导致误判 fail。

## 4.2 修复策略

1. 对 SSO 受保护监控项设置:
   - `maxredirects: 0`
   - `accepted_statuscodes: ["300-399"]`
2. 对公开域名保持 `200-299`（或按业务需要含 3xx）
3. 保留 `argocd.meirong.dev` 为 200/3xx（不走 SSO）

## 4.3 执行步骤

1. 修改 `cloud/oracle/manifests/uptime-kuma/provisioner.yaml`
2. 重新执行 provisioner Job（更新现有 monitor 配置）
3. 验证 5 分钟窗口内失败项清零
4. 若仍有失败，按域名抓包与链路回放（Cloudflare -> Tunnel -> Gateway）

## 4.4 验证命令

```bash
# 查看失败项
kubectl --context oracle-k3s -n personal-services exec deploy/uptime-kuma -- \
  sh -lc "sqlite3 -csv /app/data/kuma.db \"SELECT m.name,m.url,h.status,h.msg,h.time FROM monitor m LEFT JOIN heartbeat h ON h.id=(SELECT id FROM heartbeat WHERE monitor_id=m.id ORDER BY time DESC LIMIT 1) WHERE h.status != 1 ORDER BY m.name;\""
```

## 5. Cilium Gateway API 替换 Traefik 可行性分析

## 5.1 结论

可以替换，但必须分阶段。

阻塞点不在 HTTPRoute 本身，而在 `traefik.io/Middleware`（ForwardAuth）依赖。

## 5.2 主要差异

1. Traefik 当前通过 `ExtensionRef` 直接引用 Middleware
2. Cilium Gateway 基于 Envoy，需用 Envoy 外部鉴权（ext_authz）实现同等 ForwardAuth
3. 迁移期间若直接切换控制器，SSO 链路风险高

## 5.3 替换计划

### Phase A: 去 Traefik 依赖（先解耦）

1. 盘点所有 `ExtensionRef: traefik.io/Middleware`
2. 设计统一鉴权模型:
   - 方案 1: Cilium Envoy ext_authz 对接 oauth2-proxy
   - 方案 2: 将认证前置到 Cloudflare Access（减少集群内 auth 复杂度）
3. 在非关键域名做 canary

### Phase B: 双网关并行

1. 同时部署 Cilium GatewayClass 与 Traefik GatewayClass
2. 逐域名灰度迁移（从公开服务开始）
3. 监控指标对比:
   - 5xx rate
   - p95 latency
   - auth redirect success ratio

### Phase C: 切换与收敛

1. 全量切换到 Cilium Gateway
2. 删除 Traefik Middleware CRD 与 Traefik GatewayClass
3. 回写文档与 runbook

## 5.4 回滚策略

1. DNS/路由级回滚：切回 Traefik Gateway
2. 保留 Traefik manifests 直至观察窗口结束
3. 所有切换按服务分批，不做一次性大切

## 6. Cilium Mesh + Tailscale 优化路线图

## Milestone 1（1-2 周）

1. 修复 Uptime Kuma 误报（已进入实施）
2. 完成 Gateway 解耦设计（去 Traefik ExtensionRef）
3. 输出 ext_authz PoC

## Milestone 2（2-4 周）

1. oracle-k3s 迁移到 Cilium
2. 验证双集群 Cilium 网络一致性
3. 建立统一 CiliumNetworkPolicy 基线

## Milestone 3（4-6 周）

1. ClusterMesh 控制面联通
2. 逐步迁移跨集群业务通信到 ClusterMesh
3. Tailscale 下沉为管理平面

## Milestone 4（6-8 周）

1. Cilium Gateway 接管生产流量
2. Traefik 退出主路径
3. 收敛文档并冻结 target architecture

## 7. 风险与前置条件

1. `oauth2-proxy` 与 Envoy ext_authz 语义一致性是最大风险
2. ClusterMesh 引入前需统一 Cilium 版本与证书管理
3. 需要保留至少一个可一键回滚的网关路径

## 8. 交付物

1. 本文档: 最优架构改进计划
2. `docs/architecture/*`: 持续更新目标架构事实
3. `docs/runbooks/*`: 增补网关迁移与回滚 SOP
