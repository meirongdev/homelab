# 媒体 serving 重新引入 NFS：只读、只媒体，是 2026-07-11 退役后的唯一例外

> 日期: 2026-08-16（本文补写于 2026-08-20，见文末「为什么补写」）
> 状态: ✅ 已实施
> 关联：[plans/apps/2026-08-16-multimedia-repository.md](../plans/apps/2026-08-16-multimedia-repository.md)（执行快照，本决策出自其 §3 决策 1–2）·
> [reference/storage.md](../reference/storage.md)（存储布局与 PVC 清单的**唯一真相源**）·
> [cluster-placement-for-new-services](cluster-placement-for-new-services.md)

## 上下文

2026-07-11，106 宕机 3 天之后，**全部** PVC 从 NFS 迁到 `local-path`、`nfs-client`
provisioner 卸载。那次退役的结论被反复引用成一句话：**「NFS 已退役，106 只做冷备份目标，
运行时零依赖」**。

2026-08-16 要建多媒体仓库（Jellyfin / Navidrome / 静态 podcast RSS），撞上一个硬约束：
**媒体本体 >500GB 且长期增长**，而三个候选落点里只有一个放得下：

| 落点 | 结论 |
|---|---|
| homelab `local-path`（笔记本 NVMe） | 无冗余；500GB+ 视频 + 每夜 restic 上传 = 烧盘 + 备份体积爆表。**不适合作视频的家** |
| oracle-k3s | 只剩 ~2.6GB 可用内存、无块存储，**根本塞不下** |
| **NAS 106 的 ZFS `mrstorage`** | raidz1 + sanoid 快照，本来就是为海量数据造的 |

于是数据必须在 106，而 serving 层（要 amd64、要 HTTPRoute、要 k8s）在 homelab。
**数据和进程被分在两台机器上**，这就是本决策要回答的问题。

## 决策

**重新引入 NFS，但严格限定在「serving 只读媒体」这一个用途上。**

具体形态（as-built）：

- 106 上 **5 个只读 export**，全部
  `ro,insecure,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000`，
  授权网段 `192.168.50.0/24`：
  `/storage/{movie,tv,anime,music,podcast}`（`proxmox/ansible/storage-playbook.yaml` 的
  `nfs_exports`）。
- k8s 侧是 **5 个手写的静态 PV/PVC**（`k8s/helm/manifests/media/nfs-pv.yaml`），
  **不经 provisioner、不属于任何 StorageClass**。
- 应用自己的可写数据（Jellyfin config、Navidrome DB）仍走 `local-path`，
  **照常进 restic**；媒体本体不进 restic。

三条边界，缺一条这个决策就不成立：

1. **只读，且只读是服务端保证的。** PV 上的 `readOnly: true` 只是给 kubelet 的提示，
   真正拦写的是 export 的 `ro`。**k8s 负载永远没有 106 的写权**：所有写路径
   （上传 / 下载 / 整理）走非 k8s 侧（直接写 106 的 SMB/ssh）。
2. **只有顺序读的大文件。** 当初退役 NFS 的根因是 sqlite 的 `fcntl` 锁 + 小写入 fsync
   在 NLM 上能阻塞分钟级（[storage.md](../reference/storage.md) 有 Grafana CrashLoop 8 天
   的实例）。媒体是顺序流，恰是 NFS 能安全兜住的那类。
   **任何 sqlite / PG 都不许回 NFS**，这条没有例外。
3. **不重装 provisioner。** 动态供给一旦回来，"下一个 PVC 顺手用 NFS" 就会重演，
   静态 PV 让每一次使用都必须显式写进清单、被 review 看见。

配套取舍（同批定的，一并记在这里免得散落）：

- **媒体不进 restic**，吃 106 的 raidz1 + sanoid。理由不是"不重要"，是做不到：
  restic 的目标仓库也在 106，把 106 的数据备份到 106 不产生任何跨机冗余，只是把 500GB
  抄一遍。用户已确认接受「视频仅本地 ZFS 保护、无离站副本」。
  H4 的 `BACKUP_EXEMPT` 里逐条写了这个理由。
- **Jellyfin / Navidrome 两个组件都留**，不用 Jellyfin 单扛音乐（Navidrome 的元数据/刮削 +
  多端 Subsonic 客户端体验明显更好，两者都近零成本）。否决 Funkwhale（联邦是它的重价值，
  私藏库用不上）。
- **podcast 用静态 RSS**（nginx 伺服 mp3 + `rss.xml`），否决 Castopod：PHP 全家桶 + 数据库，
  为几十人的订阅量引入一个大后端不划算。

## 被否决的替代方案

| 方案 | 为什么否决 |
|---|---|
| 媒体拷进 homelab `local-path` | 笔记本盘无冗余，500GB+ 撑不住，且每夜 restic 会把备份体积/带宽打爆 |
| 服务跟数据一起搬到 106 上裸跑（不进 k8s） | 丢掉 HTTPRoute/external-dns/隧道/监控/PSA 全套；106 只有 8G 内存且已经紧到 ARC 砍到 1G |
| 用 CSI（如 `csi-driver-nfs`）而不是静态 PV | 又把动态供给装回来了，正是边界 3 要防的；本场景只有 5 个固定卷，静态 PV 更少动件 |
| SMB/CIFS 代替 NFS | 没有解决任何 NFS 的实际问题（本场景不写、不加锁），却多一套凭据与挂载语义 |
| 对象存储（R2 / Garage）+ 客户端直读 | 500GB 出口带宽与成本；且 Jellyfin/Navidrome 的库扫描假定 POSIX 目录 |

## 后果

**正面**

- 媒体落在唯一放得下它、且**本来就有冗余**（raidz1 + 快照）的地方，新增云成本为 0。
- serving 层保持无状态可重建：删掉 `media` ns 不丢任何媒体。
- 退役 NFS 时真正想根除的东西（provisioner、可写 PVC、sqlite on NFS）一样都没回来。

**负面 / 必须一直记着的**

- ☠️ **106 从此不再是"非运行时依赖"。** 加上它同时托着 worker VM（2026-08-13），
  106 宕机 = homelab 少一个节点 + 三个媒体服务有进程无数据。
  「106 宕机只暂停备份窗口」这句话**在 2026-08-13 之后就是错的**。
- 媒体没有离站副本，也不会有（进 restic 无意义，见上）。106 整机损毁 = 媒体全损。
  这是已知且被接受的敞口，与 ROADMAP 开放项 #1（离站备份）不是同一件事。
  那条覆盖的是 restic 仓库，不覆盖媒体。
- NFS 服务端挂起的故障签名要记住：**节点 load 飙到数千、containerd 报
  `failed to reserve container name`**：修 NFS，不是修 containerd。
- worker 节点需要 `nfs-common`，缺了表现为 `FailedMount`（落地时实际踩到并修了）。

## 与原计划的差异（as-built）

计划写的是「重开 106 **一个**只读 export，暴露新建的 `media/` 树」。实际落地改成
**复用 106 已有的 `movie/tv/anime/music` 目录 + 新建 `podcast`，5 个 export**：
不迁移、不动原数据，省掉一次 500GB 的搬运和随之而来的路径重写。
代价是 export 数从 1 变 5，`nfs_exports` 列表长一些，语义完全相同。

## 为什么补写

本文是 2026-08-16 计划 §Task 10 明确要求的产物，**当时没写**。后果在四天里可验证地发生了：
`AGENTS.md`、`ARCHITECTURE.md`、`storage.md`、`terminology.md` 四处继续声称
"NFS 已退役 / 106 非运行时依赖 / 全部 PVC 用 local-path"，与已经上线的只读 NFS 直接矛盾，
而 `check-docs.py` 全绿。**结构检查看不出内容与集群不符**。
2026-08-20 的文档复核一次性修掉那四处，并补上本文作为这个例外的**唯一解释处**：
以后再有人问"不是说 NFS 退役了吗"，答案在这里，不必每篇文档各写一遍。
