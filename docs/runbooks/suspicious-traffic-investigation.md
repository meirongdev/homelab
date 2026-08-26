# 可疑公网流量下钻调查 (Suspicious Traffic Investigation)

> 触发条件：cf-analytics 面板上出现认不出来的流量 —— 某域名请求数突刺、`tool` / `unknown`
> class 占比异常、或者单纯想知道「这个 IP / 这个 UA 是不是我自己的机器」。
> 目标：从聚合数字下钻到「**哪个 IP、打了哪些 path、拿到什么状态码**」，据此决定处置。
> **成功判定**：能回答三个问题 —— ①是不是我自己的 ②有没有真读到东西 ③要不要拦。
> **回滚**：§1–§3 是纯查询，无需回滚；§4 若改了 WAF，回滚 = revert 那次提交后重新
> `just apply`（⚠️ apply 前必看 plan，见 §4 的告警框）。
> Last updated: 2026-08-26
>
> 口径、来源分类法、免费版能力边界、指标清单是
> [reference/public-traffic-analysis.md](../reference/public-traffic-analysis.md) 的地盘，
> 本文不复制，只在需要时链过去。本文由 2026-08-14 的一次扫描反推而成（实例见 §5）。

## 0. 前置

面板给的是聚合数（谁多、真人还是爬虫），**下钻只能直接查 Cloudflare GraphQL** ——
exporter 刻意不导出客户端 IP（PII + 基数爆炸，见 reference 的「隐私与安全约束」）。

```bash
# 任意目录。token 从集群取、不落盘（复用 cf-analytics 那份，Zone Analytics Read 足够）
TOKEN=$(kubectl --context k3s-homelab get secret cf-analytics-cloudflare -n monitoring \
  -o jsonpath='{.data.api-token}' | base64 -d)
ZONE=9469bfb589d48156a8a5690e7e3d9d80
DAY=2026-08-14          # ⚠️ 只能查完整 UTC 日，且不能早于 8 天前
```

⚠️ **两条硬限制会让你误判「没发生过」**：`httpRequestsAdaptiveGroups` 单次跨度 ≤ 1 天，
保留期只有 **1w1d（约 8 天）**。超期返回的是错误不是空结果，别把它读成「那天很干净」。
完整的能力边界（哪些维度免费版拿不到）见
[reference/public-traffic-analysis.md](../reference/public-traffic-analysis.md) 的「免费版的能力边界」。

## 1. 按 UA 反查是哪些 IP

典型入口：面板显示 `tool` class 突然涨了，想知道是谁在发 curl。

```bash
q='query($zone:String!,$day:Date!,$ua:String!){viewer{zones(filter:{zoneTag:$zone}){
  httpRequestsAdaptiveGroups(limit:100,filter:{date_geq:$day,date_leq:$day,userAgent:$ua},
  orderBy:[count_DESC]){dimensions{clientIP clientRequestHTTPHost}count}}}}'

jq -n --arg q "$q" --arg zone "$ZONE" --arg day "$DAY" --arg ua "curl/8.7.1" \
  '{query:$q,variables:{zone:$zone,day:$day,ua:$ua}}' |
curl -s -X POST https://api.cloudflare.com/client/v4/graphql \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data @- |
jq -r '.data.viewer.zones[0].httpRequestsAdaptiveGroups
       | group_by(.dimensions.clientIP)
       | map({ip: .[0].dimensions.clientIP, n: (map(.count)|add)})
       | sort_by(-.n)[] | "\(.n)\t\(.ip)"'
```

输出形如（IP 已打码，仓库禁止落公网 IP）：

```
811     <外部 IP —— 后来查明是扫描器>
7       <我自己的出口 IP>
```

> `userAgent` 是**精确匹配**，不是子串。想按类别捞（所有 curl / 所有 python-requests）
> 就去掉这个 filter，改成按 `userAgent` 分组统计 —— reference 的「维护约定」里有现成的
> top-UA 查询。

## 2. 展开这个 IP：打了什么、拿到了什么

```bash
IP=<上一步的 IP>
q='query($zone:String!,$day:Date!,$ip:String!){viewer{zones(filter:{zoneTag:$zone}){
  httpRequestsAdaptiveGroups(limit:500,filter:{date_geq:$day,date_leq:$day,clientIP:$ip},
  orderBy:[count_DESC]){dimensions{clientRequestHTTPHost clientRequestPath
  edgeResponseStatus userAgent clientCountryName}count}}}}'

jq -n --arg q "$q" --arg zone "$ZONE" --arg day "$DAY" --arg ip "$IP" \
  '{query:$q,variables:{zone:$zone,day:$day,ip:$ip}}' |
curl -s -X POST https://api.cloudflare.com/client/v4/graphql \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data @- > /tmp/ipq.json

# ① 状态码分布 —— 结论主要看这个
jq -r '.data.viewer.zones[0].httpRequestsAdaptiveGroups
       | group_by(.dimensions.edgeResponseStatus)
       | map({s: .[0].dimensions.edgeResponseStatus, n: (map(.count)|add)})
       | sort_by(-.n)[] | "\(.n)\t\(.s)"' /tmp/ipq.json

# ② 打了哪些 path（含状态码）
jq -r '.data.viewer.zones[0].httpRequestsAdaptiveGroups[:20][]
       | "\(.count)\t\(.dimensions.edgeResponseStatus)\t\(.dimensions.clientRequestHTTPHost)\(.dimensions.clientRequestPath)"' /tmp/ipq.json

# ③ 归属（免费版 clientAsn 是 403，只能靠 whois）
whois "$IP" | grep -iE '^(netname|descr|country|org-name|origin)'
```

把 `dimensions` 换成 `datetimeHour` 还能看时间分布 —— 集中在一小时内 = 一次性扫描，
均匀铺满全天 = 常驻客户端（多半是自己的定时任务）。

## 3. 判读：四条经验

**① 结论看状态码分布，不看请求数。** 只有 **200** 值得紧张。几百个 404 是噪音 ——
那说明扫的东西根本不存在。逐条确认 200 命中的是哪些 path：是真实页面还是敏感文件。

**② `403` 表示 WAF 已经拦下了。** 具体命中哪条规则要去 Cloudflare 面板的 Security Events；
仓库侧的 4 条自定义规则见 [reference/security.md](../reference/security.md) 的「边缘」一节。
⚠️ 归因时**别再往「威胁分」上想**：那条规则 2026-08-26 已删（`cf.threat_score` 恒为 0、
从未命中）。现在能产生 403 的只有四条确定性规则（路径 / 敏感文件 / 漏扫 UA / 非标方法）
和 zone 级 Browser Integrity Check。

**③ UA 里带 `early hints` 的不是访客**（实测见过 `nginx-ssl early hints`、`bastion early hints`）——
那是 Cloudflare 边缘的 Early Hints 预取。它携带**真实访客的 IP**，所以既不能算成爬虫、
也不能当成独立访客；它还会替访客去打源站，2026-08-14 那次 162 个 504 全落在它头上。

**④ ☠️ 同一个 UA 可能既是我又是别人。** `curl/8.7.1` 是 macOS 自带版本 —— 同一天里
它既是扫描器的 811 次请求，也是我自己 Mac 的十来次点检。**所以永远不要因为「这看着像我」
就把某个 UA 加进 `SELF_MONITOR_AGENTS`**：那个白名单一旦放宽，扫描器就会被算成自建监控，
指标从此说谎且不会报错。这也正是分类法里 `tool` 不并入 `self_monitor` 的原因。

> 归属判断没有权威手段：免费版拿不到 `clientAsn`/`botScore`，只能 whois 看 netname ——
> 托管商 / 云厂商是扫描器的强信号，住宅 ISP 则大概率是真人。

## 4. 处置：三选一

### A. 确认是自己的机器 → 加白名单

改 `SELF_MONITOR_AGENTS`（`exporter.py`），照
[reference/public-traffic-analysis.md](../reference/public-traffic-analysis.md) 的「维护约定」走，
改完必须在 `k8s/helm/` 跑 `just gen-embedded-scripts`，否则跑的还是 ConfigMap 里的旧副本（CI 的 E1 会拦）。
⚠️ 前提是这个组件有**自己专属的 UA**；UA 是通用的（裸 curl / python-requests）就别加，见 §3④。

### B. 确认是扫描器且路径值得拦 → 并进 WAF 第 2 条

编辑 `cloudflare/terraform/waf.tf` 里 “Block sensitive file and directory access” 那条的表达式：

```bash
cd cloudflare/terraform
just plan     # ⚠️ 先看 plan，见下方告警框
just apply
```

- 免费版自定义规则上限 5 条，**当前 4/5、还剩 1 个槽位**（2026-08-26 删掉死的威胁分规则后腾出来的）。
  新路径**默认仍并进第 2 条** —— 同类判据放一处便于整体验收，而不是因为没槽位了。
  真要单独成条（比如需要不同 action、或想在 Security Events 里单独看命中数）是可以的，
  但**用掉就没有了**，且 Free 档没有别的来源能再腾一个。
- ⚠️ 新 term 一律套 `lower()`：Rules 语言的 `contains` **区分大小写**，实测扫描器会发
  `/serviceAccount.json` 这种混合大小写。
- ⚠️ 有几类**加了会误伤自己**，理由写在 `waf.tf` 行内注释里：`/version`、`/apis/`、`/swagger`
  （ArgoCD UI 自己就调 `/api/version` 和 swagger 文档）、`/actuator`、`.zip`/`.sql`
  （`book.meirong.dev` 要下载书）、裸 `..`（书名里出现连续点并非不可能）。

> ☠️ **`just apply` 前必须看 plan 的 destroy 计数。** `cloudflare/terraform` 与 external-dns
> 共管同一个 zone，state 会漂：2026-08-15 就发现 state 里还留着 5 条早已交给 external-dns 的
> 记录（argocd/book/grafana/llm/vault）+ 1 条线上存在却没 import 的 `playgrounds`，
> 裸 apply 会**删掉活的 DNS 记录**。当时已用 `terraform state rm` × 5 + `terraform import`
> 清干净，正常情况下 plan 应该只剩你自己那一处 change。再出现 destroy 就停下来查，别 apply。

**验收**（只有改了 WAF 才需要）：

```bash
# 应当 403
for u in /app/terraform.tfstate /serviceAccount.json /etc/passwd; do
  printf '%-32s ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' "https://meirong.dev$u"; done
# 应当保持 200/302 —— 误伤检查，挑几个真实端点
for u in https://meirong.dev/ https://argocd.meirong.dev/api/version https://book.meirong.dev/; do
  printf '%-45s ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' "$u"; done
```

⚠️ apply 后头几秒边缘还没传播完，**第一条请求可能仍是旧结果** —— 拿到非预期值先重测一次再排查。

> ⚠️ **验「非标方法」那条规则别用 `TRACE`/`CONNECT`**：Cloudflare 边缘自己就先回
> `405`/`400`，根本走不到自定义规则，看着像规则没生效（2026-08-26 实测）。
> 用 `curl -X PROPFIND https://meirong.dev/` —— 命中规则才是 **403**。

### C. 什么都不做

全 404 的扫描**不需要任何动作**。加 WAF 规则只是降噪（让 404 曲线只反映真实错误），
不是在堵一个真实泄漏 —— 别把它记成安全修复。

## 5. 实例：2026-08-14 的那次扫描

| 项 | 实测 |
|---|---|
| 来源 | 法国某托管商（AS211590），保留期内其余 6 天为零 |
| 时间 | 单个小时内 991 次，打完就走 |
| 目标 | 全部打 apex `meirong.dev`（该域由 Cloudflare Pages 提供，不经隧道、不碰集群） |
| 手法 | `terraform.tfstate` / `~/.aws/credentials` / `serviceAccount.json` / `s3.properties` / `settings/development.py` / `/etc/passwd` 目录穿越 / `web.config` |
| 结果 | 642×404、147×200（**只有三个真实博客页**）、18×403（WAF 拦）、9×405、162×504（全落在 Early Hints 预取上） |
| 处置 | 12 个 term 并进 WAF 第 2 条（commit `1776f06`），验收 12 条拦截路径 403、12 个真实端点无误伤 |
| 结论 | **纯降噪**。路径规则一条都没命中过这次扫描；敏感内容一个都不存在 |

> ⚠️ **本表 2026-08-26 更正**：原文把那 18 个 403 记成「威胁分规则拦下的」，**不可能** ——
> `cf.threat_score` 恒为 0，那条规则一次都没命中过（已删，见
> [reference/security.md](../reference/security.md) 的「边缘」一节）。这 18 个只能来自
> 漏扫 UA 规则或 zone 级 Browser Integrity Check；Free 档 Security Events 保留期已过，
> 无法回溯到底是哪一条。**教训**：403 的归因必须当场去 Security Events 看，
> 事后按「哪条规则听起来像」倒推会写出假因果。
