#!/usr/bin/env python3
"""cf-analytics-exporter — 把 Cloudflare 公网流量聚合暴露为 Prometheus metrics.

数据源: Cloudflare GraphQL Analytics API（zone meirong.dev）。

口径：全部指标面向「完整的 UTC 自然日」（最新 = 昨天），一天一变、不随「今天累计」
上涨 —— 保证 Grafana 里的"每日"数字是终值。exporter 每 6h 刷新一次，Prometheus 60s
抓一次；每个 date 在窗口内被反复上报为同一值，离开窗口后序列自然 stale。

指标（全部 gauge，**不带 `_total` 后缀**：它们是每日快照，不是单调计数器）:
  cf_analytics_daily_uniques{date}                 全站独立访客（Cloudflare uniq.uniques）
  cf_analytics_daily_requests{host,date}           按域名的请求数（host="__total__" = 全站）
  cf_analytics_daily_client_ips{host,date}         按域名的独立客户端 IP 数（同上有 __total__）
  cf_analytics_daily_client_ips_human{host,date}   同上，但只数「发过疑似真人请求」的 IP
  cf_analytics_daily_requests_by_class{host,date,class}   按来源分类的请求数
  cf_analytics_daily_client_ips_by_class{host,date,class} 按来源分类的独立 IP 数
  cf_analytics_daily_bot_requests{date,category}   全站已验证爬虫，按 Cloudflare 分类
  cf_analytics_host_window_days               实际取到按域名数据的完整天数
  cf_analytics_host_days_failed               本轮出错（非保留期原因）的天数
  cf_analytics_rows_truncated                 有某天撞到 ROW_LIMIT 则为 1（IP 数被低估）
  cf_analytics_scrape_success                 本轮全部成功 = 1
  cf_analytics_last_success_timestamp_seconds 上次全量成功的 unix 时间

☠️ **`*_by_class` 的各 class 不可相加成总数**：同一个 IP 可能既发浏览器请求又发
   curl 请求，会同时计入两个 class。要总数用 `cf_analytics_daily_client_ips`，
   要「疑似真人」用 `cf_analytics_daily_client_ips_human` —— 这两个都是**单独去重**
   算出来的，正因为 sum() 会算错才必须单列。请求数（`requests_by_class`）可以相加。

☠️ **不导出任何客户端 IP 本身**，只导出去重后的计数。原始 IP 是访客 PII，且仓库
   有「不落公网 IP」的硬约束；放进 label 还会把基数炸到几千。

Cloudflare 免费版的两条实测硬限制（2026-08-15 用本仓库 token 实测，别照抄文档猜）:
  1. httpRequestsAdaptiveGroups（按 host/IP 拆分的那个数据集）**单次查询时间跨度 ≤ 1 天**
     → 必须逐日查，一天一次调用。
  2. 同一数据集**保留期只有 1w1d（约 8 天）**，更早直接报
     `cannot request data older than 1w1d`。所以按域名的历史最多 ~7–8 天。
     httpRequests1dGroups（全站 uniques）不受此限，实测 30 天可读。
  → 因此 uniques 用「一次查整段」，按域名用「逐日循环」，两者窗口不同。

⚠️ 单日失败**不能**让整轮归零：早期版本把整个循环包在一个 try 里，任何一天报错
   （最常见就是撞保留期）就丢掉全部数据并让 /healthz 503 → livenessProbe 把 pod 打进
   CrashLoop。现在逐日容错：撞保留期 = 正常收窄窗口（break），其它错误只记一天失败。

权限: token 需 Zone > Analytics > Read。复用 external-dns 的 Cloudflare token
      （Vault secret/homelab/external-dns property=api_token，经 ESO 注入本 ns）。

⚠️ 本文件是**源**，容器里跑的是 cf-analytics-exporter-cm.yaml 内嵌的副本。
   改完必须在 `k8s/helm/` 跑 `just gen-embedded-scripts` 重新生成 ConfigMap，
   否则「改的是源、跑的是旧副本」—— CI 的 E1 会拦住这种漂移。
见: docs/reference/public-traffic-analysis.md（口径/分类法/PromQL 配方，唯一真相源）
    docs/decisions/cf-analytics-custom-exporter.md（为什么不用现成 exporter）
"""

import os
import time
import json
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ZONE_ID = os.environ["CF_ZONE_ID"]
API_TOKEN = os.environ["CF_API_TOKEN"]
REFRESH_SECONDS = int(os.environ.get("REFRESH_SECONDS", "21600"))  # 6h
PORT = int(os.environ.get("EXPORTER_PORT", "9901"))
# 全站 uniques 的窗口（httpRequests1dGroups，保留期 ≥30 天，一次查完整段）。
UNIQ_WINDOW_DAYS = int(os.environ.get("UNIQ_WINDOW_DAYS", "14"))
# 按域名的窗口（httpRequestsAdaptiveGroups，逐日查）。设 8 是**故意越界一天**：
# 保留期恰好 1w1d，越界那天会被识别为保留期错误并 break，等于让服务端告诉我们
# 窗口边界在哪，而不是在这里猜一个会随套餐变化的常量。
HOST_WINDOW_DAYS = int(os.environ.get("HOST_WINDOW_DAYS", "8"))
# 单日行数上限。CF 硬上限 10000；2026-08-15 实测四维分组下本 zone 约 1800–3600 行。
ROW_LIMIT = int(os.environ.get("ROW_LIMIT", "10000"))

# ☠️ **显式白名单**：判定「这个请求是我自己的机器发的」全靠这份 User-Agent 子串名单。
# 新上一个会访问公网域名的组件（探测器/同步器/webhook）**必须加进来**，否则它会被
# 算成外部访客 —— 和 restic 备份白名单同一类陷阱：漏了不报错，只是数字悄悄变胖。
# 2026-08-14 实测：自监控占全站请求 45%，argocd/vault/auth 三个域名 100% 是它。
SELF_MONITOR_AGENTS = tuple(
    s.strip().lower() for s in os.environ.get(
        "SELF_MONITOR_AGENTS",
        "uptime-kuma,alertmanager,prometheus/,grafana/,argocd,kube-probe,blackbox",
    ).split(",") if s.strip()
)

# 启发式，不是权威判定（权威的是 Cloudflare 的 verifiedBotCategory）。
# 这些桶只用来把 unknown 压到可接受的比例，别拿它们当安全判断。
BOTISH_AGENTS = ("bot", "spider", "crawl", "slurp", "scrap", "fetcher", "monitoring", "preview")
TOOL_AGENTS = ("curl/", "wget", "python-requests", "go-http-client", "libwww", "httpie",
               "okhttp", "java/", "axios", "node-fetch", "postman", "libcurl")

GRAPHQL = "https://api.cloudflare.com/client/v4/graphql"
TOTAL = "__total__"

# 「疑似真人」的 class 集合。一个 IP 只要**发过至少一个**这类请求就算进
# client_ips_human，而不是按 class 分别去重再相减。
#
# ☠️ 这个区别是实测逼出来的，别改回去：`cf_infra`（Early Hints 预取）携带的是
#    **真实访客的 IP**（2026-08-14 有 927 个），自监控则只有 2 个 IP。也就是说
#    45% 的失真全在**请求数**上、几乎不在 IP 数上。早先按 class 排除 IP 的写法
#    只把总数从 2416 减到 2415 —— 一个看起来在工作、实际什么也没做的指标。
HUMANISH_CLASSES = ("browser", "tool", "unknown")


def classify(bot_category: str, user_agent: str) -> str:
    """把一次请求归到一个来源桶。判据可信度从高到低，顺序即优先级。

    verified_bot   Cloudflare 反查 IP 归属**验证过**的爬虫 —— 唯一权威、伪造不了。
    cf_infra       Cloudflare 边缘自己的 Early Hints 预取，不是访客。2026-08-14 占 4.8%，
                   混进访客数会凭空多出 900+ 个「IP」。
    self_monitor   我自己的机器（见 SELF_MONITOR_AGENTS）。
    unverified_bot UA 自称是爬虫但没被 CF 验证（如 Sogou web spider）。启发式。
    tool           curl/wget/脚本客户端。**可能是我也可能是别人**，故不并入 self_monitor。
    browser        UA 长得像浏览器。⚠️ **不等于真人** —— 伪装成浏览器的爬虫也在这里。
    unknown        其余（空 UA、iOS NetworkingExtension、扫描器…）。2026-08-14 残余 2.0%。
    """
    if bot_category:
        return "verified_bot"
    ua = (user_agent or "").lower()
    if "early hints" in ua:
        return "cf_infra"
    if not ua:
        return "unknown"
    if any(s in ua for s in SELF_MONITOR_AGENTS):
        return "self_monitor"
    if any(s in ua for s in BOTISH_AGENTS):
        return "unverified_bot"
    if any(s in ua for s in TOOL_AGENTS):
        return "tool"
    if ua.startswith("mozilla/"):
        return "browser"
    return "unknown"

_cache = {}
_lock = threading.Lock()


class RetentionExceeded(Exception):
    """CF 拒绝该日期：超出套餐保留期。不是故障，是窗口到头了。"""


def gql(query: str, variables: dict) -> dict:
    """发一次 GraphQL 查询；把 errors 转成异常（保留期错误单独成类）。

    用 variables 而不是字符串拼接：日期/zone 都来自环境，拼接一旦被污染就是注入。
    """
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(
        GRAPHQL, data=body, method="POST",
        headers={
            "Authorization": f"Bearer {API_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        payload = json.load(resp)

    errs = payload.get("errors")
    if errs:
        msg = str(errs[0].get("message", errs[0]))
        # CF 原文：'cannot request data older than 1w1d, but your query requests ...'
        if "older than" in msg:
            raise RetentionExceeded(msg[:200])
        raise RuntimeError(msg[:200])
    return payload["data"]


def utc_date(offset_days: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(time.time() - offset_days * 86400))


Q_UNIQUES = """
query ($zone: String!, $start: Date!, $end: Date!) {
  viewer {
    zones(filter: {zoneTag: $zone}) {
      httpRequests1dGroups(
        limit: 60,
        filter: {date_geq: $start, date_leq: $end},
        orderBy: [date_ASC]
      ) {
        dimensions { date }
        sum { requests }
        uniq { uniques }
      }
    }
  }
}
"""

# 按 (clientIP, host, verifiedBotCategory, userAgent) 分组：请求数求和，独立 IP 去重计数，
# 来源分类在本地算（见 classify）。
# ⚠️ 没有 `uniq { uniques }` 可用 —— adaptive 数据集不支持该字段（实测报
#    'unknown field "uniq"'），所以独立 IP 只能靠客户端去重。
# ⚠️ **userAgent 只在本进程内用于归桶，绝不进 label** —— 它的基数是几百上千。
# 加这两个维度是**零额外 API 调用**的：同一条查询多两个字段而已。行数实测
# 1767→3553（两维时 2471），上限 10000，余量 65%；超限由 rows_truncated 报出来。
# ❌ 判断「这个 IP 属于数据中心还是住宅宽带」要 clientAsn/clientASNDescription，
#    免费版直接 403（Bot Management 的 botScore 同理）—— 所以没有真正的「服务器 IP」判定，
#    只有下面这套基于 UA + CF 验证爬虫名单的近似。
Q_HOST_DAY = """
query ($zone: String!, $day: Date!, $limit: Int!) {
  viewer {
    zones(filter: {zoneTag: $zone}) {
      httpRequestsAdaptiveGroups(
        limit: $limit,
        filter: {date_geq: $day, date_leq: $day},
        orderBy: [count_DESC]
      ) {
        dimensions { clientIP clientRequestHTTPHost verifiedBotCategory userAgent }
        count
      }
    }
  }
}
"""


def _zone_rows(data: dict, field: str) -> list:
    zones = data["viewer"]["zones"]
    if not zones or not zones[0]:
        return []
    return zones[0].get(field) or []


def fetch_uniques() -> dict:
    """全站每日 uniques，一次查完整段（该数据集支持多日范围）。"""
    rows = _zone_rows(
        gql(Q_UNIQUES, {"zone": ZONE_ID, "start": utc_date(UNIQ_WINDOW_DAYS), "end": utc_date(1)}),
        "httpRequests1dGroups",
    )
    return {r["dimensions"]["date"]: r["uniq"].get("uniques", 0) for r in rows}


def fetch_host_day(day: str) -> dict:
    """某一完整 UTC 日的聚合结果，按 host（外加 __total__ 汇总）。

    ☠️ 每个「独立 IP 数」都是**从各自的集合单独 len() 出来的**，不是把别的数字加起来。
       同一个 IP 会同时落进多个 class（浏览器请求 + curl 请求），也会访问多个子域，
       所以 sum() 一定算错。这是本函数唯一需要小心的地方。
    """
    rows = _zone_rows(
        gql(Q_HOST_DAY, {"zone": ZONE_ID, "day": day, "limit": ROW_LIMIT}),
        "httpRequestsAdaptiveGroups",
    )

    requests, req_by_class, bot_requests = {}, {}, {}
    ips, ips_human, ips_by_class = {}, {}, {}

    for r in rows:
        d = r["dimensions"]
        host = d["clientRequestHTTPHost"]
        ip = d["clientIP"]
        bot = d["verifiedBotCategory"]
        cls = classify(bot, d["userAgent"])
        n = r.get("count", 0)

        for h in (host, TOTAL):
            requests[h] = requests.get(h, 0) + n
            req_by_class[(h, cls)] = req_by_class.get((h, cls), 0) + n
            ips.setdefault(h, set()).add(ip)
            ips_by_class.setdefault((h, cls), set()).add(ip)
            if cls in HUMANISH_CLASSES:
                ips_human.setdefault(h, set()).add(ip)
        if bot:
            bot_requests[bot] = bot_requests.get(bot, 0) + n

    # ☠️ 给**每个有流量的 host** 都补一个 client_ips_human 条目（可能是 0）。
    # 不补的话，「昨天完全没有真人访问」的域名（实测 argocd/vault/auth 就是）
    # 根本不产生序列，而 PromQL 里 `== 0` 匹配的是**存在且为 0** 的序列 ——
    # 缺失序列匹配不上，"没人访问"就永远查不出来，和"一切正常"长得一模一样。
    # 同类坑在本仓库反复出现（缺失序列 ≠ 零值），别把这行删了当冗余。
    # by_class 不做这个补齐：那里「某 class 没出现」本来就该是没有序列。
    for h in requests:
        ips_human.setdefault(h, set())

    return {
        "requests": requests,
        "requests_by_class": req_by_class,
        "client_ips": {h: len(s) for h, s in ips.items()},
        "client_ips_human": {h: len(s) for h, s in ips_human.items()},
        "client_ips_by_class": {k: len(s) for k, s in ips_by_class.items()},
        "bot_requests": bot_requests,
        "truncated": len(rows) >= ROW_LIMIT,
    }


def refresh() -> None:
    data = {
        "uniques": {},               # date -> uniques
        "requests": {},              # (date, host) -> count
        "client_ips": {},            # (date, host) -> distinct ip count
        "client_ips_human": {},      # (date, host) -> 只数「发过疑似真人请求」的 IP
        "requests_by_class": {},     # (date, host, class) -> count
        "client_ips_by_class": {},   # (date, host, class) -> distinct ip count
        "bot_requests": {},          # (date, category) -> count
        "host_window_days": 0,
        "host_days_failed": 0,
        "truncated": 0,
        "errors": [],
    }
    ok = True

    try:
        data["uniques"] = fetch_uniques()
    except Exception as exc:  # noqa: BLE001
        ok = False
        data["errors"].append(f"uniques: {exc}")

    # 逐日往回走；撞到保留期就停（窗口到头，不算失败）。
    for offset in range(1, HOST_WINDOW_DAYS + 1):
        day = utc_date(offset)
        try:
            got = fetch_host_day(day)
        except RetentionExceeded:
            break
        except Exception as exc:  # noqa: BLE001
            ok = False
            data["host_days_failed"] += 1
            data["errors"].append(f"{day}: {exc}")
            continue

        data["host_window_days"] += 1
        data["truncated"] |= int(got["truncated"])
        for key in ("requests", "client_ips", "client_ips_human"):
            for host, val in got[key].items():
                data[key][(day, host)] = val
        for key in ("requests_by_class", "client_ips_by_class"):
            for (host, cls), val in got[key].items():
                data[key][(day, host, cls)] = val
        for category, cnt in got["bot_requests"].items():
            data["bot_requests"][(day, category)] = cnt

    with _lock:
        prev_ts = _cache.get("last_success_ts", 0)
        _cache.clear()
        _cache.update(data)
        _cache["scrape_success"] = 1 if ok else 0
        # 失败时保留上一次成功的时间戳，否则「数据有多旧」这个信号会被自己抹掉。
        _cache["last_success_ts"] = time.time() if ok else prev_ts

    if data["errors"]:
        print("refresh errors: " + " | ".join(data["errors"][:5]), flush=True)


def _esc(v: str) -> str:
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def render_metrics() -> bytes:
    with _lock:
        c = dict(_cache)

    lines = []

    def gauge(name, help_text, samples):
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} gauge")
        lines.extend(samples)

    gauge(
        "cf_analytics_daily_uniques",
        "Site-wide unique visitors for a complete UTC day (Cloudflare uniq.uniques).",
        [f'cf_analytics_daily_uniques{{date="{d}"}} {v}'
         for d, v in sorted(c.get("uniques", {}).items())],
    )
    gauge(
        "cf_analytics_daily_requests",
        'Requests per hostname for a complete UTC day (host="__total__" is the whole zone).',
        [f'cf_analytics_daily_requests{{host="{_esc(h)}",date="{d}"}} {v}'
         for (d, h), v in sorted(c.get("requests", {}).items())],
    )
    gauge(
        "cf_analytics_daily_client_ips",
        'Distinct client IPs per hostname for a complete UTC day (host="__total__" dedupes across hostnames).',
        [f'cf_analytics_daily_client_ips{{host="{_esc(h)}",date="{d}"}} {v}'
         for (d, h), v in sorted(c.get("client_ips", {}).items())],
    )
    gauge(
        "cf_analytics_daily_client_ips_human",
        "Distinct client IPs that made at least one browser/tool/unknown request "
        "(i.e. not attributable to self-monitoring, verified/unverified bots, or CF Early Hints). "
        "Best-effort: a bot disguising itself as a browser still lands here.",
        [f'cf_analytics_daily_client_ips_human{{host="{_esc(h)}",date="{d}"}} {v}'
         for (d, h), v in sorted(c.get("client_ips_human", {}).items())],
    )
    gauge(
        "cf_analytics_daily_requests_by_class",
        "Requests per hostname split by traffic source class (these ARE additive).",
        [f'cf_analytics_daily_requests_by_class{{host="{_esc(h)}",date="{d}",class="{cl}"}} {v}'
         for (d, h, cl), v in sorted(c.get("requests_by_class", {}).items())],
    )
    gauge(
        "cf_analytics_daily_client_ips_by_class",
        "Distinct client IPs per hostname per source class. NOT additive: one IP can fall in several classes.",
        [f'cf_analytics_daily_client_ips_by_class{{host="{_esc(h)}",date="{d}",class="{cl}"}} {v}'
         for (d, h, cl), v in sorted(c.get("client_ips_by_class", {}).items())],
    )
    gauge(
        "cf_analytics_daily_bot_requests",
        "Zone-wide requests from Cloudflare-verified bots, by Cloudflare's bot category.",
        [f'cf_analytics_daily_bot_requests{{category="{_esc(cat)}",date="{d}"}} {v}'
         for (d, cat), v in sorted(c.get("bot_requests", {}).items())],
    )
    gauge(
        "cf_analytics_host_window_days",
        "Complete days for which per-hostname data was retrieved (bounded by the plan's retention).",
        [f'cf_analytics_host_window_days {c.get("host_window_days", 0)}'],
    )
    gauge(
        "cf_analytics_host_days_failed",
        "Day queries that errored for a non-retention reason in the last refresh.",
        [f'cf_analytics_host_days_failed {c.get("host_days_failed", 0)}'],
    )
    gauge(
        "cf_analytics_rows_truncated",
        "1 if some day hit the API row limit, so distinct-IP counts are undercounted.",
        [f'cf_analytics_rows_truncated {c.get("truncated", 0)}'],
    )
    gauge(
        "cf_analytics_scrape_success",
        "1 if the last Cloudflare refresh completed with no errors.",
        [f'cf_analytics_scrape_success {c.get("scrape_success", 0)}'],
    )
    gauge(
        "cf_analytics_last_success_timestamp_seconds",
        "Unix time of the last fully successful Cloudflare refresh.",
        [f'cf_analytics_last_success_timestamp_seconds {c.get("last_success_ts", 0)}'],
    )

    return ("\n".join(lines) + "\n").encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/metrics":
            self._send(200, render_metrics(), "text/plain; version=0.0.4")
        elif self.path == "/healthz":
            # ⚠️ 进程存活探针，**刻意不看数据新鲜度**。若这里因 CF 抓取失败而 503，
            # liveness 会重启 pod、readiness 会把它踢出 Endpoints —— 后者更坏：
            # Prometheus 连 cf_analytics_scrape_success=0 都抓不到，故障变成"没数据"，
            # 告警链路自己把自己关掉了。数据健康度只走指标 + 告警规则。
            self._send(200, b"ok\n", "text/plain")
        else:
            self._send(404, b"", "text/plain")

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # noqa: N802
        pass


def background_loop():
    while True:
        try:
            refresh()
        except Exception as exc:  # noqa: BLE001
            print(f"refresh crashed: {exc}", flush=True)
        time.sleep(REFRESH_SECONDS)


if __name__ == "__main__":
    # 先起 HTTP server，再做首刷：首刷要打 8+ 次 CF API，几十秒起步；
    # 先监听可以让 readinessProbe 立刻通过，避免 pod 在首刷期间被判失败。
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print(f"cf-analytics-exporter listening on :{PORT}", flush=True)
    background_loop()
