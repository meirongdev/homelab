# 多媒体目录重组（storage-106 /storage/tv 清理去重）

> 日期：2026-08-16 ｜ 状态：✅ 已完成（2026-08-16 执行，回收 ~146G）
> 目标主机：`root@192.168.50.106`（NAS storage-106，ZFS 池 `mrstorage` 挂 `/storage`）
> 背景：多媒体仓库 Jellyfin/Navidrome 上线后，需让 Jellyfin 能正确索引 TV 存量。
> 但 `/storage/tv` 现状目录混乱（规整目录 + release 平铺 + 散文件三重混存），
> release 平铺多数是规整库的**字节级重复**，会让 Jellyfin 扫描到重复/识别错剧。

## 目标目录规范（Jellyfin 兼容）

所有剧集统一为 **`剧名/Season N/SxxExx.扩展名`**（TVDB 标准结构）：

```
/storage/tv/<剧名>/
  Season 1/
    <剧名>.S01E01.<质量>.mkv
  Season 2/
    ...
```

此结构 Jellyfin 开箱即正确识别剧名/季/集并抓元数据。不搞额外软链层。

## 现状审计（dry-run 实测，只读）

`/storage/tv` 现有 **20 个顶层目录 + 106 个顶层散 .mkv**，总 **292G**。

已规整、保留的剧（无需动）：

| 剧 | 结构 | 含集 |
|----|------|------|
| `Annedroids/` | Season 1-4 | 52 集 |
| `Bluey/` | Season 1-3 | 147 集 |
| `Kipo and the Age of Wonderbeasts/` | Season 2-3 | 17 集 |
| `My Little Pony - Make Your Mark/` | Season 1,6 | 3 集 |
| `StoryBots - Answer Time/` | Season 1-2 | 22 集 |
| `We Bare Bears/` | Season 1 | 1 集 |
| `Disney Gallery - The Mandalorian/` | Season 1-3 | 11 集 |

**重复项（规整库字节级重复，可删，回收 ~120GB+）**：

- `Annedroids.S01..S04.*-TrollHD[rartv]/` ×4 —— 与 `Annedroids/` 各季**完全重复**（已抽样 sha256 同）；每季多 `RARBG.txt` 垃圾。约 83G。
- `Bluey (2018) Season 1 S01 (…Garshasp)/` —— 与 `Bluey/Season 1` 同名 52 个文件完全重复。4.7G。
- 顶层散 `Bluey 2018 S02E*/S03E* mkv` 约 45 个 —— 与 `Bluey/Season 2,3` 重复（S02 顶层 45 文件、S03 顶层 49+）。约 30G。
- `Disney Gallery Star Wars The Mandalorian S01/S02 *-SEV/` —— 与 `Disney Gallery - The Mandalorian/` S01,S02 重复。10G。
- `Disney.Gallery.Star.Wars.The.Mandalorian.S03E01…-EDITH[TGx]/` —— 与库内 `Season 3/...-EDITH[TGx].mkv` 同名同源（文件名差 `-EDITH`/`-EDITH[TGx]` 后缀）。2.9G。
- `Kipo.And.*.S03…[eztv.io]/` + 顶层散 `Kipo…S02E0x…-GHOSTS.mkv` ×7 —— 与 `Kipo…/Season 3,2` 重复。约 8G。
- `My.Little.Pony.Make.Your.Mark.S*.mkv` ×3 —— 与 `My Little Pony - Make Your Mark/` 重复。3G。
- `StoryBots.Answer.Time.S01/S02.*/` —— 与 `StoryBots - Answer Time/` 重复。8.7G。
- `We.Bare.Bears.S01E26…-W4F/` —— 与 `We Bare Bears/Season 1` 同名同源。~0.2G。

**待用户确认的独立项（不纳入自动去重）**：

- `The.Mandalorian.S02E03…-BlackEgg.mkv`（1 个 770M，Mandalorian 正片 S02E03，意大利语+英语音轨）—— 仓库无 Mandalorian 正片规整目录，**建议新建 `The Mandalorian/` 预留**或暂留不入库。
- `screw/`（23 个 2022 年散乱下载，无规范命名）—— 疑似随手下载，建议你确认是否为垃圾后清理。

## 执行策略

1. **先 dry-run**（`--dry-run`），逐条列出将删除项，全部显示（已跑通）。
2. **字节级安全兜底**：`--execute` 时每个待删文件删除前必须能在规整库找到**同名且 sha256 相同**的副本；找不到则跳过并报告，**绝不误删唯一副本**。
3. 重复项确认后删除（`rm -rf`）。**不迁移**（规整库本身已在标准结构，无需搬）。
4. 待定项（Mandalorian 正片 / screw）单独处理。
5. 整理完由 Jellyfin 新建库指向 `/media/tv` 扫描验证。

## 执行结果（2026-08-16）

**主去重**：删除 114 项重复（Annedroids ×4、Bluey 顶层散件 + S01 平铺、Disney Gallery ×3、
Kipo S03 平铺 + 散件、MLP 散件、StoryBots ×2、We Bare Bears 平铺），均字节校验通过。

**补充清理**（文件名带 `[组名]` 后缀导致严格 basename 不匹配的 3 目录）：Kipo eztv（10 视频）、
Disney S03E01-EDITH、We Bare Bears S01E26，按 **SxxExx 集号 + size + sha** 校验后删除。

**手动项**：`The Mandalorian.S02E03…ITA.ENG` → 新建 `/storage/tv/The Mandalorian/Season 2/` 归置。
`screw/` 23 个散乱 mkv 确认垃圾删除。

**最终 TV 结构**（8 个规整剧集，0 散件，全为标准 `剧名/Season N/`）：
`Annedroids`(S1-4) · `Bluey`(S1-3) · `Disney Gallery - The Mandalorian`(S1-3) ·
`Kipo and the Age of Wonderbeasts`(S2-3) · `My Little Pony - Make Your Mark`(S1,6) ·
`StoryBots - Answer Time`(S1-2) · `The Mandalorian`(新建,S2) · `We Bare Bears`(S1)

**空间**：`/storage/tv` 292G → **146G**，回收 **~146G**。ZFS mrstorage REFER 542G → 396G。

## 脚本

- 分析：`/tmp/media_audit/analyze_tv.py`、`plan_tv2.py`（只读审计，已存 106 `/tmp/media_audit/`）
- 主去重：`/tmp/media_audit/reorg3.py`（`--dry-run` 预演／`--execute` 执行，字节兜底）
- 补充：`/tmp/media_audit/reorg_extra.py`（处理组名后缀目录）

## 关联

- 多媒体仓库设计：[../apps/2026-08-16-multimedia-repository.md](../apps/2026-08-16-multimedia-repository.md)
- 存储现状（唯一真相源）：[../../reference/storage.md](../../reference/storage.md)
- 目标系统：NAS 106 ZFS 池 `mrstorage`，LAN `192.168.50.106` / TS `100.110.27.111`
