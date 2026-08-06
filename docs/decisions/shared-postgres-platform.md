# 共享 PostgreSQL 平台：一套模式、两个 Cluster

> 日期: 2026-08-06
> 状态: ✅ 已实施

## 上下文

oracle-k3s 上有两个 postgres，形态完全不同：

| | 形态 | 版本 | 消费者 | 实测内存 |
|---|---|---|---|---|
| `rss-postgres`（rss-system） | 手搓 Deployment，`Recreate` 策略防双写，外挂 postgres-exporter sidecar + NodePort 31087 | **15** | miniflux | 108Mi |
| `zitadel-pg`（zitadel） | CNPG `Cluster` | 17 | ZITADEL | 90Mi |

homelab 集群**一个 postgres 都没有**（bifrost/jobs-sg 是 sqlite，open-notebook 是 SurrealDB，
Vault 是 raft）。所以"合并两个集群的数据库"这个动作从一开始就不存在——两个库本来就同集群、
同节点。真正的问题是**两套并存的模式**：新服务要库时没有可复用的东西，只能再抄一遍
Deployment + PVC + Service + exporter。

顺带查清的两件事实：

- `rss-postgres` 里那个 `karakeep` 库是 **0 张表**的空壳。karakeep 早就是 sqlite
  （`DATA_DIR=/data` + `karakeep-data` PVC），清单里"miniflux + karakeep 共用"是过期注释。
  该实例的真实消费者只有 miniflux 一个。
- **没有任何 scrape 配置在抓 NodePort 31087**（grep 遍 `k8s/helm/values`、
  `k8s/helm/manifests`、`cloud/oracle/manifests/monitoring` 均无）。那个 exporter sidecar
  和 NodePort 是死重量。

## 选项

| 选项 | 评价 |
|---|---|
| A. 维持现状 | 两套模式并存，新服务继续复制粘贴 postgres 清单 |
| B. 合成**一个** Cluster，所有库共用 | 省一个 postmaster（~60-80Mi），但见下方"为什么不合成一个" |
| **C. 两个 Cluster、一套模式（选中）** | `apps-pg` 承载普通应用，`zitadel-pg` 保持独立；都由 CNPG 管 |

## 决策一：统一到 CNPG，`rss-postgres` → `apps-pg`

新建 `databases` ns，起 CNPG `Cluster/apps-pg`（PG17），用
`bootstrap.initdb.import`（type `microservice`，逻辑迁移 pg_dump→pg_restore）把 miniflux
库迁入。以后应用要库 = 加一个 `Database` CR + 一个 `DatabaseRole` CR + 一条 ESO 模板，
**不再自带 postgres 实例**。

顺带清掉的债：PG15（2027-11 EOL）→ PG17、`Recreate` 防双写的 workaround、
手挂的 exporter sidecar 与无人抓取的 NodePort 31087。CNPG 原生在 `:9187` 导出
**428 条 `cnpg_*` 指标**（实测），要接监控直接抓即可。

### ⚠️ `Database` / `DatabaseRole` 必须与 Cluster 同 namespace

两者的 `spec.cluster` 是 **LocalObjectReference（只有 `name`，没有 `namespace` 字段）**。
所以租户的库声明放在 `databases` ns，**不能**放进应用自己的 ns。这是这套平台形态的硬约束，
也是选 `databases` 这个中立 ns（而非把 Cluster 留在 `rss-system`）的原因——否则
`personal-services` 的应用要用库，CR 却得写在 `rss-system` 里。

## 决策二：**不**把 `zitadel-pg` 并进来

先承认一个站不住的论据：这两个库本来就在同一个单节点、同一个内核、同一块盘，
拿"故障域隔离"反对合并是虚的。真正剩下的隔离只对 **postgres 级**故障有效
（内存上限、连接耗尽、坏索引、大版本升级）。

但**内存上限恰好是这个节点最现实的那个**：

- 实测节点内存 **87%**（7730Mi / 8867Mi allocatable），limits 已超卖 **224%**
- `zitadel-pg` 带 `priorityClassName: meirong-critical`，清单原注释：
  "SSO 的库被驱逐 = 全站登录挂，值得最高一档"

合库 = 让 RSS 刷新风暴 / 未来租户的批量导入，和 SSO 的库抢同一个 memory limit。
收益是省一个 postmaster（~60-80Mi，约节点内存的 0.9%）。不值。

`apps-pg` 刻意**不设** `priorityClassName`（默认 0）：`meirong-bulk`(-10) 会让**库比用库的
应用更容易被驱逐**，方向反了；`meirong-critical`(1000) 是留给控制面的。默认档正好落在
bulk 应用之上、控制面之下。

## 决策三：不开超级用户口令，备份改逐库 `pg_dump`

`apps-pg` 设 `enableSuperuserAccess: false`——运维要 psql 就
`kubectl exec -it apps-pg-1 -- psql`（容器内本地 socket，peer auth 直接是 postgres），
不必再往 Vault 塞一份超管口令。

连带影响：夜备从 `pg_dumpall` 改成**逐库 `pg_dump`**。旧的 `rss-postgres` 里 miniflux 恰好
是超级用户，`pg_dumpall` 才跑得通；CNPG 下应用用户只能 dump 自己的库。角色/权限现在由 git
里的 CR 声明，不再需要 globals。

> ⚠️ **这让备份脚本的 PG 段变成了显式清单**——性质等同于它下面那份 sqlite 白名单。
> apps-pg 上每加一个租户，就必须在 `backup/overlays/oracle/backup-script.yaml` 里加一行
> `pg_dump`，否则该库静默不备份。`trends-data` 曾因同类失误静默漏备 2 个月。
> CI 的 H4 规则**查不到这个**：它只扫清单里声明的 PVC，而 CNPG 的 PVC 由 operator 动态创建。

## 后果

- 新增数据库租户的流程变成：`Database` CR + `DatabaseRole` CR（都在 `databases` ns）
  + 应用侧一条 ESO 模板 + 备份脚本加一行。
- 内存基本持平：少一个 exporter sidecar，多一个 CNPG instance manager。本次不是为省内存做的
  （省内存的真正大头是应用侧，例如 stirling-pdf 实测 633Mi）。
- `apps-pg` 的 `externalClusters`/`import` 段在旧库销毁后就指向不存在的 Service 了。
  它**只在 bootstrap 时用一次**，留着无害；想清理可连同 `import` 段一起删，不会触发重建。
- CNPG 的 Barman 备份**没启用**（本环境没有对象存储，备份走 restic → 106 sftp），
  与 `zitadel-pg` 同口径。

## 迁移中踩到的坑

**`postImportApplicationSQL` 属于 `import` 段，不是 `initdb` 段。**
写错层级时 `kubectl apply --dry-run=client --validate=strict` **照样通过**（CRD 的客户端
校验拦不住），但 ArgoCD 的 ServerSideApply 建 typed patch 时报
`field not declared in schema` → 同步失败并进入重试（重试会钉住 revision，
修复 commit 得等重试排空或手工 terminate operation 才生效）。

→ **改 CRD 类清单，预检要用 `kubectl apply --server-side --dry-run=server`**，
那才是 ArgoCD 实际走的路径；字段位置以 `kubectl explain` 为准。

## 相关文档

- [reference/storage.md](../reference/storage.md) — PVC 清单与备份设计
- [reference/services.md](../reference/services.md) — 服务清单（唯一真相源）
- 清单：`cloud/oracle/manifests/databases/`
