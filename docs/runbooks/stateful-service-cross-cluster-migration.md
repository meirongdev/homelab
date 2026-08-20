# 有状态服务跨集群迁移 (Stateful Service Cross-Cluster Migration)

> 触发条件：要把一个**带 PVC 的**服务从 homelab 搬到 oracle-k3s（或反向），
> 且需要保住数据、尽量短的切换窗口。无状态服务不需要本文，改 destination 推送即可。
> 目标：给出一条已经跑通过的执行序列，以及每一步「不做就会静默出问题」的配套。
> **成功判定**：§ 5 校验全绿 + § 6 域名切换后业务可用。
> **回滚**：源端保留到 § 7 之前——§ 6 域名切换未完成前可整体回切；§ 7 后源端已退役，需走
> [backup-recovery.md](backup-recovery.md) 的 restic 恢复。
> Last updated: 2026-08-18
>
> 本文由 2026-08-03 的 calibre 迁移（书库 23G / 2061 本 / 3 个 sqlite）反推而成，
> 那次的实测数字与事故见
> [../plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md](../plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md)。
> **下一个用户大概率是 Vault**（仍挂在那份文档的「剩余候选」里）。

## 0. 动手前必须核实的三件事

| 核实项 | 怎么查 | 踩过的坑 |
|---|---|---|
| **镜像支持目标架构** | `docker manifest inspect <image>@<digest>` 看有没有 `linux/arm64` | oracle 是 aarch64。calibre 那次 digest 原样复用**是安全的**（核实过是多架构 manifest list）；但此前的 oauth2-proxy 样例就栽过——那次 pin 的是**单架构 digest**，搬过去直接起不来 |
| **目标集群容量** | `kubectl --context <target> get node -o wide`；`df -h` | 别只看 `kubectl top` 的百分比，页缓存会骗人（见迁移文档 §5） |
| **是否真的能搬** | 依赖是否跨 tailnet / 是否必须贴着抓取目标 | open-notebook 搬不了：模型后端 DGX/Mac 是**按人共享**的节点，oracle 的 tagged-device 在 netmap 里看不到它们 |

## 1. 建空壳，让 PVC 落地

⚠️ **`local-path` 是 `WaitForFirstConsumer`** —— `replicas: 0` 时 PVC 根本不绑定，
节点上不会有目录，**就无处 rsync**。所以必须先真起一次 Pod。

```bash
# 目标集群：先部署完整清单（含 PVC），让它跑起来一次
git add cloud/oracle/manifests/<app>/ && git commit && git push     # ArgoCD 3 分钟内同步
kubectl --context oracle-k3s -n <ns> get pvc          # 确认全部 Bound
```

此时**不动数据、不切域名**，源端仍在正常服务。

> 空卷上 init 容器失败是正常的（例：calibre 的 `disable-auto-convert` 报
> `no such table: cwa_settings`，它假定 `cwa.db` 已存在）。这同时说明一件事：
> **光靠 Git 无法从零重建这类应用**，必须先恢复 config PVC。

## 2. 停掉目标端 Pod，让卷静止

```bash
# 目标集群改 replicas: 0（走 Git，别手工 scale——selfHeal 会打回来）
kubectl --context oracle-k3s -n <ns> get pod          # 确认已无 Pod
```

## 3. 配套改造（这一步漏了不会报错，只会静默出问题）

**在传数据的同时做掉**，因为它们都不影响源端服务：

| 配套 | 不改的后果 | 现在有没有网兜住 |
|---|---|---|
| **备份白名单** | 备份脚本是**显式白名单**，搬过去不加 = 数据直接掉出 restic，且**不会有任何报错** | ✅ CI 的 H4 会拦（[manifest-safety-checks.md](../reference/manifest-safety-checks.md)） |
| **SLO / 告警** | oracle 侧指标名不同：`envoy_cluster_upstream_rq_xx_total`（带 `_total`，otel remote-write 的命名差异）+ 需要 `cluster="oracle-k3s"` 过滤。照抄 homelab 写法得到**空集**，SLO 恒绿 | ❌ 只能人工核对，查询要实跑一次 |
| **配额护栏** | LimitRange/ResourceQuota 常常留在原地 —— **风险搬走了，防护留下**。calibre 那组护栏当初就是为 ebook-sync 泄漏 92 个 Job pod 加的 | ❌ 人工 |
| **工具链默认 context** | 脚本 / skill / justfile 里的 `kubectl` 打到旧集群 | ❌ 人工；跨集群后所有命令都得带 `--context` |
| **隐藏耦合** | 见下 | ❌ 人工 |

⚠️ **隐藏耦合要先解开再删**。calibre 的 `route-calibre-web.yaml` 里那条
`allow-gateway-to-calibre` ReferenceGrant **没限定 Service 名**，实际覆盖整个 ns，
`route-open-notebook.yaml` 一直在白蹭它。直接删文件 = 瞬间弄断 `notebook.meirong.dev`，
而症状（HTTPRoute `ResolvedRefs=False`）与 calibre 毫无关联，排查会很久。

做法：**先加一条命名如实的独立 grant**，ReferenceGrant 是累加式授权，两条共存无冲突，
旧的随原文件一起删，中间没有空窗。

## 4. 两遍 rsync（关键手法）

PVC 在节点上就是目录：`/var/lib/rancher/k3s/storage/pvc-<uid>_<ns>_<pvc-name>`。

```bash
# 先取两端的实际目录名
ssh <src-node>  "sudo ls -d /var/lib/rancher/k3s/storage/*_<ns>_<pvc>"
ssh <dst-node>  "sudo ls -d /var/lib/rancher/k3s/storage/*_<ns>_<pvc>"

# 第 1 遍：源端**仍在运行**时全量传（耗时最长的一遍，不占停机窗口）
rsync -aHAX --info=progress2 <src>/ <dst>/
```

**第 1 遍拿到的 DB 是不可用的** —— sqlite 处于 WAL 模式、库是活的
（calibre 那次 `metadata.db` 带 152KB 未 checkpoint 的 `-wal`）。所以：

```bash
# 停源端实例（切换窗口从这里开始计时），让 sqlite 干净关闭
# 第 2 遍：增量，只传变化
rsync -aHAX --info=progress2 <src>/ <dst>/
```

第 2 遍按 `size+mtime` 跳过已传文件 —— calibre 那次 2000+ 书籍文件全部跳过，
**实际只传了 811KB（speedup 29772）**。停机窗口因此是秒级而非小时级。

## 5. 校验（进域名切换前必须全绿）

```bash
# sqlite 完整性 —— 每个库都要
sqlite3 <db> 'PRAGMA integrity_check;'        # 期望 ok

# 业务级计数，与源端逐项比对（比 integrity_check 更能发现"传了但传错"）
sqlite3 metadata.db 'SELECT count(*) FROM books; SELECT count(*) FROM authors;'
```

calibre 那次的验收线：`metadata.db` 2043 本 / 2578 作者、`app.db` 2 个用户账号
（**登录凭据保住**）、`cwa.db` 的 `auto_convert=0`（init 容器要改的设置已在）、
文件数 2061、`/login` HTTP 200。

## 6. 域名两步切换

必须**分两个提交**，不能一步到位 —— external-dns 的 owner TXT 机制决定了
同一记录不能被两个集群同时持有。

```
第 1 步：摘掉源端 HTTPRoute  → 等 external-dns 删掉 CNAME + owner TXT
   核对：CF 上该名字的记录数确实为 0，且**同域其它记录未受影响**
第 2 步：挂上目标端 HTTPRoute → 目标端 external-dns 以自己的 owner 重建
   核对：CNAME 指向目标隧道 ID、owner TXT 已变成目标集群的 externaldns
```

> 新增子域名只写 HTTPRoute 即可，**不要碰 `cloudflare/terraform`**
> （隧道已是 `*.meirong.dev` 通配路由）。见 [../decisions/external-dns-adoption.md](../decisions/external-dns-adoption.md)。

## 7. 退役源端

☠️ **删任何清单文件前先 `grep '^kind:' <file>`** —— 看有没有作用域大于该文件的资源。
2026-08-03 就是 `Namespace` 内嵌在 `calibre-web.yaml` 顶部，`git rm` 掉它 →
ArgoCD prune 掉整个 ns → **级联删光同 ns 的 open-notebook 数据**
（[复盘](../records/2026-08-03-namespace-prune-cascade.md)）。
Namespace/CRD 这两类现在由 CI 的 H1 拦截，但「语法对、位置错」的（如寄生的
ReferenceGrant）仍要靠眼睛。

```bash
grep '^kind:' <要删的每个文件>
```

其余收尾：

- **源端备份脚本移除对应逻辑**，否则每晚打 `[warn] ... NOT in this backup`
- Application 的 `path` 与 `destination` 一起改（destination 写错会把负载装错集群，
  由 H2 拦截）
- ⚠️ **带 `Prune=false` 的 PVC 删清单不会删数据**，需在确认目标端服务正常后**手工删除**
  —— 这是刻意的护栏，别在切换当天就删

## 8. 残余清扫（迁移完成后单独跑一轮）

删 ns / 删清单**带不走**这四类东西，它们会长期留在源端：

| 残余 | 为什么留下 | 怎么清 |
|---|---|---|
| 集群级 RBAC（ClusterRole/Binding） | 不属于任何 ns | 逐个点名删。☠️ 别按前缀批量删——`argocd-manager` 是 oracle 纳管 homelab 的**活凭据** |
| 无 `ownerReferences` 的 trivy 报告 | trivy 的 GC 靠 ownerRef 级联 | `kubectl delete configauditreport <name> -n <ns>` |
| Vault path | 消费它的 ExternalSecret 删了，path 还在 | 两集群 ExternalSecret 交叉核对确认零消费者后 `vault kv metadata delete` |
| containerd 镜像 | k3s 镜像 GC 阈值是磁盘 **85%**，低于此永不触发 | `k3s crictl rmi --prune` |

⚠️ `crictl rmi --prune` 会刷一屏 `DeadlineExceeded`（默认 RPC 超时 2s，控制面那台笔记本
的 containerd 跟不上），**但删除其实在后台完成了**。别看见报错就重跑，先 `df -h` 复核。

完整的一次实例（2026-08-03，释放 9GB）见迁移文档的「残余清理」一节。

## 相关

- [../plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md](../plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md) — 本文的来源，含实测数字与剩余候选
- [argocd-control-plane-on-oracle.md](argocd-control-plane-on-oracle.md) — 控制面本身搬家（不是应用搬家）
- [../reference/manifest-safety-checks.md](../reference/manifest-safety-checks.md) — H1/H2/H4 三条正是为本文里的坑写的
- [../records/2026-08-03-namespace-prune-cascade.md](../records/2026-08-03-namespace-prune-cascade.md) — 退役步骤的事故复盘
- [backup-recovery.md](backup-recovery.md) — 真出事时怎么从 restic 恢复
