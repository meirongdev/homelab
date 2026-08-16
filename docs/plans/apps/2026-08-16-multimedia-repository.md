# 多媒体仓库（收藏音乐 / 自录 podcast / 视频）

> 日期: 2026-08-16
> 状态: ⚠️ 部分完成
> 结论: 在 homelab 建一个「以 **NAS 106 ZFS 为媒体唯一真相源、k8s 只做 serving 层」的多媒体仓库。
> 媒体（尤其 >500GB 视频）放 106 的 `mrstorage` ZFS（raidz1 + sanoid 快照 = 本地保护），
> Jellyfin（视频）/ Navidrome（音乐）/ 静态 RSS（podcast 发布）作为 homelab k8s 负载，
> 经**只读 NFS** 挂 106 的 `media/`。新增**零云成本**（全走现有 homelab + 106 + 已有隧道/DNS）。
> 刻意不引 Castopod（PHP 全家桶，超出小范围所需）。
> 视频只有 106 本机 ZFS 保护、**无离站副本**（用户已确认接受的成本取舍）。
>
> **实施进度（2026-08-16）**：NFS 只读 export ✅ · Jellyfin/Navidrome/podcast 部署 ✅ ·
> HTTPRoute/DNS ✅（media/music/podcast.meirong.dev 公网 200）· 备份/PSA/SLO ✅。
> 落地时按现有媒体布局调整（复用 106 已有 movie/tv/anime/music，不新建 media/ 树），
> 并修了 worker 缺 nfs-common 导致的 NFS FailedMount。**未包含**：yt-dlp 下载 Job（Task 9，可选后置），
> pod 账号与 RSS 分集更新流程（维护性，非阻塞）。

## 1. 现状与动机

### 1.1 需求

- 收藏音乐（自己收集的 mp3/flac）——规模小，GB 级。
- 自录 podcast 分集——mp3，小范围（几十人内）对外 RSS 订阅。
- 视频（自拍 + 网上下载），**>500GB 且长期攒**——成本大头是它。

### 1.2 为何「数据在 106、serving 在 k8s」是低成本正解

双集群余量（[cluster-placement](../../decisions/cluster-placement-for-new-services.md)）与其存储本质：

| 落点 | 结论 |
|------|------|
| homelab（热笔记本 amd64） | 本地 NVMe **无冗余**；500GB+ 视频塞 `local-path` + 每夜 restic 上传 = 烧盘 + 备份体积/带宽成本爆表。**不适合作视频的"家"** |
| oracle-k3s（Arm 免费层） | 只剩 ~2.6GB 内存、无块存储，**视频根本塞不下**，排除 |
| **NAS 106（ZFS `mrstorage`）** | **为海量数据而造**：raidz1 + sanoid 快照。视频 500GB 吃 ZFS 保护，restic 不必备份它 → 备份不爆炸。这是数据唯一真相源的合理落点 |

106 恰是 NAS 本体（`192.168.50.106` / TS `100.110.27.111`，ZFS pool `mrstorage` 挂 `/storage`）。
媒体放 106 是符合现有存储架构（[storage.md](../../reference/storage.md)）的延伸，而非新引入的故障面。

### 1.3 只读 NFS 是路线 A 的代价，但有据可依

- [storage.md](../../reference/storage.md) 明言：**「大顺序读对 NFS 耐受度高得多，NFS 的坑在 sqlite 的
  lock+fsync」**。媒体是**顺序读 + 只读 + 非关键路径**，恰是 NFS 能安全兜住的那类；
  不做运行时 sqlite/PG（那才是当初退役 NFS 的根因）。
- 重开 106 **一个只读 export**（`ro,sync,all_squash`，只暴露 `media/`），k8s 侧以 NFS volume
  readOnly 挂载。这是 NFS 退役（2026-07-11）以来的**首个、也是唯一一个**例外，范围严格限定在
  "serving 只读媒体"。

### 1.4 podcast 发布：为什么是静态 RSS 而非 Castopod

- 需求量级 = 小范围（几十人内）→ 家宽上行 + Cloudflare Tunnel 足够，零成本。
- **Castopod**（PHP + 联邦/订阅管理全家桶）超出所需；引入一个大后端 + 数据库，违背"最低成本"。
- 静态 RSS = mp3 落 106 + 一个手写/脚本生成的 `rss.xml` + 封面，经隧道公网。
- 若未来订阅量真涨到需要对象存储/稳定带宽，再迁 Cloudflare R2（免费档）——**YAGNI，本次不做**。

## 2. 目标架构

```text
                ┌──────────────────────────────────────────────┐
                │ NAS 106 — ZFS pool mrstorage → /storage       │
                │   media/                                      │
                │     music/          收藏音乐 (mp3/flac)        │
                │     podcast/        自录 podcast 分集 (mp3)    │
                │     podcast/feed/   生成的 RSS + 封面          │
                │     video/          视频（自拍 + 下载归档）    │
                │     video/inbox/    上传暂存（人工整理去重）    │
                │     download/       yt-dlp 下载暂存区          │
                │   raidz1 + sanoid 快照 = 本地保护              │
                └──────────────────────────────────────────────┘
                          ▲ 只读 NFS (media/ 仅只读, ro,sync,all_squash)
                          │
 Internet → Cloudflare Tunnel → Cilium Gateway → k8s (homelab)
                │
   Jellyfin (video) · Navidrome (music) · 静态 RSS (podcast)
                │        Metadata/DB → homelab local-path PVC
```

### 组件清单（全在 homelab，amd64）

| 组件 | 职责 | 变化 | 说明 |
|------|------|------|------|
| NAS 106 只读 NFS export | 暴露 `media/` 给 k8s | 新增 | `ro,sync,all_squash`，只读、只媒体；Ansible 管理 |
| Jellyfin | 视频播放 | 新增 | 用户选手机/电脑标准浏览器 → **无需转码** → CPU 低，不烧热笔记本 |
| Navidrome | 音乐库 + 流播 | 新增 | 单 Go 二进制 + sqlite，极轻；Subsonic API 兼容多端 |
| 静态 RSS | podcast 发布 | 新增 | mp3 + `rss.xml` + 封面，经隧道公网 |
| yt-dlp Job | 网上下载 | 可选 | 周期 batch，落 `download/`（CPU/带宽型 → homelab）|
| HTTPRoute ×3 | 子域名入口 | 新增 | 新建子域名不需动 Cloudflare（external-dns）|

落点理由：三服务都 amd64-only/或需 NFS 到 106/或走 k8s，故全放 homelab；轻量但需要本集群
数据与 NFS，符合 [cluster-placement](../../decisions/cluster-placement-for-new-services.md) 判据。

## 3. 关键决策

1. **媒体唯一真相源在 106 ZFS**；Jellyfin/Navidrome 的 metadata DB 放 homelab `local-path`
   （小，照常进 restic）。**视频不进 restic**（太大；restic 目标也是 106，跨机冗余本就做不到）
   ——吃 106 的 raidz1 + sanoid 快照。用户已确认接受「视频仅本地 ZFS 保护、无离站副本」。
2. **只读 NFS 是唯一例外**：范围严格限定"serving 只读媒体顺序读"。所有写路径（上传/下载/整理）
   走非 k8s 侧（直接写 106 的 SMB/ssh），**不让 k8s 负载有 106 的写权**，避免再次踩 NFS 写锁坑。
3. **保留 Jellyfin + Navidrome 双组件**，不用 Jellyfin 单扛音乐：Navidrome 是专业音乐工具
   （元数据/刮削/多端 Subsonic 客户端），体验明显更好；两者都近零成本，组件数取舍偏向体验。
   否决 Funkwhale（联邦/公开是它的重价值，个人私藏仓库用不上，纯付复杂度）。
4. **podcast 用静态 RSS**，不上 Castopod（见 §1.4）。
5. **新子域名走现有隧道**：写 HTTPRoute 即可（external-dns 建记录 + 隧道通配路由），
   **不改 `cloudflare/terraform`**（[networking-ingress.md](../../reference/networking-ingress.md)）。
6. **镜像按 digest 钉死**（仓库惯例）；Jellyfin/Navidrome 需确认 amd64 digest（均 amd64-only 无 arm64 顾虑）。

## 4. 不做的事（YAGNI）

- 不做 Castopod / 去中心化音乐联邦（Funkwhale）。
- **不上视频转码**（用户设备浏览器直放直播；转码会烧热笔记本，是长期成本）。
- 不上传去重/自动整理工具（手动 inbox → video 起步；后续有需要再加）。
- 不接 Cloudflare R2 对象存储（podcast 量小，家宽够用）。
- 视频不进 restic（见决策 1）。

## 5. 前置准备（执行前必读）

- 执行目录：仓库根 `cd /Users/matthew/projects/homelab`；集群 context `k3s-homelab`。
- 确认 NAS 106 可用路径与权限：`/storage/media` 目录结构、`mediabackup`（或等效）只读 export 规划。
- NFS export 由 `proxmox/ansible/storage-playbook.yaml` 管理（现有 topology 里 media 与 calibre
  类似地作为 Ansible 管理的 export）。
- 待核实（执行时再查，写进计划不等）：Jellyfin / Navidrome 最新稳定版 amd64 digest、PSA baseline
  兼容性、NFS external provisioner 选型（仓库无现成 NFS provisioner，需引入或用手动 NFS PV）。

---

## Task 1 — NAS 106 媒体目录 + 只读 NFS

**目的**：在 106 建媒体目录树，导出**只读** NFS，供 k8s serving 层挂载。

- [ ] **Step 1: 建目录树**（106，Ansible 管理，非临时）

```bash
ssh root@100.110.27.111   # storage-106，Tag homelab
mkdir -p /storage/media/{music,podcast/feed,video/inbox,video/archive,download}
chown -R <media-user>:<media-group> /storage/media     # 所有写路径走非 k8s 侧
zfs snapshot mrstorage@media-init                        # 初始化快照
```

- [ ] **Step 2: 只读 NFS export**（`proxmox/ansible/storage-playbook.yaml`）

```text
/storage/media  <homelab节点或子网>(ro,sync,all_squash,anonuid=<media-uid>,anongid=<media-gid>,subtree_check)
```

> 只读 + all_squash，k8s 负载永远没有 106 的写权（决策 2）。媒体是顺序读，安全。

- [ ] **Step 3: 验证本机挂载只读**

```bash
ssh root@100.110.27.111 exportfs -v | grep media
mount -t nfs 100.110.27.111:/storage/media /mnt/media-test -o ro && \
  touch /mnt/media-test/x 2>&1 || echo "readonly confirmed"   # 触摸应报错
```

---

## Task 2 — homelab k8s：NFS 卷 + Jellyfin

**Files（新建）：** `k8s/helm/manifests/jellyfin/` 下若干清单。

- [ ] **Step 1: 只读 NFS PV/PVC**（或引入 NFS external provisioner —— 见 §5 待核实）

  手动 NFS PV 最简：一个 `ReadOnlyMany` PV 指向 `100.110.27.111:/storage/media/video`，
  readOnly，storageClassName `manual-nfs`（不占 local-path）。Jellyfin 挂它 + 自有
  `local-path` PVC 存 metadata/db。

- [ ] **Step 2: Jellyfin Deployment + Service**（amd64 digest，`jellyfin/jellyfin`）
  - metadata/db → `local-path` PVC `jellyfin-data-local`（小，进 restic）
  - 媒体 → 只读 NFS 挂 `/media`
  - **不配转码 GPU**；客户端直放。`requests: cpu 250m / mem 512Mi`（实测校准）

- [ ] **Step 3: ExternalSecret**（Vault `secret/homelab/jellyfin`，无则跳过鉴权）

---

## Task 3 — 音乐 Navidrome

**Files（新建）：** `k8s/helm/manifests/navidrome/`。

- [ ] **Step 1: Navidrome Deployment + Service**（amd64 digest；单 Go 二进制 + sqlite）
  - sqlite/data → `local-path` PVC `navidrome-data-local`（小，进 restic）
  - 媒体 → 只读 NFS 挂 `/music`
  - `requests: cpu 50m / mem 128Mi`（极轻，`priorityClassName: bulk`）

- [ ] **Step 2: ExternalSecret**（Vault `secret/homelab/navidrome`，含 admin 口令）

---

## Task 4 — podcast 静态 RSS

**Files（新建）：** `k8s/helm/manifests/podcast/`（nginx 静态站 + rss.xml 生成脚本）。

- [ ] **Step 1: mp3 落位**：分集进 `/storage/media/podcast/`，`feed/` 放 `rss.xml` + 封面
- [ ] **Step 2: 静态站**（nginx 镜像，只读 NFS 挂 `podcast/`），HTTPRoute → 公网
  - RSS 里 `<enclosure url>` 指向 mp3 的公网 URL（经隧道）
- [ ] **Step 3: rss.xml 生成**（脚本入库，幂等；本阶段可手写 XML 起步）

---

## Task 5 — HTTPRoute + 域名（外部收敛）

**Files（新建）：** `k8s/helm/manifests/gateway/route-<service>.yaml` ×3。
新子域名（如 `media.meirong.dev` / `music.…` / `podcast.…`）**不需动 Cloudflare**——
写 HTTPRoute，external-dns 建记录 + 隧道通配路由。首次部署查 `ResolvedRefs`（homelab 路由/workload
同步排序竞态，见 skill `.claude/skills/add-service/SKILL.md`）。

---

## Task 6 — ArgoCD 注册

**Files（新建）：** `argocd/applications/{jellyfin,navidrome,podcast}.yaml`
（destination `https://100.94.186.7:6443` = homelab，见
[argocd-app-patterns.md](../../reference/argocd-app-patterns.md)）。git push → 3 分钟轮询同步。

---

## Task 7 — 备份接入

- Jellyfin/Navidrome 的 metadata/sqlite PVC → `backup/overlays/homelab/backup-script.yaml` 白名单
  （H4 兜底）。**视频/音乐本体不进 restic**（在 106 ZFS 快照保护，决策 1）。

---

## Task 8 — PSA / SLO / 告警

- `k8s/helm/justfile` 的 `psa_baseline_ns` 加 `jellyfin navidrome podcast`；`just harden-psa`
- `k8s/helm/manifests/monitoring/slos.yaml` 加 `jellyfin-availability` 等（可选，起步可后置）

---

## Task 9 — yt-dlp 下载（可选，后置）

周期 batch Job 落 homelab（CPU/带宽型），写 `download/` 暂存 → 手动归档 `video/archive/`。
下载也走非 k8s 侧更省事——本次列为**可选**，YAGNI 起步可不做。

---

## Task 10 — 文档与索引

- 新增 `docs/decisions/multimedia-repository-nfs-readonly.md`（决策 1–2 的 ADR，R3 字段）
- 更新 `docs/reference/services.md`（服务清单唯一真相源）、`docs/ROADMAP.md`（如适用）
- 更新 `docs/plans/apps/README.md` 索引 + `docs/plans/README.md` 份数（apps 8→9）
- `python3 scripts/check-docs.py` 期望 exit 0

---

## Task 11 — 验收清单

- [ ] 106 `media/` 只读 NFS export 生效；k8s 挂载只读，写被拒
- [ ] Jellyfin 可播放视频（直放，无转码），metadata PVC 落 local-path 且进备份
- [ ] Navidrome 可播放音乐，多端 Subsonic 客户端可连
- [ ] podcast RSS 公网可达，`<enclosure>` mp3 可下载
- [ ] 新子域名 external-dns owner 生效，无需改 `cloudflare/terraform`
- [ ] 新增 PVC 全进 restic 白名单（H4 过）
- [ ] `python3 scripts/check-docs.py` exit 0
- [ ] 更新本计划文首状态为 `✅ 已完成`，同步两处 README 索引状态

## 附：相关文件地图

| 动作 | 路径 |
|------|------|
| NFS export | `proxmox/ansible/storage-playbook.yaml` |
| 新服务清单 | `k8s/helm/manifests/{jellyfin,navidrome,podcast}/` |
| ArgoCD App | `argocd/applications/*.yaml` |
| 备份 | `backup/overlays/homelab/backup-script.yaml` |
| SLO/PSA | `k8s/helm/manifests/monitoring/slos.yaml`、`k8s/helm/justfile` |
| 文档 | `docs/decisions/multimedia-repository-nfs-readonly.md`、`docs/reference/services.md`、`docs/plans/{apps,}/README.md` |
