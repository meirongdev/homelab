# 公网访问分析 —— 谁在访问我的服务

> Last updated: 2026-08-15
> Status: 生效事实
> Scope: 「有多少人访问了哪个域名、其中多少是真人 / 爬虫 / 我自己的机器」——
> 口径定义、可信度分级、已知失真、查询配方。数据由 cf-analytics-exporter 从
> Cloudflare Analytics API 桥接。
> **入口链路本身**（Tunnel 健康、cloudflared 指标）见
> [cloudflare-tunnel-observability.md](cloudflare-tunnel-observability.md)。
> **看到认不出来的流量、想下钻到具体 IP/path/状态码**，见
> [../runbooks/suspicious-traffic-investigation.md](../runbooks/suspicious-traffic-investigation.md)。

## 先读这一条

☠️ **原始访问量里约 45% 不是访客，是你自己的机器。**

Uptime Kuma、Alertmanager 这些自建组件访问公网域名时，请求会**绕出公网再回来**
（本机 → 公网出口 → Cloudflare 边缘 → Tunnel → 服务），所以 Cloudflare 把它们当成
正常访客记了下来。2026-08-14 实测：

| 域名 | 总请求 | 其中自建监控 | 真人 IP |
|---|---|---|---|
| `argocd.meirong.dev` | 1,453 | **100%** | **0** |
| `vault.meirong.dev` | 1,453 | 99% | 1 |
| `auth.meirong.dev` | 1,447 | 100% | 1 |
| `notebook.meirong.dev` | 1,496 | 96% | 11 |
| `jobs.meirong.dev` | 1,593 | 91% | 37 |
| `grafana.meirong.dev` | 3,301 | 44% | 4 |
| `meirong.dev`（主站） | 10,056 | 0% | 1,868 |

那一串 **~1440** 是 Uptime Kuma 每 60 秒探一次的结果（24×60=1440）。

⚠️ **所以「某某域名昨天有 N 个访客」这句话，不指明口径就是错的。** 面板上默认展示
「疑似真人 IP」，要原始数字得自己切。这与
[decisions/slo-availability-targets.md](../decisions/slo-availability-targets.md)
里从 Envoy 侧得出的「vault/argocd 真实流量≈0」是同一件事的两次独立印证。

## 三个数据源，量的不是同一件事

排查时最容易犯的错是拿它们互相对账。它们在链路的不同位置：

```text
访客 → Cloudflare 边缘 ──→ Tunnel ──→ Cilium Gateway ──→ Service
        ①                    ②           ③
```

| | ① Cloudflare Analytics | ② cloudflared | ③ cilium-envoy |
|---|---|---|---|
| 面板 | 本文 / `cf-analytics-overview` | — | `ingress-traffic-overview` |
| 位置 | **边缘**，缓存命中/WAF 拦截都算 | 隧道自身 | Cloudflare **之后**，服务实收 |
| 维度 | **域名** + 客户端 IP + 来源分类 | 隧道/PoP，**无 hostname** | **服务**（`ns_svc`）+ 状态码 |
| 粒度 | 天 | 秒级 | 秒级 |
| 回溯 | 按域名 7–8 天 / 全站 14 天 | Prometheus retention (7d) | 同左 |
| 适合回答 | 谁来了、来自哪、是不是机器人 | 隧道通不通 | 服务真实负载与错误率 |

①和③对不上是**正常的**：差额 = 边缘缓存命中 + WAF 拦截 + Cloudflare 直接应答的部分。

## 来源分类法

exporter 把每一条 `(clientIP, host, verifiedBotCategory, userAgent)` 分组归进一个桶。
**判据可信度从高到低，顺序即优先级**（见 `exporter.py` 的 `classify()`）：

| class | 判据 | 可信度 | 2026-08-14 占比 |
|---|---|---|---|
| `verified_bot` | Cloudflare 的 `verifiedBotCategory` 非空 | ✅ **权威**：CF 反查 IP 归属验证，UA 伪造无效 | 5.2% |
| `cf_infra` | UA 含 `early hints` | ✅ 确定：Cloudflare 边缘自己的预取，**不是访客** | 4.8% |
| `self_monitor` | UA 命中 `SELF_MONITOR_AGENTS` 白名单 | ⚠️ 靠白名单，见下方维护约定 | **45.1%** |
| `unverified_bot` | UA 含 bot/spider/crawl/slurp… | ⚠️ 启发式（如 Sogou web spider） | 0.8% |
| `tool` | UA 含 curl/wget/python-requests… | ⚠️ 启发式。**可能是我也可能是别人**，故不并入 self_monitor | 3.2% |
| `browser` | UA 以 `Mozilla/` 开头 | ⚠️ **不等于真人** —— 伪装成浏览器的爬虫都在这里 | 38.9% |
| `unknown` | 其余（空 UA、iOS NetworkingExtension、扫描器…） | — | 2.0% |

### 「疑似真人」是怎么算的

`cf_analytics_daily_client_ips_human` = **发过至少一次 `browser` / `tool` / `unknown`
请求**的独立 IP 数。

☠️ **不是「按 class 分别去重再相减」** —— 那样算是错的，而且错得很隐蔽：
`cf_infra`（Early Hints）携带的是**真实访客的 IP**（2026-08-14 有 927 个），
自建监控则只有 2 个 IP。也就是说 45% 的失真几乎全在**请求数**上、不在 IP 数上。
早期按 class 排除 IP 的写法只把总数从 2416 减到 2415 —— 一个看起来在工作、
实际什么也没做的指标。

## 指标清单

全部是 **gauge**，值的口径是「某个完整 UTC 自然日」，`date` 是**标签不是时间戳**。

| 指标 | 含义 |
|---|---|
| `cf_analytics_daily_client_ips_human{host,date}` | **疑似真人访客 IP 数**（通常你要的是这个） |
| `cf_analytics_daily_client_ips{host,date}` | 独立 IP 总数，不做任何剔除 |
| `cf_analytics_daily_requests{host,date}` | 请求数总计 |
| `cf_analytics_daily_requests_by_class{host,date,class}` | 按来源的请求数 —— **可相加** |
| `cf_analytics_daily_client_ips_by_class{host,date,class}` | 按来源的独立 IP 数 —— ☠️ **不可相加** |
| `cf_analytics_daily_bot_requests{date,category}` | 全站已验证爬虫，按 CF 分类 |
| `cf_analytics_daily_uniques{date}` | Cloudflare 自己算的全站 uniq（另一个数据集） |
| `cf_analytics_scrape_success` / `_last_success_timestamp_seconds` | 采集健康 |
| `cf_analytics_host_window_days` / `_host_days_failed` / `_rows_truncated` | 窗口与数据质量 |

`host="__total__"` 是全站汇总，**跨域名再去重过**，所以各域名之和会大于它
（同一个 IP 常访问多个子域）。

☠️ **三个「独立 IP」互不等价，别互相对账**：`client_ips`（我们数的）、
`client_ips_human`（剔除后）、`daily_uniques`（Cloudflare 的 uniq，口径不公开、
adaptive 数据集有自适应采样）。2026-08-14 分别是 2416 / 1966 / 2376。

## 常用问题 → PromQL

在 Grafana 的 Prometheus 数据源里直接用。`$date` 换成 `2026-08-14` 这样的完整 UTC 日。

```promql
# 昨天全站有多少真人访客？
max(cf_analytics_daily_client_ips_human{host="__total__", date="$date"})

# 哪些域名真的有人在用？（真人 IP 降序）
topk(20, max by (host) (cf_analytics_daily_client_ips_human{host!="__total__", date="$date"}))

# 哪些域名只有我自己的监控在访问？（真人 IP = 0 但有请求）
max by (host) (cf_analytics_daily_client_ips_human{host!="__total__", date="$date"}) == 0

# 某个域名的流量构成
sum by (class) (cf_analytics_daily_requests_by_class{host="book.meirong.dev", date="$date"})

# 自建监控占了多少请求？
sum(cf_analytics_daily_requests_by_class{host="__total__", class="self_monitor", date="$date"})
  / max(cf_analytics_daily_requests{host="__total__", date="$date"})

# 谁在爬我的站？（Cloudflare 验证过的）
sort_desc(sum by (category) (cf_analytics_daily_bot_requests{date="$date"}))

# 某域名流量涨了 —— 是真人还是爬虫？（对比两天）
max by (host) (cf_analytics_daily_client_ips_human{date="2026-08-14"})
  - max by (host) (cf_analytics_daily_client_ips_human{date="2026-08-13"})
```

## 免费版的能力边界

zone `meirong.dev` 是 **Free 套餐**（`plan id = 0feeeeeeeeeeeeeeeeeeeeeeeeeeeeee`）。
以下都是 2026-08-15 用本仓库 token 逐条实测的，**别照文档猜**：

**拿得到**：`verifiedBotCategory` · `userAgent` · `userAgentBrowser` · `userAgentOS` ·
`clientDeviceType` · `requestSource` · `clientIP` · `clientCountryName` ·
`clientRequestHTTPHost`

**拿不到（403 `does not have access to the field`）**：

- ❌ `clientAsn` / `clientASNDescription` —— **判断「这个 IP 属于 AWS/Hetzner 等数据中心
  还是住宅宽带」的最直接手段**。所以本仓库**没有真正的「服务器 IP」判定**，
  只有上面那套基于 UA + CF 验证名单的近似。
- ❌ `botScore` / `botManagementDecision` / `botScoreSrcName` —— Bot Management，Enterprise。
- ❌ `threatIntelIpDatasets`
- ❌ `httpRequests1mGroups` 整个数据集（这也是现成 exporter 全部失效的原因，见
  [decisions/cf-analytics-custom-exporter.md](../decisions/cf-analytics-custom-exporter.md)）

**还有两条时间上的硬限制**：`httpRequestsAdaptiveGroups` 单次查询跨度 ≤ 1 天，
且保留期只有 **1w1d（约 8 天）**。所以按域名的历史最多 7–8 天；更久要靠 Prometheus
自己的 retention 把每天的值攒下来。全站 uniques 走 `httpRequests1dGroups`，不受此限。

## 维护约定

☠️ **`SELF_MONITOR_AGENTS` 是显式白名单** —— 定义在 `exporter.py`，可用同名环境变量覆盖。
当前值：`uptime-kuma,alertmanager,prometheus/,grafana/,argocd,kube-probe,blackbox`。

**新上一个会访问公网域名的组件（探测器 / 同步器 / webhook）必须加进这份名单**，
否则它会被算成外部访客。和 restic 备份白名单同一类陷阱：**漏了不报错，只是数字悄悄变胖**。
改完在 `k8s/helm/` 跑 `just gen-embedded-scripts`（E1 会拦住忘记重新生成的情况）。

`unknown` 占比是这套分类法的体检指标：2026-08-15 基线 **2.0%**。明显上涨说明来了新的
客户端类型，值得看一眼 top UA：

```bash
# 仓库根目录；token 从集群里取，不落盘
TOKEN=$(kubectl --context k3s-homelab get secret cf-analytics-cloudflare -n monitoring \
  -o jsonpath='{.data.api-token}' | base64 -d)
curl -s -X POST https://api.cloudflare.com/client/v4/graphql \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"query":"query { viewer { zones(filter: {zoneTag: \"<ZONE_ID>\"}) { httpRequestsAdaptiveGroups(limit: 15, filter: {date_geq: \"2026-08-14\", date_leq: \"2026-08-14\"}, orderBy: [count_DESC]) { dimensions { userAgent } count } } } }"}'
```

⚠️ **拿真实 token 测第三方软件时别开 debug 日志** —— lablabs 那个 exporter 会把
`Authorization: Bearer <token>` 完整打进日志（2026-08-15 因此烧掉过一把 token）。

## 隐私与安全约束

☠️ **不导出任何客户端 IP 本身**，只导出去重后的计数。原因有两条，缺一不可：
访客 IP 是 PII；而且放进 Prometheus label 会把基数炸到几千。
仓库「不落公网 IP」的硬约束（CI 的 `check-public-ips.py`）同样适用于指标标签与文档。
本文里出现的自有出口 IP 一律打码。

## 排查

采集侧的失效**全是静默的**（pod Running、探针绿、面板照常出图，只是数字停在几天前），
所以判断"数据还在不在更新"要看指标不要看 pod：

```bash
# 集群 k3s-homelab
kubectl --context k3s-homelab logs -n monitoring deploy/cf-analytics-exporter --tail=20
```

四条告警的触发条件与处置见
[observability-alerting-slo.md](observability-alerting-slo.md) 的 cf-analytics 条目，
规则本体在 `k8s/helm/manifests/monitoring/alerts/cf-analytics-alerts.yaml`。
