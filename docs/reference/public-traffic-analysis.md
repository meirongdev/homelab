# 公网访问分析：谁在访问我的服务

> Last updated: 2026-10-28
> Status: 生效事实
> Scope: 「有多少人访问了哪个域名、其中多少是真人 / 爬虫 / 我自己的机器」，以及
> 「博客的哪几篇文章被读了」：口径定义、可信度分级、已知失真、查询配方。数据由
> cf-analytics-exporter 从 Cloudflare Analytics API 桥接。
> 入口链路本身（Tunnel 健康、cloudflared 指标）见
> [cloudflare-tunnel-observability.md](cloudflare-tunnel-observability.md)。
> 看到认不出来的流量、想下钻到具体 IP/path/状态码，见
> [../runbooks/suspicious-traffic-investigation.md](../runbooks/suspicious-traffic-investigation.md)。

## 先读这一条

☠️ **原始访问量里约 45% 不是访客，是你自己的机器**（2026-08-14 实测）。

Uptime Kuma、Alertmanager 这些自建组件访问公网域名时，请求绕出公网再回来（本机 → 公网出口 →
Cloudflare 边缘 → Tunnel → 服务），Cloudflare 把它们当正常访客记下。同日实测 `argocd` / `vault` /
`auth` 三个域名的请求 99–100% 是它、真人 IP 0–1 个，`grafana` 44%，主站 `meirong.dev` 0%。
每个被探的域名每天约 1440 次，就是 Uptime Kuma 每 60 秒一次。

⚠️ **所以「某某域名昨天有 N 个访客」不指明口径就是错的。** 面板默认展示「疑似真人 IP」，要原始数字
得自己切。Envoy 侧的独立印证见
[decisions/slo-availability-targets.md](../decisions/slo-availability-targets.md)（vault/argocd 真实流量≈0）。

## 三个数据源，量的不是同一件事

排查时最容易犯的错是拿它们互相对账。它们在链路的不同位置：

```text
访客 → Cloudflare 边缘 ──→ Tunnel ──→ Cilium Gateway ──→ Service
        ①                    ②           ③
```

| | ① Cloudflare Analytics | ② cloudflared | ③ cilium-envoy |
|---|---|---|---|
| 面板 | 本文 / `cf-analytics-overview` | — | `ingress-traffic-overview` |
| 位置 | 边缘，缓存命中/WAF 拦截都算 | 隧道自身 | Cloudflare 之后，服务实收 |
| 维度 | 域名 + 客户端 IP + 来源分类 | 隧道/PoP，无 hostname | 服务（`ns_svc`）+ 状态码 |
| 粒度 | 天 | 秒级 | 秒级 |
| 回溯 | 按域名 7–8 天 / 全站 14 天 | Prometheus retention | 同左 |
| 适合回答 | 谁来了、来自哪、是不是机器人 | 隧道通不通 | 服务真实负载与错误率 |

①和③对不上是正常的：差额 = 边缘缓存命中 + WAF 拦截 + Cloudflare 直接应答的部分。

## 来源分类法

exporter 把每一条 `(clientIP, host, verifiedBotCategory, userAgent)` 分组归进一个桶。
**判据可信度从高到低，顺序即优先级**（`exporter.py` 的 `classify()`）：

| class | 判据 | 可信度 |
|---|---|---|
| `verified_bot` | Cloudflare 的 `verifiedBotCategory` 非空 | ✅ 权威：CF 反查 IP 归属验证，UA 伪造无效 |
| `cf_infra` | UA 含 `early hints` | ✅ 确定：Cloudflare 边缘自己的预取，不是访客 |
| `self_monitor` | UA 命中 `SELF_MONITOR_AGENTS` 白名单 | ⚠️ 靠白名单，见「维护约定」 |
| `unverified_bot` | UA 含 bot/spider/crawl/slurp… | ⚠️ 启发式（如 Sogou web spider） |
| `tool` | UA 含 curl/wget/python-requests… | ⚠️ 启发式。可能是我也可能是别人，故不并入 self_monitor |
| `browser` | UA 以 `Mozilla/` 开头 | ⚠️ **不等于真人**：伪装成浏览器的爬虫都在这里 |
| `unknown` | 其余（空 UA、iOS NetworkingExtension、扫描器…） | — |

### 「疑似真人」是怎么算的

`cf_analytics_daily_client_ips_human` = 发过至少一次 `browser` / `tool` / `unknown` 请求的独立 IP 数。

☠️ **不是「按 class 分别去重再相减」**：`cf_infra`（Early Hints）携带的是真实访客的 IP，自建监控
只有 2 个 IP，45% 的失真几乎全在请求数上、不在 IP 数上。按 class 排除 IP 的写法几乎减不掉任何东西，
是个看起来在工作、实际什么也没做的指标。

## 指标清单

全部是 gauge，值的口径是「某个完整 UTC 自然日」，`date` 是**标签不是时间戳**。

| 指标 | 含义 |
|---|---|
| `cf_analytics_daily_client_ips_human{host,date}` | 疑似真人访客 IP 数（通常你要的是这个） |
| `cf_analytics_daily_client_ips{host,date}` | 独立 IP 总数，不做任何剔除 |
| `cf_analytics_daily_requests{host,date}` | 请求数总计 |
| `cf_analytics_daily_requests_by_class{host,date,class}` | 按来源的请求数，**可相加** |
| `cf_analytics_daily_client_ips_by_class{host,date,class}` | 按来源的独立 IP 数，☠️ **不可相加** |
| `cf_analytics_daily_bot_requests{date,category}` | 全站已验证爬虫，按 CF 分类 |
| `cf_analytics_daily_uniques{date}` | Cloudflare 自己算的全站 uniq（另一个数据集） |
| `cf_analytics_daily_page_requests{path,date}` | 博客单个页面的 200 HTML 请求数（含爬虫） |
| `cf_analytics_daily_page_requests_browser{path,date}` | 同上，只数 UA 是已知浏览器的（**通常你要的是这个**） |
| `cf_analytics_page_rows_truncated` | 按 path 的查询撞到行数上限则为 1 |
| `cf_analytics_scrape_success` / `_last_success_timestamp_seconds` | 采集健康 |
| `cf_analytics_host_window_days` / `_host_days_failed` / `_rows_truncated` | 窗口与数据质量 |

`host="__total__"` 是全站汇总，跨域名再去重过，所以各域名之和会大于它（同一个 IP 常访问多个子域）。

☠️ **三个「独立 IP」互不等价，别互相对账**：`client_ips`（我们数的）、`client_ips_human`（剔除后）、
`daily_uniques`（Cloudflare 的 uniq，口径不公开、adaptive 数据集有自适应采样）。

## 按文章（path）的访问量

只对**博客那一个域名**（`meirong.dev`，exporter 的 `BLOG_HOST`）拆 path，其余子域是服务不是内容，
它们的 path 全是自建监控探针打出来的。

**只数 `edgeResponseStatus=200` 且 `edgeResponseContentTypeName=html` 的请求**（2026-09-06 实测）：
只按 host + 200 过滤时 css/js/字体占满行数，页面不到一半；加 `html` 后离 10000 行硬上限余量充足。
该域名 HTML 从不返回 304，所以只数 200 不漏带缓存的回访。

☠️ **`_browser` 是真人的近似，不是真人数。** 判据是 Cloudflare 解析出的浏览器名（`userAgentBrowser`）
非空、不是 `Unknown`、不含 bot/spider/crawl，且 CF 没把它标成已验证爬虫。伪装成 Chrome 的爬虫仍算在
里面（免费版拿不到 `botScore`，这是能做到的上限）。它与分类法里的 `browser` class 不是一回事（那个看
原始 UA 前缀），别互相对账。

⚠️ **两列差一个量级是正常的**：首页 `/` 的 HTML 请求绝大多数不来自已知浏览器（脚本刷首页），具体文章页
几乎全来自浏览器。排序、看趋势一律用 `_browser`。

⚠️ **指标侧每天只保留前 50 个 path**（`PAGE_TOP_N`，按 `_browser` 降序），其余并进
`path="__other__"`。完整长尾只在下面的长期表里（全量进 Prometheus 的 series 数不值当）。

### 长期表 `blogstats.blog_pageviews`

Cloudflare 按 path 只留 8 天、Prometheus 只留 14 天，而「某篇文章累计被读了多少」按年算。所以 exporter
多一个 `/pages.csv`（完整明细、不做 top-N），`blog-stats-rollup` CronJob 每天 UPSERT 进共享实例
`apps-pg` 的 `blogstats` 库：

```text
blog_pageviews(day, path, requests, browser_requests, updated_at)  PK (day, path)
```

窗口里每天都重发一遍是刻意的：**≤8 天的中断下一轮自己补齐**，超过 8 天才是永久空洞
（`BlogStatsRollupStale` 3 天就报，留 5 天处置余量）。取舍与激活步骤见
[decisions/blog-pageview-rollup-store.md](../decisions/blog-pageview-rollup-store.md)。

面板 `blog-pageviews`（Grafana / Platform）上半来自 Prometheus（8 天、按 path），下半来自这张表（长期、
吃时间选择器）。☠️ 两半窗口不同，别互相对账。Grafana 用只读角色 `blogstats_ro` 连（`INSERT`/`DROP`
均被拒）。命令行看：

```bash
# 任意目录，集群 k3s-homelab。blogstats 的口令在 Vault homelab/blogstats（ESO 同步）
kubectl --context k3s-homelab exec -n databases deploy/apps-pg -- \
  psql -U postgres -d blogstats -c \
  "SELECT path, sum(browser_requests) v FROM blog_pageviews
     WHERE path LIKE '/posts/%' GROUP BY path ORDER BY v DESC LIMIT 10"
```

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

# 昨天哪几篇文章被读得最多？（只数已知浏览器，排除 __other__ 汇总桶）
topk(10, cf_analytics_daily_page_requests_browser{date="$date", path!="__other__"})

# 某篇文章这 8 天的曲线（date 是标签 → 用 barchart + instant，不要用时间轴）
cf_analytics_daily_page_requests_browser{path="/posts/kafka-producer-tccl-fat-jar/"}

# 这个页面是被人读还是被脚本刷？（比值越低越像脚本）
cf_analytics_daily_page_requests_browser{date="$date"}
  / cf_analytics_daily_page_requests{date="$date"}

# 某域名流量涨了，是真人还是爬虫？（对比两天）
max by (host) (cf_analytics_daily_client_ips_human{date="2026-08-14"})
  - max by (host) (cf_analytics_daily_client_ips_human{date="2026-08-13"})
```

## 免费版的能力边界

zone `meirong.dev` 是 Free 套餐（`plan id = 0feeeeeeeeeeeeeeeeeeeeeeeeeeeeee`）。以下用本仓库 token
逐条实测过，**别照文档猜**；「清单里没写」也不等于「拿不到」，加维度前自己发一条查询试。

拿得到：`verifiedBotCategory` · `userAgent` · `userAgentBrowser` · `userAgentOS` ·
`clientDeviceType` · `requestSource` · `clientIP` · `clientCountryName` ·
`clientRequestHTTPHost` · `clientRequestPath` · `edgeResponseStatus` ·
`edgeResponseContentTypeName`（既能当维度也能当过滤器，按 path 的查询靠它挡掉静态资源）

拿不到（403 `does not have access to the field`）：

- ❌ `clientAsn` / `clientASNDescription`：判断「IP 属于数据中心还是住宅宽带」最直接的手段。所以本仓库
  没有真正的「服务器 IP」判定，只有上面那套基于 UA + CF 验证名单的近似。
- ❌ `botScore` / `botManagementDecision` / `botScoreSrcName`：Bot Management，Enterprise。
- ❌ `threatIntelIpDatasets`
- ❌ `httpRequests1mGroups` 整个数据集（现成 exporter 全部失效的原因，见
  [decisions/cf-analytics-custom-exporter.md](../decisions/cf-analytics-custom-exporter.md)）

**两条时间上的硬限制**：`httpRequestsAdaptiveGroups` 单次查询跨度 ≤ 1 天，保留期只有 1w1d（约 8 天）。
所以按域名的历史最多 7–8 天，更久要靠 Prometheus 把每天的值攒下来。全站 uniques 走
`httpRequests1dGroups`，不受此限。

### RUM（Web Analytics）数据集

同一把 token（`secret/homelab/external-dns`，两处复用）**能读 account 作用域的
`rumPageloadEventsAdaptiveGroups`**，beacon 也在跑，不需要另发 account-scoped token。
☠️ 别用不带 filter 的 `{ viewer { accounts { accountTag } } }` 判作用域：它要的是「列出账号」权限，
会返回 0 个 account + `not authorized for that account`（code `authz`），看着像没权限；加上
`filter:{accountTag:"<id>"}` 就正常。判作用域只能直接查目标数据集。

它是**另一种口径**，不是边缘数据的升级版：不含爬虫（爬虫不执行 JS，`bot` 维度恒 0），但会被 adblock
吃掉一部分；**account 作用域覆盖全部主机名，必须按 `requestHost` 过滤**；独有 `deviceType` /
`refererHost` / `refererPath` / `countryName` / `navigationType` / `siteTag` 等维度。
☠️ **`count` 是抽样放大的，只落在 10 的倍数上**，而按文章的信号每天只有个位到十几次，长尾被量化成
0 或 10，**不能拿它做按文章排序**。定位是「并存加一列」，实测对比与取舍见
[decisions/blog-pageview-rollup-store.md](../decisions/blog-pageview-rollup-store.md)。

查询形态的三个坑：`dimensions` **不是入参**（选哪几个 dimension 字段就按它们分组）·
`confidence` 裸选报 `level: not a number`（要带参数）· `limit` 必填。

## 维护约定

☠️ **`SELF_MONITOR_AGENTS` 是显式白名单**，定义在 `exporter.py`，可用同名环境变量覆盖。
当前值：`uptime-kuma,alertmanager,prometheus/,grafana/,argocd,kube-probe,blackbox`。

**新上一个会访问公网域名的组件（探测器 / 同步器 / webhook）必须加进这份名单**，否则它会被算成外部
访客。和 restic 备份白名单同一类陷阱：漏了不报错，只是数字悄悄变胖。改完在 `k8s/helm/` 跑
`just gen-embedded-scripts`（E1 会拦住忘记重新生成的情况）。

`unknown` 占比是这套分类法的体检指标（2026-08-15 基线 2.0%）。明显上涨说明来了新的客户端类型，
值得看一眼 top UA：

```bash
# 仓库根目录；token 从集群里取，不落盘
TOKEN=$(kubectl --context k3s-homelab get secret cf-analytics-cloudflare -n monitoring \
  -o jsonpath='{.data.api-token}' | base64 -d)
curl -s -X POST https://api.cloudflare.com/client/v4/graphql \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"query":"query { viewer { zones(filter: {zoneTag: \"<ZONE_ID>\"}) { httpRequestsAdaptiveGroups(limit: 15, filter: {date_geq: \"2026-08-14\", date_leq: \"2026-08-14\"}, orderBy: [count_DESC]) { dimensions { userAgent } count } } } }"}'
```

⚠️ **拿真实 token 测第三方软件时别开 debug 日志**：lablabs 那个 exporter 会把
`Authorization: Bearer <token>` 完整打进日志，本仓库因此烧掉过一把 token。

## 隐私与安全约束

☠️ **不导出任何客户端 IP 本身**，只导出去重后的计数。原因有两条，缺一不可：访客 IP 是 PII；放进
Prometheus label 会把基数炸到几千。仓库「不落公网 IP」的硬约束（CI 的 `check-public-ips.py`）同样适用于
指标标签与文档，本文出现的自有出口 IP 一律打码。

## 排查

采集侧的失效全是静默的（pod Running、探针绿、面板照常出图，只是数字停在几天前），所以判断数据还在
不在更新要看指标不要看 pod：

```bash
# 任意目录，集群 k3s-homelab
kubectl --context k3s-homelab logs -n monitoring deploy/cf-analytics-exporter --tail=20
```

`cf-analytics-alerts.yaml` 的 6 条告警（规则本体在 `k8s/helm/manifests/monitoring/alerts/`）的触发条件与
处置见 [observability-alerting-slo.md](observability-alerting-slo.md) 的 cf-analytics 条目。
