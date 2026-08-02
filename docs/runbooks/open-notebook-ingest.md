# Open Notebook — 从 Calibre 书库批量摄取

> **触发条件**：想把书库里某一批书灌进某个 notebook 做研读/问答。
> **成功判定**：job 日志每本 `ok (200)`；`/api/sources` 里 `embedded: True` 且 chunk 数 >0；
> UI 里该 notebook 能对书内容问答/语义搜索。
> **回滚**：摄取只"新增 source"——删错灌的书在 UI 里删 source 即可，不动书库（只读挂载）。
> 执行目录：仓库根。首跑验证：2026-08-01（SRE 书，111 chunks，见文末数据点）。
>
> ☠️ **2026-08-02 起这条链路横跨两个集群，命令必须带 `--context`**：
> 书库与 ingest Job 在 **oracle-k3s**（calibre 迁走了），Open Notebook 应用本身在
> **k3s-homelab**（模型后端是跨 tailnet 按人共享的 DGX/Mac，oracle 的 tagged-device
> 看不到它们）。Job 因此不再走集群内 svc，而是经公网 `notebook.meirong.dev/api`
> 把文件推回 homelab，Bearer 口令由同源读同一 Vault path 的 ExternalSecret 提供。

## 设计要点（为什么不是"全量同步"）

书库 23G/2040 本，大多数书永远不会被问到——所以**没有自动同步**。摄取是一个
默认挂起的 CronJob 模板（schedule 写成 2 月 31 日 + `suspend: true`），三道闸：
`NOTEBOOK_ID`/`BOOK_PATTERN` 为空直接失败退出、`MAX_BOOKS` 单次上限。
参数进 git，"什么时候灌过什么"可追溯。

## 步骤

### 1. 预览 pattern（必做）

pattern 是对**完整路径** `grep -i`，作者名/书名/目录名都行。先看它会捞到什么：

```bash
kubectl --context oracle-k3s -n personal-services exec deploy/calibre-web -c calibre-web -- sh -c \
  'find /calibre-library -type f -size -95000000c \( -name "*.epub" -o -name "*.pdf" \) | grep -i "<pattern>"'
```

⚠️ 短 pattern 会误捞：裸 `sre` 同时命中作者 `Sreeram`/`Sreejith` 的无关书——首跑最终用的是
作者名 `betsy beyer`（唯一命中）。

### 2. 改参数并 push

编辑 `cloud/oracle/manifests/personal-services/open-notebook-ingest.yaml` 顶部的
`open-notebook-ingest-params` ConfigMap：

| 参数 | 说明 |
|---|---|
| `NOTEBOOK_ID` | 目标 notebook（UI 建好后从地址栏/API 拿，形如 `notebook:xxxx`；也可 `POST /api/notebooks` 建） |
| `BOOK_PATTERN` | 第 1 步验证过的 pattern |
| `MAX_BOOKS` | 单次上限；**新 pattern 首跑先 `"1"`** |
| `EMBED` | 默认 `"true"`（摄取时同步向量化）；Mac 不在线时可 `"false"` 只提取文本，之后 UI 重嵌 |

```bash
git add -A && git commit -m "chore: ingest <pattern> into <notebook>" && git push
# 等 ArgoCD 同步 ConfigMap（~1 分钟），确认：
kubectl --context oracle-k3s -n personal-services get cm open-notebook-ingest-params -o jsonpath='{.data.BOOK_PATTERN}'
```

### 3. 手工触发

```bash
kubectl --context oracle-k3s -n personal-services create job --from=cronjob/open-notebook-ingest ingest-$(date +%s)
kubectl --context oracle-k3s -n personal-services logs -l job-name=ingest-<时间戳> -f
```

期望日志：`matched N file(s)` → 每本 `ok (200)` → `DONE rc=0`。

### 4. 验证处理完成

上传返回 200 后，提取/切片/向量化在**后台异步**跑（worker 并发 2）：

```bash
# embedded 变 True、embedded_chunks >0 即完成（一本书约 2-3 分钟，见数据点）
kubectl --context k3s-homelab -n personal-services exec deploy/open-notebook -- sh -c \
  'curl -s -H "Authorization: Bearer $OPEN_NOTEBOOK_PASSWORD" http://127.0.0.1:5055/api/sources' \
  | python3 -m json.tool | grep -E '"title"|"embedded"'
# 语义搜索冒烟（可选）：
#   POST /api/search {"query":"...","type":"vector","search_sources":true}
```

## 故障排查（每条都是首跑真踩过的）

| 症状 | 原因 | 处理 |
|---|---|---|
| `matched 0 file(s)` 但预览有 | find 报错被吞过一次（BusyBox 不认 `-size -95M`，已改 `-95000000c` 且不再静音 stderr）——若复发，看 job 日志里 find 的 stderr | 脚本已修；pattern 打偏则回第 1 步 |
| `curl: (26) Failed to open/read local data` | calibre 路径里的**逗号**被 curl `-F` 当多文件分隔符 | 已修（`@` 路径套双引号）；路径带 `"` 的文件仍会失败（calibre 会把 `"` 转 `_`，实际不出现） |
| 每本 `FAILED (401)` | Bearer 口令不对：secret 卷权限（曾因 0400 + uid 100 读不到，已改 0444）或 Vault 里换了口令没 rollout restart | `kubectl --context oracle-k3s -n personal-services get secret open-notebook-ingest-secret`；对照 [reference/open-notebook.md 运维备忘](../reference/open-notebook.md) |
| 每本 `FAILED (404)` | API 路径没带 `/api` 前缀（router 全挂在 `/api` 下，只有 `/health` 在根） | 脚本已修，别改回去 |
| `FAILED (413)` | 单文件超上游 100MB 上限 | find 的 95MB 过滤本应挡住；确认没人改小 `OPEN_NOTEBOOK_MAX_UPLOAD_SIZE_MB` |
| 上传 200 但 `embedded` 一直 False | Mac OMLX 不可达/在忙（embedding 全走它） | `curl http://100.89.15.120:8000/v1/models`；曾有旧进程假死先例——重启 omlx 服务（`macbook/ansible/`，Homebrew 服务 `homebrew.mxcl.omlx`） |

已知行为（非 bug）：**不去重**——同一 pattern 跑两次会重复建 source，靠 `MAX_BOOKS` 和人工触发兜底。

## 单本捷径

一两本书不必走这套：UI 里直接拖文件上传即可。区别：UI 直传且不在书库里的**原件**不在备份
口径内（提取文本/向量在 DB 里，见 [reference/open-notebook.md](../reference/open-notebook.md) 真相源地图）。

## 首跑数据点（2026-08-01，容量规划用）

Google《Site Reliability Engineering》epub：提取秒级；111 chunks（avg 1401 字符）；
embedding 146.5s ≈ **1.3s/chunk**（走 Mac，含模型换入）。据此 20 本一批 ≈ 50 分钟，
全在 Mac 串行——别与播客渲染/35B 对话撞车。
