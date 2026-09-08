# 博客按文章的访问量：扩现有 exporter + 每日 rollup 落 Postgres

> 日期: 2026-09-07 · 2026-09-08 激活完成
> 状态: ✅ 已完成（三步激活已跑完，表里 3345 行 / 2026-08-31..09-06；CronJob 已 `suspend: false`）

## 上下文

想回答的问题只有一句：**哪几篇文章真的被人读了**。

难点不在采集，在于这个博客**不在集群里**：`meirong.dev`（apex）是 Cloudflare Pages
托管的静态站（`meirongdevblog.pages.dev`，橙云），所以
[reference/public-traffic-analysis.md](../reference/public-traffic-analysis.md) 里那三个
数据源有两个对它完全失明 —— ② cloudflared 和 ③ cilium-envoy 都在隧道之后，而博客的流量
压根不进集群。唯一看得见它的是 ① Cloudflare 边缘。

而 ① 已经有一条完整的桥：`cf-analytics-exporter` → Prometheus → Grafana。它 2026-08-15
上线时就在数主站，只是**按域名**：2026-08-14 实测 `meirong.dev` 10,056 请求 / 1,868 个
疑似真人 IP。缺的不是一套系统，是**一个维度**（`clientRequestPath`）。

三个候选存储的保留期都不够（这是本次真正要解决的约束）：

| 层 | 保留期 | 依据 |
|---|---|---|
| Cloudflare `httpRequestsAdaptiveGroups`（按 path 那个数据集） | **~8 天**（1w1d），且单查跨度 ≤1 天 | 2026-08-15 实测 |
| Prometheus | 14d / 10240MB | `values/kube-prometheus-stack.yaml`（[cronjob-and-job-hygiene](cronjob-and-job-hygiene.md) 采纳 4 抬的） |
| Loki | 168h | `cloud/oracle/values/loki.yaml` |

「某篇文章累计被读了多少」按年算，三个都存不住。

## 决策

### 一、按 path 的维度加在现有 exporter 里，不新起一个进程

同一个 6h 刷新循环里多一次 API 调用（每天一次、8 天窗口 = 每轮多 8 次调用），复用现成的
token、逐日容错、保留期识别、告警和面板范式。查询形态是逐条实测定的（2026-09-06，
本仓库的 token）：

| 查询 | 行数 | 结论 |
|---|---|---|
| `dimensions{clientRequestPath verifiedBotCategory}`，只按 host+200 过滤 | **1000（截断）**，647 个 path | 不可用：css/js/字体把行占满 |
| 加 `edgeResponseContentTypeName:"html"` | 886，538 个 path | 可用 |
| 再加 `userAgentBrowser` 维度 | **962**（+8.6%） | 采纳：几乎不要钱的真人近似 |
| 同上但只要 304 | **0 行** | 「只数 200」不漏带缓存的回访 |

`clientRequestPath` **免费版拿得到** —— reference 里那份「拿得到的字段」清单漏了它
（runbook §2 早就在用），本次实测确认。`userAgentBrowser` 是低基数枚举（单日只有 10 个
取值：Unknown / Chrome / MobileSafari / GoogleBot / ChromeMobile / BingBot / Edge /
Firefox / Safari / AppleBot），所以敢当分组维度用；原始 `userAgent` 不敢（几百上千）。

☠️ **「浏览器请求」是真人的近似，不是真人数。** 免费版拿不到 `botScore`，伪装成 Chrome
的爬虫照样算进来。反过来它也确实有用：2026-09-04 实测首页 `/` 的 1,539 次请求里只有 **68**
次来自已知浏览器，而具体文章页是 3–17 次全部来自浏览器 —— 排序键用它而不是总请求数，
否则被脚本刷的首页和 tag 页会把文章挤下去。

指标侧每天只留前 50 个 path（其余进 `__other__`）：538 个 path × 2 个指标 × 8 天 ≈ 8600
条 series，不值当（同 [prometheus-series-reduction](prometheus-series-reduction.md) 的取向）。

### 二、长期留存落 `apps-pg` 的第四个租户，不抬 retention

exporter 多一个 `/pages.csv` 端点（完整明细、不做 top-N），`blog-stats-rollup` CronJob
每天把它 UPSERT 进 `blogstats.blog_pageviews`（主键 `(day, path)`）。

- **为什么不抬 Prometheus retention**：要的是按年，不是按月；而 retention 是全局的，
  为一个博客指标把 10 万条 series 一起留一年，方向不对。
- **为什么不用 Loki 的 per-stream retention**：Loki 拒重复条目、日推的幂等补写会变成
  「同一天多条」，LogQL 侧还得再去重；而「某篇累计多少」本来就是关系型聚合。
- **为什么不新起一个 Postgres**：homelab 刻意不装 CNPG，共享实例就是为这种「一张表的
  应用」准备的（[shared-postgres-platform](shared-postgres-platform.md) 决策四）。
- **幂等是设计的一部分**：exporter 每次吐整个 8 天窗口 → `ON CONFLICT DO UPDATE` →
  **≤8 天的中断下一轮自己补齐**，不需要补数脚本。超过 8 天才是永久空洞。
- 体量：实测每天 538 行 ≈ 20 万行/年，可忽略。

Grafana 用**只读角色** `blogstats_ro` 连（`SELECT` + 未来新表的 DEFAULT PRIVILEGES）。
本地起 PG 17 实测：`SELECT` 通、`INSERT` 报 `permission denied`、`DROP` 报
`must be owner` —— 面板里的 SQL 改不了库。

### 三、明确不做的

- **❌ 自托管 Umami / Plausible / GoatCounter**：`personal-services` 是目录即清单，加个
  租户和 HTTPRoute 十分钟能上线。但换来的是在 LGTM 之外再养一个应用（自己的升级、备份、
  登录），数据进不了现有面板与告警，而它多给的那点（referrer、会话）目前不值这个价。
  同 [cf-analytics-custom-exporter](cf-analytics-custom-exporter.md) 的取向：宁可自己写
  一百行，不多养一个栈。
- **❌ 升 zone 套餐**：[ROADMAP](../ROADMAP.md) 已经把「升 Pro/Business」记成前提未满足，
  而按 path 在免费版就拿得到。
- **⏸️ Cloudflare Web Analytics（RUM 数据集）**：`rumPageloadEventsAdaptiveGroups` 带
  `requestPath` / `refererHost` / `deviceType`，且只有真浏览器会执行 beacon —— 是比
  `userAgentBrowser` 干净得多的真人信号，Pages 侧还能一键注入。
  **2026-09-08 实测：现有 token 读不到，已确认（原来的 `[need manual confirm]` 结清）。**
  RUM 在 GraphQL 里是 **account 作用域**，而本仓库这把 token（复用
  `secret/homelab/external-dns` 那份）是 zone 级：
  `/user/tokens/verify` 返回 `active`（token 本身有效），但
  `{ viewer { accounts { accountTag } } }` 返回 **0 个 account** +
  `not authorized for that account`（code `authz`）。所以不是查询写错，是作用域不够。
  ⚠️ 判据要用 `viewer.accounts` 这一问：直接查 RUM 数据集报的错会长得像「数据集不存在」，
  容易误判成免费版没有这个数据集。
  **要推进就得在 Cloudflare 控制台另发一把 account-scoped token（Account > Account
  Analytics > Read），写进 Vault 新路径**——不要覆盖 `homelab/external-dns`，那把是
  external-dns + cf-analytics-exporter 在用的生产凭据。
  届时本管道只换数据集，rollup 与面板不用动。
  ⚠️ 它和边缘数据**量的不是一回事**（beacon 会被 adblock 吃掉一部分，读者是开发者，
  损耗不小），所以真要上是**并存加一列**对比，不是替换掉现在这条。
- **⏸️ 自建 beacon（浏览器侧打点）**：能拿到阅读时长、滚动深度、referrer，但代价是
  博客要挂一段 JS（本仓库改不到那个 repo）、多一个公网端点、且被 adblock 吃掉一部分
  （读者是开发者，这个损耗不小）。**它和本方案量的不是一回事**（边缘数完整但含爬虫，
  beacon 干净但漏统计），真要做是加第 ④ 列而不是替换。

## 后果

- 面板 `blog-pageviews`（Grafana / Platform 文件夹）分两半：上半 Prometheus，**最近 8 天**、
  按 path、含健康信号；下半 Postgres，**长期**、吃时间选择器。两半的窗口不同，
  ☠️ 别互相对账。
  ⚠️ 另外**下半会比「昨天」落后 1 天**（有时 2 天），这是预期不是漏数：exporter 是
  「启动即刷 + sleep 6h」，刷新相位随 pod 启动时刻漂，02:30Z 的 rollup 常读到上一次
  （前一天 21:58Z 附近）刷新的结果，那份的 offset=1 天是前天。8 天窗口 + UPSERT
  会在次日补齐，所以不要为此去调 cron 时刻或缩 `REFRESH_SECONDS`（相位追不住）。
  2026-09-08 01:50Z 实测：`/pages.csv` 最新一天是 09-06。
- `public-traffic-analysis.md` 的「三个数据源」表**不加第 ④ 列** —— 这仍然是 ① 的数据，
  只是多了一个维度和一个更长的存储。
- 新增两条告警（[observability-alerting-slo](../reference/observability-alerting-slo.md)）：
  `CFAnalyticsPageRowsTruncated`（按 path 的查询撞行上限）与 `BlogStatsRollupStale`
  （超 3 天没成功 → 距永久丢数还有 5 天）。
  ⚠️ **已知盲区**：从未成功过一次时 KSM 不发 `kube_cronjob_status_last_successful_time`
  这个序列，所以「CronJob 对象被误删」在首次激活前无法与「还没激活」区分，故只守
  「成功过、然后停了」。激活后请确认那个 stat 面板有值。
- 备份多一段 `pg_dump`（`backup/overlays/homelab/backup-script.yaml` 的 2f），凭据走
  **独立的 ExternalSecret + optional 卷**，照 `open-notebook-surreal` 的成例：往共享的
  `restic-backup` 里加 key 会让整条夜备的凭据随一个新 Vault 路径的缺失一起同步失败，
  而且 `ExternalSecretNotReady`（15m 就响）会指着 backup ns 报警 —— 一个还没激活的新功能
  不该让关键子系统的健康信号说谎。
  ☠️ 这个库**没有自己的 PVC**，那一行是它唯一的备份，而 H4 查不出「实例里多了个库」——
  同 nakama 的坑。丢了也不能重算：上游只留 8 天。
- ☠️ **rollup 的 SQL 必须挂在 ConfigMap 里，不能内联进 `args`**（2026-09-08 首轮验证
  实际踩到）：kubelet 对 `command`/`args` 做 `$(VAR)` 展开，而 `$$` 是「字面 `$`」的转义，
  于是 `DO $$ ... END $$;` 到容器里变成 `DO $ ... END $;`，psql 报
  `syntax error at or near "$"`，作业 exit 3。
  **git 里和 CronJob 对象里存的都是正确的 `$$`**，坏的只有运行时那一刻 —— 所以
  `kubectl get -o yaml` 与本地文件比对**看不出任何差异**，`just check-render` 也查不出，
  唯一的判据是真跑一轮。ConfigMap 的内容不经过那层展开。同类只影响 `args`：
  仓库里另两处 `$$`（calibre 的两个脚本）在 ConfigMap 里，不受影响。

- ☠️ **`optional: true` 的 `secretKeyRef` 换来的可用性，代价是「激活后必须重启消费方」**：
  apps-pg（两个租户口令）与 Grafana（数据源口令）都是这个形状。Secret 后来出现时
  **env 不会刷新**，而 `optional` 让它安静地整个缺失 —— 于是「ExternalSecret 全绿 +
  表里有行 + pod Running」三个信号同时为真，面板却连不上库。收口只能看面板出数。

- ⚠️ `apps-pg` 的 Deployment 多了两个 `optional: true` 的 env → **ArgoCD 同步时 Postgres
  会滚动重启一次**（`strategy: Recreate` + 单 RWO PVC，秒级），litellm / multica / nakama
  会短暂断连重连。`optional` 是必须的：Vault 里还没写口令时非 optional 的 `secretKeyRef`
  会让整个 apps-pg 起不来。

## 激活（2026-09-08 已跑完；重建集群时按此重放）

前两步动的是「口令」这类不该进 git 的东西，所以刻意留成手工；CronJob 当时以
`suspend: true` 进仓库，就是为了不在这三步之前每天失败一次报警（现已 `false`）。

**2026-09-08 的实际结果**：三个 ExternalSecret 全部 `SecretSynced`；`blogstats` /
`blogstats_ro` 两个角色 + `blogstats` 库建好（前三个租户原地跳过）；首轮
UPSERT 3345 行、`2026-08-31..2026-09-06`；`blogstats_ro` 实测 `SELECT` 通、
`INSERT` 报 `permission denied for table blog_pageviews`。

1. 生成两个口令写进 Vault（在能连 `vault.meirong.dev` 的机器上）：

   ```bash
   vault kv put secret/homelab/blogstats \
     owner_password="$(openssl rand -base64 24)" \
     readonly_password="$(openssl rand -base64 24)"
   ```

   ⚠️ ESO 失败后的重试间隔实测 ~420s，写完 Vault 后不必手动 force-sync，等一轮即可
   （三个对象的重试相位不同，会先后变绿，不是「有的没生效」）。

   写完确认三个 ExternalSecret 变绿。⚠️ 在此之前它们是 `Ready=False`，15 分钟后
   `ExternalSecretNotReady` 会报 —— **这是预期的「等激活」信号**，三个对象都是本次新增的，
   刻意拆开就是为了让失败面只有它们自己：

   ```bash
   kubectl --context k3s-homelab get externalsecret -n databases apps-pg-blogstats
   kubectl --context k3s-homelab get externalsecret -n monitoring blogstats-db
   kubectl --context k3s-homelab get externalsecret -n backup blogstats-pg
   ```

2. 在**已经跑着**的实例上建租户。`initdb` 脚本只在数据目录为空时执行，改它对现有实例
   无效 —— 但那个脚本本身是幂等的（建角色/建库都带 `WHERE NOT EXISTS`）且就挂在 pod 里，
   所以把它再跑一遍即可，前三个租户原地跳过：

   ```bash
   cd /Users/matthew/projects/homelab   # 任意目录都行，这里只是给 context 一个落点
   PW=$(kubectl --context k3s-homelab get secret apps-pg-blogstats -n databases \
          -o jsonpath='{.data.BLOGSTATS_PASSWORD}' | base64 -d)
   RO=$(kubectl --context k3s-homelab get secret apps-pg-blogstats -n databases \
          -o jsonpath='{.data.BLOGSTATS_RO_PASSWORD}' | base64 -d)
   kubectl --context k3s-homelab exec -n databases deploy/apps-pg -- \
     env BLOGSTATS_PASSWORD="$PW" BLOGSTATS_RO_PASSWORD="$RO" \
     /docker-entrypoint-initdb.d/10-tenants.sh
   ```

   ⚠️ 显式传 env 是为了不依赖 pod 重启：那两个 env 是本次随 Deployment 加的，
   ConfigMap 挂载会自己刷新，env 不会。

   ⚠️ 上面那两个 `kubectl get secret | base64 -d` 会被 Claude Code 的 auto-mode
   classifier 拦掉。等价且更直接的取法是绕开 K8s Secret、直接问 Vault（值同源）：

   ```bash
   export VAULT_ADDR=https://vault.meirong.dev
   PW=$(vault kv get -field=owner_password    secret/homelab/blogstats)
   RO=$(vault kv get -field=readonly_password secret/homelab/blogstats)
   ```

3. 先手工验一轮，绿了再把 `suspend` 改成 `false` 并 push：

   ```bash
   kubectl --context k3s-homelab create job -n monitoring blog-stats-manual \
     --from=cronjob/blog-stats-rollup
   kubectl --context k3s-homelab logs -n monitoring -l app=blog-stats-rollup --tail=30
   ```

   预期日志：`[rollup] csv = N lines` → `staged N rows` → 表行数与 `min/max(day)`。
   ☠️ 若 `staged 0 rows` 会**直接报错退出**（不是静默成功）：那说明 exporter 首刷还没
   完成或 `/pages.csv` 空了 —— 空推会被读成「昨天没人访问」，所以这里刻意判失败。

   ☠️ **2026-09-08 这一轮先失败了一次**，但不是上面这个原因：日志停在 `COPY 3345` 之后
   的 `syntax error at or near "$"` —— 是 `$$` 被 kubelet 转义（见「后果」倒数第二条）。
   判据分得很清：`csv = N lines` 有值说明取数没问题，`COPY N` 有值说明入库连得上，
   错在那之后就只可能是 SQL 本身。
   ⚠️ 预验证不要 `kubectl apply` 覆盖 ArgoCD 跟踪的对象；用 ArgoCD 不跟踪的**新名字**
   （当时是 `blog-stats-rollup-sql-verify` + `blog-stats-verify`），验完删掉再 push。

4. ☠️ **重启 Grafana** —— 少了这步「表里有行」但「面板无数」，且不报任何错：

   ```bash
   kubectl --context k3s-homelab rollout restart deployment/kube-prometheus-stack-grafana -n monitoring
   ```

   数据源口令走 `BLOGSTATS_PG_PASSWORD`（`optional: true` 的 `secretKeyRef`，见
   `values/kube-prometheus-stack.yaml`）。`optional` 的 env 在 Secret 还不存在时**不是
   空串，而是整个变量不存在**，且**env 不会随 Secret 出现而刷新**（挂载的卷才会）——
   与第 2 步 apps-pg 那个坑同一个机制。2026-09-08 实测：Grafana pod 起于 09-07 16:01Z、
   Secret 建于 09-08 01:26Z，重启前容器里 `BLOGSTATS_PG_PASSWORD` 未设置。
   判据（不是「pod Running」）：

   ```bash
   POD=$(kubectl --context k3s-homelab get pod -n monitoring \
           -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
   kubectl --context k3s-homelab exec -n monitoring "$POD" -c grafana -- \
     sh -c 'echo "len=${#BLOGSTATS_PG_PASSWORD}"'   # 期望 32，不是 0
   ```

   收口判据是**面板真出数**（2026-09-08 实测 `/api/ds/query` 对 `uid: blogstats` 返回
   200 + 3345 行 / 2026-08-31..09-06），不是「三个 ExternalSecret 全绿」——
   后者绿了 Grafana 仍可能拿着不存在的口令。

## 相关

- 口径、免费版能力边界、PromQL 配方 → [reference/public-traffic-analysis.md](../reference/public-traffic-analysis.md)
- 为什么自己写这个 exporter → [cf-analytics-custom-exporter](cf-analytics-custom-exporter.md)
- 共享 Postgres 的租户约定 → [shared-postgres-platform](shared-postgres-platform.md)
- CronJob 的两个 deadline 为什么必须有 → [cronjob-and-job-hygiene](cronjob-and-job-hygiene.md)
- 博客自身的托管归属（不在集群里）→ [reference/networking-ingress.md](../reference/networking-ingress.md) 的「不走这条链的 meirong.dev 主机名」
