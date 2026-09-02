# 舰队级共享版本 —— 被 k8s/helm/justfile 与 cloud/oracle/justfile 用 `import` 引入。
#
# 为什么在这里而不是各写一份：这两个值是**同一个事实**（不是"名字碰巧一样"），
# 写两份就会漂，而漂移是静默的：
#   · 2026-08-10 oracle 的 deploy-cilium 缺 --version，一次例行部署把它从 1.19.1 静默升到
#     1.20.0，两集群劈叉直接断 ClusterMesh（`retrieved=false`，单向断所以更难发现）。
#   · 2026-08-13 复查又发现 oracle 的 ansible 剧本仍钉着旧 gateway_api_version，
#     注释却写着"与 homelab 一致" —— 注释拦不住漂移。
# 2026-09-02 起改为单一真相源；CI 的 V2 仍然管着 justfile 之外的副本（ansible 剧本里
# 那份 YAML 变量没法 import，只能靠断言）。
#
# ⚠️ 不放这里的：`eso_version`（两集群各自独立装 ESO，版本无耦合，同步反而是假约束）、
# `vault_version` / `argocd_chart_version`（只有 homelab 一处）、各 chart 的 targetRevision
# （唯一真相源是 argocd/applications/<app>.yaml，别在 justfile 里重复维护）。

# ☠️ cilium_version 与 gateway_api_version 是**一对**，升 Cilium 必须同步核对后者，
# 判据见 CI 的 V3（scripts/check-version-pairs.py 的 CILIUM_GATEWAY_API 兼容表）。
#
# 2026-08-10 1.19.1 → 1.20.0：1.20 的四条 breaking change 中三条本仓库不命中
# （CiliumNodeConfig v2alpha1 0 个、带 kafka/l7/l7proto 的 CNP/CCNP 0 条、未用自定义 CNI chaining）。
# ☠️ 但「Gateway API 需 ≥v1.6.1」那条当时判错了，代价是两集群入口静默半瘫 30 小时
# （2026-08-11 查明）。错在两处：
#   1. 它不只关乎 TLSRoute。Cilium 1.20 的 operator 在启动时**硬性检查**
#      TLSRoute / BackendTLSPolicy / ReferenceGrant(**必须提供 v1**) 三个 CRD 是否齐备，
#      少任何一个就**整个 Gateway API 控制器不初始化**——哪怕你一条 TLSRoute 都没有。
#   2. 「入口全部 200」这个验证方法**恰恰看不见这种故障**：已建路由的 datapath 早就编程好了、
#      会一直生效，所以旧域名照常 200；死掉的只是**调和新路由的能力**。
#      故障因此完全静默，直到 2026-08-11 加 bentopdf 时第一条新 HTTPRoute 拿不到 status、
#      pdf.meirong.dev 503 才暴露。homelab 08-10 07:08Z 挂、oracle 08-10 19:07Z 挂。
#   教训：验证 Gateway API 是否健康，**不能只 curl 旧域名**，要看新建路由能否拿到 `.status`；
#   operator 日志里那句 "Required GatewayAPI resources are not found" 是**故障信号**
#   （有输出=坏了），健康集群什么都不打，所以 grep 不到不等于健康。
#   完整复盘 docs/records/2026-08-11-gateway-api-crd-stall.md
# renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
cilium_version := "1.20.0"

# Cilium 1.20 要求的 Gateway API CRD 版本（装它的配方是 `just deploy-gateway-api-crds`，
# 两个 justfile 各有一份，因为要打的是各自的集群）。
# 升级前先读 Cilium 对应版本文档的 Gateway API 前置条件，别假设旧 CRD 还能用。
# ⚠️ 还有第三份副本在 cloud/oracle/ansible/playbooks/setup-k3s.yaml（YAML 变量，import 不进来），
#    由 CI 的 V2 断言与本文件一致。
# renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
gateway_api_version := "1.6.1"
