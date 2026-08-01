# Open Notebook 部署（homelab k3s）

> 状态: ⚠️ **已上线，模型接线待在 UI 完成** —— 2026-08-01 部署验证通过：两个 Pod Running、
> `https://notebook.meirong.dev` 返回 307（跳登录）、四个 ArgoCD App 全 Synced+Healthy、
> Homepage 条目已加载、Uptime Kuma PostSync hook Succeeded。剩下的是浏览器里配模型（见"未完成项与理由"）。
> 日期: 2026-08-01
> 范围: 把 Open Notebook 跑起来、接上现有推理算力（DGX + Mac OMLX），并把它纳入既有的备份/门户/探测体系。

## 落点决策

| 项 | 值 | 依据 |
|---|---|---|
| 集群 | **homelab** | 见下方"为什么不是 oracle" |
| 命名空间 | `personal-services` | 书库 PVC `calibre-books-local` 在此；PVC 是 ns 级对象，摄取侧必须同 ns |
| ArgoCD App | 复用 `personal-services`（目录源） | 该目录"放进即生效"，无需新建 Application |
| 域名 | `notebook.meirong.dev` | HTTPRoute 即 DNS，不动 `cloudflare/terraform` |
| 部署形态 | 两容器（app + SurrealDB v2） | `-single` 变体上游已标 deprecated、v2 移除 |

### 为什么不是 oracle-k3s（`add-service` 技能的默认集群）

2026-08-01 实测：**oracle 节点看不见 DGX Spark**。

```
oracle → 100.97.87.120   tailscale ping → "no matching peer"；curl :8000 → 8s 超时
oracle → tailscale status → 7 个 peer，两台 spark 均不在列
homelab k8s-node → 100.97.87.120:8000/v1/models → 200（TCP connect 66ms）
```

不是 ACL 问题（`tailscale/terraform/main.tf` 里 `tag:oracle` 已是 `dst=["*:*"]`）。两台 spark 属于
**另一个 tailnet**（`spark-ccf3.tailf63175.ts.net`，owner `kaixinhuang3307@`），靠 node sharing 共享进来；
共享是按"人"授予的 —— `meirongdev@` 名下的设备（k8s-node、两台 Mac、pve）在 netmap 里有它，
而 `node0` 是 `tagged-devices`，拿不到共享节点。

要改成 oracle 可达，需要动 tailnet 侧（去掉 node0 的 tag 会牵动 `main.tf` 里靠 `tag:oracle`
自动批准的 `10.0.0.26/32` 路由），不在本方案范围内。

## 资源代价

节点当前（2026-08-01）：requests 5222Mi/11.5Gi（44%），实测已用 7744Mi（66%），
`MemAvailable` 5.15GB，磁盘 48.3GB 可用。

本方案新增 requests **896Mi / 150m**，limits **2304Mi / 1500m**：

| 容器 | requests | limits |
|---|---|---|
| `open-notebook` | 100m / 640Mi | 1000m / 1536Mi |
| `open-notebook-surrealdb` | 50m / 256Mi | 500m / 768Mi |

档位按 [reference/k8s-qos-resource-management.md](../../reference/k8s-qos-resource-management.md)：
用户 Web 服务 500m–1000m、数据库 500m，全部 Burstable。
后台任务并发压到 2（`OPEN_NOTEBOOK_WORKER_MAX_TASKS`，默认 5），避免和 LGTM/Vault 抢这台
idle ~74°C 的 5600H。

## 模型接线（部署后在 Settings → API Keys 里配）

v1 推荐 UI 配置，落 SurrealDB；env 那套（`OPENAI_COMPATIBLE_BASE_URL*`）上游已标 deprecated，故不写进清单。
以下 base URL / 模型 ID 均为 2026-08-01 实测存在的值：

| 用途 | 凭据类型 | Base URL | 模型 |
|---|---|---|---|
| 对话/生成 | OpenAI-Compatible（LLM URL） | `http://100.97.87.120:8000/v1` | `deepseek-v4-flash`（`max_model_len` 1,000,000） |
| Embedding | oMLX | `http://100.89.15.120:8000/v1` | `mlx-community__Qwen3-Embedding-4B-4bit-DWQ` |
| STT | OpenAI-Compatible（**STT URL**） | `http://100.89.15.120:8000/v1` | `mlx-community__Qwen3-ASR-1.7B-8bit` |
| TTS | OpenAI-Compatible（**TTS URL**） | `http://100.89.15.120:8000/v1` | `mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` |
| Rerank | — | — | ⚠️ `/v1/rerank` 路由在，但 Mac 上**没加载 reranker 模型**，需先加载 |

要点：

- **oMLX 凭据只支持 chat + embedding**，不支持 STT/TTS —— 音频两项必须走 OpenAI-Compatible
  凭据的 per-service URL。`/v1/audio/transcriptions` 与 `/v1/audio/speech` 在 mbp-m2-pro 的
  OMLX 上实测存在（POST 空 body 返回 422 字段校验错误，非 404）。
- 不经 Bifrost：这两个后端在 tailnet 上对 k8s-node 直接可达，走网关只是多一跳。
  `llm.meirong.dev` 继续只服务公网面（codex）。
- **DGX 那条是跨境链路**：k8s-node 在新加坡（`tailscale netcheck` 最近 DERP = sin 4.2ms），
  spark 在国内，中间经 DERP(hkg)，无直连，RTT 66–83ms。对话流式感觉不到，
  但**逐条同步调用（如批量向量化）会被 RTT 吃掉**，摄取必须批处理。
- **mbp-m2-pro 是笔记本**，OMLX 上列了 5 个模型但装不下同时常驻，会按需换入换出；
  embedding 密集任务与 TTS/对话并发时延迟会跳。

## 执行步骤

1. **写 Vault**（前置，否则 ESO 拉不到、Pod 停在 `CreateContainerConfigError`）。

   **不需要切 kubectl context**：`vault.meirong.dev` 经 Cloudflare Tunnel → Cilium Gateway
   → `vault:8200`，从这台 Mac 直连即可；token 用 `~/.vault-token` 里已缓存的 root（`expire_time: null`）。
   唯一的坑是 **`VAULT_ADDR` 不设会连 `127.0.0.1:8200` 然后 connection refused**：

   ```bash
   export VAULT_ADDR=https://vault.meirong.dev
   vault kv put secret/homelab/open-notebook \
     encryption-key="$(openssl rand -hex 24)" \
     app-password='<你选的 UI 登录口令>' \
     surreal-password="$(openssl rand -hex 16)"

   # 只看键名不打印值
   vault kv get -format=json secret/homelab/open-notebook \
     | python3 -c "import json,sys;print(sorted(json.load(sys.stdin)['data']['data']))"
   ```

   KV 是 **v2、挂在 `secret/`**（`vault secrets list` 可确认），所以路径就是 `secret/homelab/…`。
   写完让 ESO 立刻拉（否则等 `refreshInterval: 1h`）：

   ```bash
   kubectl -n personal-services annotate externalsecret open-notebook-secret \
     force-sync=$(date +%s) --overwrite
   ```

   **隧道/网关挂了时的兜底**（走集群内；⚠️ pod 里的 `$VAULT_TOKEN` 是空的，
   照抄 oracle 侧那套 `VAULT_TOKEN=$VAULT_TOKEN vault kv put` 会 403）：

   ```bash
   # vault-keys.json 是 gitignored 且本机已无副本，先从集群里的备份恢复
   kubectl -n vault get secret vault-backup-keys \
     -o jsonpath='{.data.vault-keys\.json}' | base64 -d > vault-keys.json
   ROOT=$(python3 -c "import json;print(json.load(open('vault-keys.json'))['root_token'])")
   kubectl -n vault exec vault-0 -- sh -c \
     "VAULT_TOKEN=$ROOT vault kv put secret/homelab/open-notebook encryption-key=… app-password=… surreal-password=…"
   ```

   ⚠️ `encryption-key` 丢失 = 库里存的模型凭据全部解不开。它本身也在 Vault 的备份范围内。

2. **push**，ArgoCD 3 分钟内同步（`personal-services` + `gateway` 两个 App）。

3. **验证**：

   ```bash
   kubectl -n personal-services rollout status deploy/open-notebook-surrealdb
   kubectl -n personal-services rollout status deploy/open-notebook
   dig +short notebook.meirong.dev
   curl -sS -o /dev/null -w '%{http_code}\n' https://notebook.meirong.dev
   ```

4. **配模型**（上表），逐项 Test Connection。

## 本轮已落地的配套改动

| 项 | 文件 | 说明 |
|---|---|---|
| SurrealDB 进夜备 | `backup/overlays/homelab/{backup-script,cronjob-patch,open-notebook-external-secret,kustomization}.yaml` | rocksdb 是活进程持有的一组 `.sst/MANIFEST`，热拷不一致、也不匹配脚本按 `*.db*` 抓文件的规则 → 改走 HTTP `GET /export` 拿 SurrealQL 全量（与 Vault raft snapshot 同为"逻辑 dump"）。口令走**独立** ExternalSecret + `optional: true` 卷：Vault 还没写时只 warn，不让新应用的密钥拖垮整条夜备（该仓库 2026-07-07 栽过同类跟头） |
| 按需摄取工具 | `k8s/helm/manifests/personal-services/open-notebook-ingest.yaml` | 挂 `calibre-books-local`（只读）→ POST `/sources`。**默认 suspend、参数为空即拒跑、单次 MAX_BOOKS 上限**三道闸，防止 2040 本被无差别灌进去 |
| Homepage 入口 | `cloud/oracle/manifests/homepage/homepage.yaml` | 个人服务区加一条。**不写 `kubernetes:` 块**——Homepage 在 oracle，查不到 homelab 的 pod（同 Calibre-Web） |
| Uptime Kuma 探测 | `cloud/oracle/manifests/uptime-kuma/provisioner.yaml` | 公网 URL 探测；`200-299`+`300-399` 都收，等实测出稳定状态码再收紧 |
| 修 `add-service` 技能 | `.claude/skills/add-service/SKILL.md` | 第 3 步说 homelab 的 HTTPRoute 追加进 `gateway.yaml`、parentRef 用 port 8000——两条都不对。实际是**一服务一个 `route-*.yaml`**（2026-07-31 目录化后），Gateway listener 是 **port 80**（现有 4 条 route 全用 80） |

已验证：`kubectl apply --dry-run=server` 全部通过、`kubectl kustomize backup/overlays/homelab` 构建通过
（原有 volume/mount 未被 patch 挤掉）、两段内嵌 shell `sh -n` 通过、`scripts/check-docs.py` 0 违规。

## 上线实测（2026-08-01）

```
ArgoCD:   personal-services / gateway / backup / oracle-k3s → 全部 Synced + Healthy @ a5db2b7
Pods:     open-notebook 1/1、open-notebook-surrealdb 1/1
ESO:      open-notebook-secret SecretSynced（3 个键齐）
公网:     https://notebook.meirong.dev → 307（跳登录页，符合开了 OPEN_NOTEBOOK_PASSWORD 的预期）
pod 内:   :5055/health → 200 {"status":"healthy"}；:5055/api/health → 401；:8502/ → 307
门户:     homepage pod 重启后已加载条目（ConfigMap 走 subPath，同步不触发 reload）
探测:     oracle-k3s 的 PostSync hook Succeeded → Uptime Kuma monitor 已 provision
```

### ⚠️ 踩到一个会复现的坑：HTTPRoute 的 `BackendNotFound` 排序竞态

路由由 `gateway` App 同步、工作负载由 `personal-services` App 同步，**两者没有先后保证**。
这次路由先落地，Cilium 记下 `ResolvedRefs=False / BackendNotFound`，然后 **Service 创建后它不会自动重算**
——`observedGeneration` 停在 1，等 5 分钟状态不动，表现是 `gateway` App 一直 Degraded。

碰一下路由（加个无意义注解）即刻变 `True`，随后把注解删掉状态仍保持 `True`：

```bash
kubectl -n personal-services annotate httproute open-notebook reconcile-nudge="$(date +%s)" --overwrite
kubectl -n personal-services annotate httproute open-notebook reconcile-nudge-
```

已写进 `add-service` 技能第 3 步，以后每加一个服务都该顺手查一次 `ResolvedRefs`。

## 未完成项与理由

| 项 | 为什么没做 | 怎么解 |
|---|---|---|
| **模型接线** | 只能在浏览器 UI 做（Settings → API Keys）。非弃用的配置路径只有 UI，env 那套上游已标 deprecated | 按上方"模型接线"表逐项填 + Test Connection |
| **Reranker 模型** | 要加载在 `mbp-m2-pro` 的 OMLX 上。那台机器**不在本仓库的 IaC 范围内**，且本机没有它的 SSH 权限（`Permission denied (publickey)`），无法远程操作 | 在那台 Mac 上加载一个 MLX reranker，再回 UI 配 Rerank |
| **摄取脚本未跑过一次真实上传** | 需要先在 UI 建出 notebook 拿到 id。⚠️ 对活实例验证时**抓出一个真 bug 并已修**：脚本原来打 `:5055/sources` → **404**，FastAPI 的 router 全挂在 `/api` 下（`POST /api/sources` 返回 400 "File upload or file_path is required"，说明路由在、`type=upload` 认）。只有探针用的 `/health` 在根上 | 建好 notebook 后把 `MAX_BOOKS` 改成 `1` 试一本 |
| **夜备的 SurrealDB 导出未经一次真实夜跑** | CronJob 03:00 触发，上线时已过点。`/export` 端点与请求头取自 SurrealDB v2 文档，未对活库打过 | 看 08-02 凌晨那次的日志有没有 `open-notebook.surql = N bytes`，或手工 `just backup-run` |
| **oauth2-proxy + ZITADEL** | 刻意不做：Open Notebook 没有原生 OIDC，套 oauth2-proxy 等于在它自带的口令认证之上再叠一层，且前端→后端的内部转发要额外验证不被打断。单用户下收益不抵复杂度 | 保持 `OPEN_NOTEBOOK_PASSWORD` |
