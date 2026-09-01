# 按域名的公网访问统计：自写 exporter，而不是用现成的 Cloudflare exporter

> 日期: 2026-08-15
> 状态: ✅ 已完成

## 上下文

想要的东西很具体：**每个域名（`*.meirong.dev`）每天被多少个不同的公网 IP 访问过，以及多少请求**。

现有两条采集路径都答不了：

- `cloudflared` 的官方指标**不带 hostname 标签**（这一点 2026-08-13 已逐条对着 `/metrics`
  核过，见 [cloudflare-tunnel-observability.md](../reference/cloudflare-tunnel-observability.md)）。
- `cilium-envoy` 的 L7 指标粒度是**服务**（`ns_svc`）不是域名，而且它在 Cloudflare **之后**，
  看不到边缘缓存命中与 WAF 拦截。

「谁来过」这件事只有 Cloudflare 边缘知道，所以数据源必然是 Cloudflare Analytics API。
问题只剩：**用现成的 exporter，还是自己写。**

☠️ **前提，也是本决策的全部关键：`meirong.dev` 是 Free 套餐**
（`plan id = 0feeeeeeeeeeeeeeeeeeeeeeeeeeeeee`）。下面所有结论只在免费版成立；
哪天升到 Pro，这份记录要重新评估。

## 评估过的选项

### 选项 A：`cloudflare/cloudflare-prometheus-exporter`（官方，90+ 指标）

❌ **否决,两个独立原因**：

1. **它没有要的那个指标**。hostname 系列只有 `cloudflare_zone_hostname_requests` /
   `_by_status` / `_cache_status` / `_edge_ttfb_seconds` / `_origin_response_duration_seconds`；
   独立访客只有 **zone 级**的 `cloudflare_zone_uniques_total`。**没有按域名的独立访客/IP 数。**
2. README 明写「Free plan 的 zone 没有 GraphQL Analytics 权限，exporter 自动跳过」，
   并用 `cloudflare_zones_skipped_free_tier` 报告被跳过的 zone。

另外形态也不合：它是 **Cloudflare Worker + Durable Objects**，不是集群内组件
（虽然提供了 docker-compose 备选）。

### 选项 B：`lablabs/cloudflare-exporter`（426★，社区最流行；及其一众 fork）

❌ **否决**。它比官方的更接近：有 `cloudflare_zone_requests_status_country_host`，
**按域名的请求数是有的**。但

1. 独立访客同样**只到 zone 级**（`cloudflare_zone_uniques_total`）。
2. 它的 zone analytics **全部建在 `httpRequests1mGroups` 上**，而这个数据集对本 zone
   直接 403（见下表）。

**实测**（`ghcr.io/lablabs/cloudflare_exporter:latest`，`FREE_TIER=true`，等满两个采集周期）：

```
level=info msg="Filtering zone: <zone> meirong.dev"
→ 之后只发 r2StorageAdaptiveGroups 查询
→ 输出的指标族只有 cloudflare_r2_storage_bytes / _total_bytes
→ 零个 cloudflare_zone_*
```

`gathertown` / `transferwise` / `robbiet480` / `gitlab-org` 的实现同源，同样依赖 1m/1h 数据集。

⚠️ **顺带发现的一个真实缺陷**：lablabs 的 exporter 在 `LOG_LEVEL=debug` 下会把
`Authorization: Bearer <token>` **完整打进日志**。在本仓库的集群里跑它 = token 进 Loki。
（这条是评估当天踩出来的，代价是那把 token 当场作废重滚。）

### 选项 C：Grafana Infinity datasource 直接查 GraphQL，完全不写代码

未采纳，也**未验证**。代价明确：没有 Prometheus 历史留存（每次开面板重新查）、
token 落进 Grafana datasource、且无法对「数据变旧」告警。而这个数据源的失效
恰恰全是静默的。留作备选。

### 选项 D：升级到 Pro（$20/月）

解决不了问题：选项 A 在 Pro 上能跑，但**它依然没有按域名的独立访客/IP 数**。花钱买不到这个指标。

## 决策

**自写 exporter**（`k8s/helm/manifests/monitoring/cf-analytics-exporter/`）。

根因是一条，值得单独记住：它同时解释了「为什么现成的都不行」和「为什么必须自己数」：

| GraphQL 数据集 | 本 zone（Free） | 谁依赖它 |
|---|---|---|
| `httpRequests1mGroups` | ❌ `does not have access to the path` | lablabs 及全部 fork 的 zone analytics |
| `httpRequests1hGroups` | ✅ | — |
| `httpRequestsAdaptiveGroups` | ✅ 但单次跨度 ≤ 1 天、保留期仅 1w1d | 官方 exporter 的 hostname 指标 |

免费版唯一能按域名拆的数据集是 `httpRequestsAdaptiveGroups`，而它**没有 `uniq` 字段**
（实测报 `unknown field "uniq"`）。所以「每个域名多少个独立 IP」只能靠
**拉 `clientIP` 维度回来在本地去重**：没有任何现成 exporter 这么做，因为这在付费版上
本来就有更省事的算法。

自写的代价被刻意压到最低：**~200 行纯标准库 Python，零第三方依赖，不建镜像**
（通用 `python:3.12-alpine` + ConfigMap 挂脚本）。

## 后果

- ✅ 拿到了买不到也装不来的指标：按域名的独立访问 IP 数，以及**按来源的分类**
  （真人 / 已验证爬虫 / 自建监控 / CF 边缘预取）：后者 2026-08-15 补齐，用的是同一条
  查询多加两个维度，**零额外 API 调用**。口径见
  [reference/public-traffic-analysis.md](../reference/public-traffic-analysis.md)。
- ☠️ **它立刻揭穿了一件事**：原始访问量约 45% 是自建监控（Uptime Kuma / Alertmanager
  绕公网回来），`argocd`/`vault`/`auth` 三个域名 100% 是它、真人 IP 为 0，与
  [slo-availability-targets.md](slo-availability-targets.md) 从 Envoy 侧得出的结论互相印证。
- ⚠️ **多了一份要自己跟的代码**。缓解措施都已落地，别拆：
  - `check-embedded-scripts.py` 的 **E1** 盯住「`.py` 源 ↔ ConfigMap 内嵌副本」漂移，
    并用 pod 模板的 checksum 注解逼 ArgoCD 在脚本变更时滚动重启
    （见 [manifest-safety-checks.md](../reference/manifest-safety-checks.md)）。
  - 4 条告警覆盖它**全部是静默的**失效面（`cf-analytics-alerts.yaml`）。
- ⚠️ **按域名只有 7–8 天历史**，这是套餐保留期不是配置失误。真要长期趋势，
  得靠 Prometheus 自己的 retention 把每天的值攒下来。
- ☠️ **不导出任何客户端 IP 本身**，只导出去重后的计数：原始 IP 是访客 PII，
  且仓库「不落公网 IP」的硬约束同样适用于指标标签。
- 🔁 **重新评估的触发条件**：zone 升到 Pro/Business；或上游任一 exporter 开始支持
  `httpRequestsAdaptiveGroups` + 按 hostname 的独立访客。届时优先换回现成方案。

## 参考

- [cloudflare/cloudflare-prometheus-exporter](https://github.com/cloudflare/cloudflare-prometheus-exporter)
- [lablabs/cloudflare-exporter](https://github.com/lablabs/cloudflare-exporter)
- [Cloudflare Analytics: Prometheus 集成](https://developers.cloudflare.com/analytics/analytics-integrations/prometheus/)
- [Cloudflare GraphQL API 错误与访问控制](https://developers.cloudflare.com/analytics/graphql-api/errors/)
