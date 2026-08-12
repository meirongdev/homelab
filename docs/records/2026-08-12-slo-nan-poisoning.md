# SLI 的 0/0 产出 NaN，毒死全部 SLO 的 30d 错误预算——面板全 N/A，无人告警

> 日期: 2026-08-12
> 影响: Grafana「SLO / Service Availability」看板的**错误预算剩余**与**燃尽率**面板，
>       5 个服务（grafana / vault / argocd / calibre-web / zitadel）**全部显示 N/A**。
>       告警链路未受影响（多窗口燃尽率用的都是 ≤3d 窗口，走另一条计算路径），
>       所以这是**纯观测面失效**：预算烧到哪儿了看不见，但真出 5xx 仍会 page。
> 根因: SLI = errorQuery/totalQuery，零请求窗口里两边都是 0 → **0/0 = NaN**，且 NaN
>       被当正常样本写入 TSDB。Sloth 的周期窗口(30d)规则是
>       `sum_over_time(ratio_rate5m[30d]) / count_over_time(...)`，
>       **sum_over_time 遇 NaN 全程传染 → 一个 NaN 样本毒死整条 30d 序列**。
> 结果: 5 条 totalQuery 全部加 `(... > 0) OR on() vector(1)` 兜底；
>       新增 `SLOSLIProducingNaN` 哨兵告警防复发；面板文案纠正。
> 触发: 人肉看面板觉得"这些都是无流量的，看过去不太正常"——**没有任何自动信号**。

## 一句话根因

**空闲窗口的 `rate()` 不是空集，是值为 0 的真实样本。** 分子已经用
`OR on() vector(0)` 兜过底，分母却没有，于是 0/0 = NaN 落进 TSDB；
再被 `sum_over_time` 汇总时污染整个 30 天窗口。

## 症状 vs 真相

看板显示"无流量"，但流量一直都在。Grafana 入口过去 1h `totalQuery = 0.057 req/s`，
计数器 2xx=1959 / 3xx=3179 / 4xx=150 / 5xx=3。

同一个 SLO 各窗口的实测值，只有最后一列是坏的：

| SLO | 5m | 30m | 1h | 2h | 6h | 1d | 3d | **30d** |
|---|---|---|---|---|---|---|---|---|
| grafana-availability | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **NaN** |

传染链：`ratio_rate30d` → `slo:period_burn_rate:ratio` →
`slo:period_error_budget_remaining:ratio` → 面板 N/A。

## 为什么只有 30d 窗口坏

Sloth 对**周期窗口**用汇总优化（省 TSDB 扫描），对短窗口直接算——两种规则形态：

```promql
# 1d / 3d —— 直接 rate()，跨度大到不可能零流量，永不 NaN
sum(rate(envoy_cluster_upstream_rq_xx{...}[3d]))

# 30d —— 拿 5m 录制规则求平均，NaN 在这里传染
sum_over_time(slo:sli_error:ratio_rate5m{...}[30d])
  / ignoring (sloth_window) count_over_time(slo:sli_error:ratio_rate5m{...}[30d])
```

**污染阈值低到离谱**：可见窗口内的 NaN 占比——

| SLO | NaN / 总样本 | 占比 |
|---|---|---|
| grafana | 6 / 2061 | 0.3% |
| vault | 10 / 2061 | 0.5% |
| argocd | 7 / 2056 | 0.3% |
| calibre-web | 2 / 2055 | 0.1% |
| zitadel | 2005 / 2048 | 97.9% |

**0.1% 就够了**——calibre-web 三万分之二的样本毁掉整月预算数。

## 为什么潜伏这么久没被发现

三重伪装叠在一起，每一层都把异常解释成正常：

1. **面板文案主动辟谣**。dashboard 里写着 `"N/A 无流量"` 和
   "无流量服务显示 N/A（NaN：rate() 无样本，SLI 无法计算，**非故障**）"。
   看板作者当初预判的是"低流量 homelab 偶尔没数据"，于是给故障预先盖了章。
2. **告警链路完好**。≤3d 窗口全部正常工作，`ALERTS` 里干干净净，
   所有"监控在工作"的常规信号都是绿的。
3. **确实有一个是真无流量**。zitadel 7 天只有 138 个请求（~0.8 req/h），
   97.9% 的 5m 窗口真的是空的——它的 N/A 名副其实，进一步佐证了"就是没流量"的误判。

> 与 [2026-08-11 Gateway API CRD](2026-08-11-gateway-api-crd-stall.md) 同型：
> **老路径全绿、只有新增/边缘路径静默失效**，且缺少针对"监控自身"的检查。

## 证据

```bash
kubectl --context k3s-homelab -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090
# 各窗口对比：短窗口 0，30d NaN
curl -sG --data-urlencode 'query=slo:sli_error:ratio_rate3d'  localhost:19090/api/v1/query
curl -sG --data-urlencode 'query=slo:sli_error:ratio_rate30d' localhost:19090/api/v1/query
# 原始指标确有流量（反证"无流量"说法）
curl -sG --data-urlencode 'query=envoy_cluster_upstream_rq_xx' localhost:19090/api/v1/query
# 揪出 NaN 序列（NaN 参与比较恒 false，> -1 会把它过滤掉）
curl -sG --data-urlencode 'query=slo:sli_error:ratio_rate5m unless (slo:sli_error:ratio_rate5m > -1)' \
  localhost:19090/api/v1/query
```

生成的规则原文（确认 30d 与 3d 的形态差异）：

```bash
kubectl --context k3s-homelab -n monitoring get prometheusrule homelab-gateway-availability -o yaml \
  | grep -B12 'record: slo:sli_error:ratio_rate30d'
```

## 修复

`k8s/helm/manifests/monitoring/slos.yaml`，5 条 totalQuery 统一加分母兜底：

```promql
# 之前
totalQuery: sum(rate(envoy_cluster_upstream_rq_xx{...}[{{.window}}]))
# 之后
totalQuery: (sum(rate(envoy_cluster_upstream_rq_xx{...}[{{.window}}])) > 0) OR on() vector(1)
```

语义：**空闲窗口记 0 错误 = 健康**。这是可用性 SLO 的常规取法；
"入口整个不可达"属外部视角，由 Uptime Kuma 的公网探测负责，不指望这里的 5xx 比率。

上线前用 range query 对线上 Prometheus 实测（3 天窗口，step=5m）：

| SLO | 样本 | NaN | 汇总后预算剩余 |
|---|---|---|---|
| grafana | 865 | 0 | 100.00% |
| vault | 865 | 0 | 100.00% |
| argocd | 865 | 0 | 100.00% |
| calibre-web | 865 | 0 | 99.88% |
| zitadel | 865 | 0 | 100.00% |

（zitadel 修复前是 97.9% NaN；calibre-web 的 99.88% 对应一次真实 5xx，不是误差。）

防复发哨兵 `SLOSLIProducingNaN`（`alerts/slo-meta-alerts.yaml`）：

```promql
slo:sli_error:ratio_rate5m unless (slo:sli_error:ratio_rate5m > -1)
```

盯 **rate5m 而非 30d 面板**：周期窗口的 NaN 只可能来自 rate5m，它是严格上游，
覆盖 100% 成因且早约 30 天暴露。
⚠️ 不能写成 `count(X) - count(X > -1) > 0`——全 NaN 时右侧空集、减法结果整个消失，
告警永不触发（本仓库 absent 类踩坑同理）。

## ⚠️ 面板不会立刻恢复

`sum_over_time` 仍会读到**已经写进 TSDB 的历史 NaN 样本**。
`web.enable-admin-api=false`，删不了 series，只能等 retention(7d) 自然滚出——
**预计 2026-08-19 前后自愈**。改 `sloth_slo` 名字换新序列可立即生效，
但会断掉告警名与历史连续性，不值得。

## 遗留：两件刻意不改的事

- **30d 周期跑在 7d retention 上**。`count_over_time([30d])` 只返回 20592 个样本
  （30s 间隔 ≈ 7.15 天），所谓"30d 错误预算"实为 ~7 天平均。不改的理由：告警用的
  全是 ≤3d 窗口、在 7d 内完全有效；而 sloth 内置窗口目录只有 30d/28d，换 7d 要自带
  catalog 并重新标定全部燃尽率系数。已在面板标题与描述里注明真实窗口。
  （同一论证此前已用于关掉 chart 的 `kubeApiserverAvailability`，见
  `k8s/helm/values/kube-prometheus-stack.yaml`——当时结论没有推广到 sloth 自己的 SLO。）
- **zitadel 的 SLO 统计意义很弱**（本次已顺手修掉一半）。0.8 req/h 之下，99% 目标里
  一个 5xx 就是 0.7% 预算。查它为什么没流量时**牵出一个独立的更大盲区**：
  ZITADEL 在 Uptime Kuma 的监控清单里**根本不存在**——身份提供方是全站 SSO 的单点依赖，
  却是唯一没有存活探测的对外服务。其余 4 个 SLO 服务三千级的 3xx 计数，正是这组公网探测
  穿过 gateway 留下的底噪；zitadel 全部计数只有 7，因为没有任何探测在打它。
  已补进 `cloud/oracle/manifests/uptime-kuma/provisioner.yaml`
  （`/` → 302 `/ui/login`，实测 2026-08-12，与 Grafana/Vault/Calibre-Web 同款只收 3xx）。
  ⚠️ 探测底噪只能让 SLI 有稳定样本，**不会让 SLO 更能代表真实用户体验**——
  样本量仍以合成流量为主，读这个数时要清楚它测的是"入口通不通"。

## 教训

- **给"没数据"写解释性文案之前，先确认它真的没数据。** 那句"非故障"的注解是这次
  潜伏一个多月的一半原因；文案让人不再去查原始指标。
- **NaN 是会被持久化的正常样本，不是空值。** PromQL 里判它只能靠"NaN 参与任何比较
  都返回 false"（`unless (X > -1)`）或"NaN 不等于自身"（`X != X`）。
- **兜底要兜两头。** 仓库里早有 errorQuery 空集的踩坑注释（2026-07-12），
  但只覆盖了分子；分母是另一条独立路径，且症状完全不同。
- **监控系统自身也要被监控。** 观测面静默失效不会有人喊，靠的是运气或洁癖。
- **retention 短于窗口时，故障起点不可考。** 这次连"坏了多久"都答不上来
  ——可见的 7 天内全程是坏的，之前无从查证。同 2026-08-05 ClusterMesh 那次。
