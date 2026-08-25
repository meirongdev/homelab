# 共享 PostgreSQL 平台：每个集群一个共享实例

> 日期: 2026-08-06（决策一~三，oracle-k3s）· 2026-08-25 增补决策四（homelab）
> 状态: ✅ 已实施

## 上下文

oracle-k3s 上有两个 postgres，形态完全不同：

| | 形态 | 版本 | 消费者 | 实测内存 |
|---|---|---|---|---|
| `rss-postgres`（rss-system） | 手搓 Deployment，`Recreate` 策略防双写，外挂 postgres-exporter sidecar + NodePort 31087 | **15** | miniflux | 108Mi |
| `zitadel-pg`（zitadel） | CNPG `Cluster` | 17 | ZITADEL | 90Mi |

homelab 集群**一个 postgres 都没有**（jobs-sg 是 sqlite，open-notebook 是 SurrealDB，
Vault 是 raft）。所以"合并两个集群的数据库"这个动作从一开始就不存在——两个库本来就同集群、
同节点。真正的问题是**两套并存的模式**：新服务要库时没有可复用的东西，只能再抄一遍
Deployment + PVC + Service + exporter。

> ⚠️ **上面这句"homelab 一个 postgres 都没有"只在 2026-08-06 成立，别再引用。**
> 之后 homelab 进了两个：`litellm-pg`（2026-08-16，手搓 Deployment）与
> `multica-postgres`（2026-08-18，上游 chart 自带 pgvector）。两者都**没走**本 ADR 定的
> CNPG 租户流程 —— 也就是说"一套模式"在 2026-08-25 之前只在 oracle 生效。
> 收敛过程与为什么 homelab 不用 CNPG 见下面的**决策四**。

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
- `zitadel-pg` 带 `priorityClassName: critical`，清单原注释：
  "SSO 的库被驱逐 = 全站登录挂，值得最高一档"

合库 = 让 RSS 刷新风暴 / 未来租户的批量导入，和 SSO 的库抢同一个 memory limit。
收益是省一个 postmaster（~60-80Mi，约节点内存的 0.9%）。不值。

`apps-pg` 刻意**不设** `priorityClassName`（默认 0）：`bulk`(-10) 会让**库比用库的
应用更容易被驱逐**，方向反了；`critical`(1000) 是留给控制面的。默认档正好落在
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

## 决策四（2026-08-25）：homelab 也收敛成一个实例，但**不装 CNPG**

到 2026-08-25，homelab 上长出了两个各自独立的 postgres —— 都没走上面那套流程：

| | 形态 | 镜像 | 实测内存 | 消费者 |
|---|---|---|---|---|
| `litellm-pg`（litellm ns） | 手搓 Deployment | `postgres:17-alpine` | rss 12.4Mi / ws 47.1Mi | LiteLLM 的 key/spend |
| `multica-postgres`（personal-services） | 上游 chart 自带 | `pgvector/pgvector:pg17` | rss 37.6Mi / ws 76.1Mi | Multica |

合并成 `databases/apps-pg` 一个实例，两个租户（`litellm` / `multica`）。

### 为什么不顺手装 CNPG 统一形态

实测 oracle 上 `cnpg-operator` 自己就吃 **rss 45Mi / ws 69Mi**，比合并省下的那个
postmaster（rss 12–38Mi）还贵。**"一套模式"在 homelab 是净亏内存的**，所以这里的形态
是裸 Deployment + initdb 脚本，与 oracle 的 CNPG **刻意不一致**。

☠️ 代价是**同名不同物**：两个集群都有 `databases/apps-pg`，但 oracle 那个 pod 叫
`apps-pg-1`、服务是 `apps-pg-rw`、加租户 = 加 `Database`/`DatabaseRole` CR；homelab 这个
pod 前缀是 `apps-pg-`、服务就叫 `apps-pg`、加租户 = 改 initdb 脚本 + 手工建库 + 备份脚本加
一行。照抄对面的运维命令会全部对不上。取这个名字仍然值：角色一致比名字唯一重要，
而两边的差异在清单文件头写死了。

### 这次合并**不是**为省内存

`k8s-node` 当时 requests 61% / available 3951Mi，不缺这 40–50Mi。真收益是少一套要维护的
手搓清单、少一个 PVC。**如果哪天有人拿"省内存"当理由再做一次类似合并，先看这一行。**

### 镜像取 pgvector 而不是 alpine

multica 的上游镜像就是 `pgvector/pgvector:pg17`。它现在**没有**建 vector 扩展（实测库里
只有 `pg_trgm`/`pgcrypto`/`plpgsql`），但上游哪天加一条 `CREATE EXTENSION vector` 的迁移，
alpine 上就会启动即炸，而症状是 backend 的 `./migrate up` 卡死在 startupProbe ——
一点不像"缺扩展"。pgvector 镜像是官方 `postgres:17`(bookworm) 的超集，换过去零损失。

### 隔离：一处变严，一处变松

- **变严**：租户不再是 superuser（旧实例的 `POSTGRES_USER` 是），且 initdb 里
  `REVOKE CONNECT ON DATABASE <t> FROM PUBLIC` —— 实测跨租户连库被拒
  （`permission denied for database "multica"`）。
- **变松**：两个库共享一个 memory limit、一次重启、一个 postmaster 故障域。
  ⚠️ 具体后果是 **multica 的库故障能把 LLM 网关一起拖下去** —— LiteLLM 设了
  `DATABASE_URL` 就硬依赖库（虚拟 key 校验走库）。两者都不在关键路径上，且本来就同节点
  同盘，所以接受；但这是这次合并唯一真实的可用性代价，别忘了它存在。

### 迁移方式：逻辑 dump，不是拷数据目录

集群内 `pg_dump | psql`（`--no-owner --no-privileges` + `--single-transaction`），
以租户身份灌进新库。**不能拷数据目录**：旧的 litellm-pg 是 alpine(musl)、新实例是
bookworm(glibc)，跨 libc 搬 PGDATA 的排序规则不安全。逻辑恢复顺带绕开了这一点。

逐表对账（这次真做了，不是"看着对"）：

| | 表 | 行 | 其它 |
|---|---|---|---|
| litellm | 68 | 374 | 虚拟 key 17 条、SpendLogs 86 条 |
| multica | 108 | 2558 | 索引 365、扩展 3、`schema_migrations` 381 行（所以 backend 启动的 migrate up 是 no-op）|

### 加租户的流程当天就被走了一遍（nakama）

2026-08-25 同日新增 `nakama`（游戏后端）作为第三个租户，四步一步没少：
① initdb 脚本加一行 `create_tenant` + ESO 加一个口令 key（为重建准备，脚本本身**不会**对
已初始化的实例生效）→ ② 在活实例上手工执行同样的 SQL 建角色/库/`REVOKE CONNECT` →
③ 备份脚本加 2e) 段 `pg_dump` → ④ 应用侧 ESO 渲染连接串。
第 ③ 步是唯一没有任何检查兜底的一步，而 nakama **没有 PVC**，漏了它整个服务零备份。

### 决策二在这次一并复核了：**仍然不并 `zitadel-pg`**

2026-08-25 复测 oracle 节点：requests **75%**、limits 超卖 **226%**（当初是 87%/224%），
`zitadel-pg` 仍带 `critical`、`apps-pg` 仍是默认档。前提没变，所以决策二不变。
真正的代价也说清楚：合并后一个实例只能有一个 priorityClass，等于**失去单独给 SSO 的库
设 limit 和优先级的能力**，收益仍只是一个 postmaster（zitadel-pg 实测 rss 47.7Mi）。

### 这次踩到的四个坑

1. ☠️ **删 chart values 里的 `postgres:` 块会带走 YAML 锚点。** `&pin-control-plane` 原先
   定义在 `postgres.affinity` 上，frontend 还在 `*pin-control-plane` 引用它。锚点丢了
   **不报错**，是整份 values 解析失败 → `helm template` 渲染出**空文件**。
   删块前先 grep `&`。
2. chart 的 `postgres.external.enabled=true` 不只是"不建 postgres"：它同时让 backend
   不再注入 `env: DATABASE_URL`、ConfigMap 不再有 `POSTGRES_*` —— 连接串**只**能从
   `existingSecret` 经 envFrom 进来。好处是不会和 chart 的 env 撞成 SSA 重复键硬失败。
3. Kyverno 的 `restrict-image-registries` 是**字面前缀匹配**，镜像必须显式写
   `docker.io/`。省略前缀虽然能拉到镜像，策略却判违规（`failureAction: Audit` 所以
   fail-open，pod 照跑，只在 PolicyReport 里留一条永久违规）。合并前的两个旧实例
   **都在违规**，实测确认。
4. ⚠️ **旧 PVC 不会被 prune**（都带 `Prune=false`，multica 那个是集群侧注解），
   所以旧数据还在盘上，而 multica 那个 App 会**一直 OutOfSync**（`requiresPruning=True`
   但被拦住）。手工删掉旧 PVC 才收口 —— 挂着 OutOfSync 的 App 会掩盖将来真实的漂移。

## 后果

- 新增数据库租户的流程变成：`Database` CR + `DatabaseRole` CR（都在 `databases` ns）
  + 应用侧一条 ESO 模板 + 备份脚本加一行。
- 内存基本持平：少一个 exporter sidecar，多一个 CNPG instance manager。本次不是为省内存做的
  （省内存的真正大头是应用侧，例如 stirling-pdf 实测 633Mi）。

  > ⚠️ **读 `kubectl top pod` 会被误导。** 迁移刚完成时 apps-pg 显示 209Mi，是旧库
  > (101Mi) 的两倍——但那是 working set，其中绝大部分是 `shared_buffers`（128MB，
  > 与 postgres:15-alpine 默认值相同）被完整触达后计入的**共享内存/页缓存，可回收**。
  > 看 kubelet summary 的分项：apps-pg `rssBytes` 只有 **25Mi**，比跑了 18 天的
  > zitadel-pg（`rss` 41Mi / `workingSet` 117Mi）还低。当时的虚高是验证工作本身造成的
  > （往该实例恢复了 29MB 对账转储 + ANALYZE），稳态应向 zitadel-pg 那档靠拢。
  > 判断 postgres 容器的真实占用要看 `rssBytes`，别只看 `top`。
- `apps-pg` 的 `externalClusters`/`import` 段在旧库销毁后就指向不存在的 Service 了，
  是**刻意保留的死引用**：`bootstrap` 只在建库时读一次，集群 initialized 之后 CNPG 不再看它。
  ⚠️ 不要为了"清理干净"去删它——那是在动一个有数据的库的 bootstrap 配置，收益纯属美观，
  而 CNPG 对 bootstrap 变更的处理**没在本环境验证过**。真要动，先拿一次性测试 Cluster 验。
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
