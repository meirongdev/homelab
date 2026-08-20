# LiteLLM LLM 网关迁移（替换旧网关）

> 日期: 2026-08-01（2026-08-16 实施：纳入 MacPro M2 OMLX 第二上游，计划已落地）
> 状态: ✅ 已完成（2026-08-16 部署 litellm 上线；现状见 decisions/litellm-llm-gateway.md 与 reference/services.md）
> 结论: 把 homelab 的 LLM 网关从 **旧网关**（`llm.meirong.dev`）整体换成 **LiteLLM proxy**（`litellm/litellm:v1.94.1`），
> 同主机名、同 OpenAI 兼容面，旧网关无真实使用 → **不设计回退**。
> 用 Rust 重写的是 LiteLLM 的 core/realtime 网关（截至 2026-08-01 只覆盖 `/v1/realtime`）；本次部署的是仍由
> Python 承载的**官方生产 proxy**（chat/responses/keys 全在 Python 侧，仓库 README 明示 "until each Rust path
> has parity coverage and production evidence"）。**动机不是 Rust**，而是：
> (1) 网关真正被用起来之前的"网关即代码"改造（config.yaml 进 git，替代旧网关的 PVC-SQLite 配置漂移坑）；
> (2) 砍掉 oauth2-proxy + ZITADEL client 一组只为"无鉴权 admin 面"而生的配套（LiteLLM 管理面自带认证）；
> (3) 为 ROADMAP 上"多自托管算力 fallback"铺平（LiteLLM 原生支持 fallback/load-balancing）——
>     本次补全把第二个自托管推理源 **MacPro M2 OMLX**（`100.89.15.120:8000`，Qwen3.6-35B）一并收进网关，
>     与 DGX 组成「DGX 主 + Mac 兜底」的 fallback 链（接线可行性由 Open Notebook 实证，见 §1.3）。

## 1. 现状与动机

### 1.1 现在是什么

- **旧 LLM 网关**在 homelab 网关命名空间运行，`llm.meirong.dev`（ArgoCD 旧网关 App；
  该 App 已于 2026-08-08 退役，本方案即其接替设计）。
- 架构：Cloudflare Tunnel → Cilium Gateway → HTTPRoute（`/v1,/openai,/anthropic,/genai` 直连旧网关 +
  virtual-key 门；其余 → oauth2-proxy → ZITADEL 登录）。
- 旧网关下游：`http://100.97.87.120:8000`（DGX Spark vLLM `deepseek-v4-flash`），pod → tailnet 直连已实测可行。
- **第二个自托管来源（2026-08 补）**：MacPro M2 OMLX `http://100.89.15.120:8000`（OpenAI 兼容，
  Qwen3.6-35B / 262k ctx），同为 tailnet 可达；接线已被 Open Notebook 生产使用（见 §1.3）。
- 已知脆弱点：旧网关的 enforce 开关 + 路由规则 +
  虚拟 key 全在 **PVC SQLite**（旧网关的 PVC），不在 git；重建 PVC 即"开门"。
- 消费方：`~/.zshrc` 的旧网关 virtual key + `codex-dgx` alias → `~/.codex/litellm.config.toml`
  （`base_url=https://llm.meirong.dev/v1`，`wire_api=responses`，model `custom_dgx/deepseek-v4-flash`）。
  **旧网关基本没被实际使用**（仅本机 Codex profile 接了一个 virtual key，日常主要直连 vLLM）。

### 1.2 为什么换 LiteLLM

| 对比项 | 旧网关 | LiteLLM proxy |
|--------|---------|---------------|
| 配置存放 | PVC SQLite（重建即丢，git 里只有 intent） | `config.yaml` 进 git（ConfigMap），GitOps 一致 |
| 虚拟 key / spend | 有 key，无 spend | key + spend + budget 头等公民（Postgres 持久化） |
| admin 面鉴权 | 无（要 oauth2-proxy 兜） | 自带 UI 登录（`UI_USERNAME/UI_PASSWORD`） |
| fallback / 多上游 | 支持 | 支持（ROADMAP 多自托管算力 fallback 可落） |
| 生态/维护 | 较新、小众 | 主流、活跃（v1.94.x 稳定线） |
| 资源 | Go，~384Mi | Python，~1Gi（单节点可接受，见 Task 2） |

### 1.3 双自托管来源的接线可行性（2026-08 补全，Open Notebook 实证）

两个推理源对 **homelab 控制面（k8s-node）都直连可达**，且已被 Open Notebook 生产使用——
[open-notebook.md](../../reference/open-notebook.md) 是接线事实的唯一真相源：

| 来源 | 端点 | 模型 | ctx | 备注 |
|------|------|------|-----|------|
| DGX Spark vLLM | `100.97.87.120:8000/v1` | `deepseek-v4-flash` | 1M | 跨境链路（SG→CN，DERP hkg，RTT 66–83ms），忽略鉴权 |
| MacPro M2 OMLX | `100.89.15.120:8000/v1` | `mlx-community__Qwen3.6-35B-A3B-nvfp4` | 262k | 笔记本，多模型按需加载；embedding 密集任务与 35B 并发时延迟会跳 |

要点（决定 gateway 配置怎么写的坑）：

- **两个后端对 k8s-node 直接可达，经 Open Notebook 已实测**：不需要任何代理/dgx-proxy 那类转发层。
  ⚠️ **worker-106 不行**（tagged-device netmap 里没有这两个源），网关必须留在控制面。
- **Mac 也是"any token works"**（OMLX 忽略鉴权，Open Notebook 统一用 openai_compatible + dummy）——
  `api_key: dummy` 可留在 git，与 DGX 同理。
- **via LiteLLM 加** fallback 链相对旧网关是净收益：DGX 挂了自动切 Mac，而不是 client 手动换 base_url。
- **不做的事**：不把 Mac 的 embedding/STT/TTS/rerank 接进网关（§范围见 §3 决策 7）——那些仍由
  Open Notebook 直连 Mac，网关只管对话/生成两个 chat 模型。
- **RTT 语义差异**：Mac 在境内、延迟低，但**笔记本无 SLA**（电池/合盖会掉）；DGX 跨境但常驻。
  fallback 语义取「DGX 主 + Mac 兜底」，不是双向均衡——见 §3 决策 6。

### 1.4 关键事实（2026-08-01 已核实）

- LiteLLM 官方仓库自述 "Rust core with Python SDK"；`litellm-rust/crates/ai-gateway` 目前**只做 realtime
  WebSocket**（`/v1/realtime`），chat completions / responses / keys / 配置仍全在 Python proxy。
- 官方镜像 `litellm/litellm` 仍是 Python（Dockerfile 用 uv 建 venv；Rust 仅作 PyO3 bridge 构建依赖）。
- 当前 proxy 的 DB **只支持 Postgres**（`schema.prisma` 钉 `provider="postgresql"`，`sqlite://` 被显式拒绝）
  —— 虚拟 key/spend 必须有一个 Postgres。
- proxy 启动时自动跑 Prisma migration（`DATABASE_URL` 已设即生效）。
- 支持 `/v1/responses`（Codex `wire_api=responses` 需要的路径）。
- `general_settings.master_key`（或 env `LITELLM_MASTER_KEY`）语义 = "require a key for all calls to proxy"，
  即默认强制 key 鉴权（un-keyed → 401），无需额外开关。

## 2. 目标架构

```text
Codex (wire_api=responses) / 任意 OpenAI 兼容 client
        │  Authorization: Bearer sk-…（master key 或虚拟 key）
        ▼
llm.meirong.dev
  └─ Cloudflare DNS CNAME（external-dns，hostname 不变）
  └─ Cloudflare Tunnel（*.meirong.dev 通配，不变）
  └─ Cilium Gateway homelab-gateway（不变）
  └─ HTTPRoute litellm（单条 catch-all `/` → litellm:4000）
        ▼
LiteLLM proxy（litellm ns, v1.94.1, config.yaml 在 git）
  ├─ /v1/chat/completions, /v1/responses … → key 鉴权（master/虚拟 key）
  ├─ /ui（admin UI）→ LiteLLM 自带登录（UI_USERNAME/UI_PASSWORD，Vault→ESO）
  └─ keys/spend → PostgreSQL litellm-pg（homelab local-path PVC）
        ▼  fallback 链（DGX 主 → Mac 兜底）
  主: DGX Spark vLLM http://100.97.87.120:8000/v1 （deepseek-v4-flash, 1M ctx）
  兜底: MacPro M2 OMLX http://100.89.15.120:8000/v1 （Qwen3.6-35B, 262k ctx）
```

### 组件清单

| 组件 | 变化 | 说明 |
|------|------|------|
| `litellm` Deployment + Service | 新增 | `litellm/litellm@sha256:29b7…`（v1.94.1 amd64），端口 4000；config.yaml 含 DGX + Mac 双上游 fallback（见 Task 2 config） |
| `litellm-pg`（Postgres 17）| 新增 | 单副本、local-path PVC `litellm-pg-data-local`（2Gi） |
| `litellm` HTTPRoute | 新增 | `llm.meirong.dev` catch-all → `litellm:4000` |
| oauth2-proxy + 旧的 oauth2-proxy client（ZITADEL） | **移除** | LiteLLM 管理面自带认证，不再需要（见 §3 决策） |
| 旧网关 App / namespace / PVC | **移除** | 随旧网关 App 删除级联清理（不设计回退） |
| 备份 | 改 | homelab restic 脚本加 `pg_dump litellm`；删旧网关 PVC 模式 |
| SLO | 改 | 旧网关的 availability → `litellm-availability` |
| 消费方 | 改 | `~/.zshrc` / `~/.codex` 的 key 与命名；可选加 `codex-mac` profile 直指 Mac 兜底模型 |

## 3. 关键决策

1. **砍掉 oauth2-proxy，管理面用 LiteLLM 自带登录**。旧网关需要 oauth2-proxy 的唯一原因是它的 OSS 管理面
   **没有鉴权**；LiteLLM 管理面自带 `UI_USERNAME/UI_PASSWORD` 登录（凭据进 Vault→ESO）。这样：
   - 少一个 Deployment、少一个 ZITADEL OIDC client、少一次"ZITADEL 登录后再被 LiteLLM 再要一次密码"的双重登录；
   - 仍符合 security.md 的既定矩阵"每个服务要么公开、要么原生 ZITADEL OIDC、**要么自带认证**"。
   - 代价：admin UI 由强口令（Vault 随机生成）守护而非 SSO。单用户 + CF WAF 在前的威胁模型下可接受。
   - 备选（不采纳，写明理由）：保留 oauth2-proxy 复用旧的 oauth2-proxy client —— 双重登录且多一组维护面。
2. **Postgres 放 homelab 本集群**（`litellm` 命名空间内），不复用 oracle 的 CNPG：
   - 网关与密钥库同故障域、同 restic 备份拓扑；oracle 故障不影响网关；
   - 复刻仓库既有"纯 postgres Deployment + local-path"模式（ZITADEL 迁移时 oracle 侧就是这么做的）。
3. **hostname `llm.meirong.dev` 不变**：external-dns owner 随 HTTPRoute 自动从旧网关变更为
   `httproute/litellm/litellm`（`upsert-only`，无手工 DNS）。
4. **镜像按 digest 钉死**（仓库惯例）：`litellm/litellm:v1.94.1` 与 `postgres:17-alpine`（amd64 digest，见 §5）。
5. **model 名保留别名 `custom_dgx/deepseek-v4-flash`**：消费方（Codex profile）的 model 字段零改动，只换 key。
6. **双自托管来源 fallback：DGX 主 + Mac 兜底**（2026-08 补，替代原"双 DGX fallback"设想）。在
   config.yaml 里给无前缀 `deepseek-v4-flash` 声明**主上游 DGX + `fallbacks: ["mac/qwen3.6-35b"]`**，
   用 LiteLLM 原生 fallback 承接 DGX 不可达时自动切 Mac（Mac 也作为独立 `mac/qwen3.6-35b` 模型，
   供想绕开 fallback 的消费方直接指名）。理由：
   - 与 Open Notebook 已实证的接线一致（DGX 主、Mac 兜底），零新网络层；
   - DGX 是跨境共享、常驻、但不可控（他人机器、无告警）；Mac 在境内低延迟但**笔记本无 SLA**
     （电池/合盖/负载可能掉）。两源互不能全信，互为兜底是最优编排。
   - round-robin 权重：主写死 DGX 优先，**不做双向均衡**（Mac 是笔记本，不该平摊生产性对话流量）。
7. **网关只接对话/生成模型，不接 Mac 的 embedding/STT/TTS/rerank**（2026-08 补）。那些多模态模型仍由
   Open Notebook 直连 Mac（见 §1.3）；网关的单一职责是"一个 OpenAI 兼容入口 + key/spend + DGX/Mac
   chat fallback"。理由：embedding/音频有各自的调用方（Open Notebook）与语义（批任务、高延迟），
   塞进网关只会放大 `llm.meirong.dev` 的故障面，收益为零。今后确有 RAG 消费方需要统一 embedding 面时再扩。

## 4. 不做的事

- **不做回退设计**：旧网关无真实使用，旧网关 App/ns/PVC 直接删除。
- **不接入 Rust ai-gateway**：当前只支持 `/v1/realtime`，与 chat/responses 无关。
- **不把 Mac 的多模态模型接进网关**：embedding/STT/TTS/rerank 仍由 Open Notebook 直连 Mac（§3 决策 7）。
- **不新增 Prometheus 抓取**：沿用 envoy L7 SLO；LiteLLM `/metrics` 留作后续增强。
- **不动 Cloudflare**：无 CF AI Gateway 资源，隧道/DNS 走既有 external-dns。

## 5. 前置准备（执行前必读）

- 执行目录：仓库根 `cd /Users/matthew/projects/homelab`；集群 context `k3s-homelab`。
- 已核实的镜像 digest（amd64/linux）：
  - `litellm/litellm@sha256:29b7f41dd84601550354b98a8e7c767256a18300ad20a5821fbb652ec0a3ea93`（tag `v1.94.1`，2026-07-30 推送）
  - `postgres:17-alpine@sha256:af194ccf3e2d7fe367012c7b88ce8b816c5c889b18a5b316799a1f0d7eac746a`
- 升版路径：改 `image:` 的 digest + 注释里的 tag，`git push` 即可（ArgoCD 3 分钟轮询）。**不要**追 `main-stable`。

---

## Task 1 — Vault 密钥 + 上游预检

**目的**：LiteLLM 的所有密钥真相源进 Vault；先确认**两个**上游可用——DGX vLLM（含 `/v1/responses`）与 Mac OMLX——再动手。

- [ ] **Step 1: 确认 DGX vLLM 上游可达且支持 responses**

```bash
curl -s -m 10 http://100.97.87.120:8000/v1/models
# 期望：返回列表含 deepseek-v4-flash
curl -s -o /dev/null -w '%{http_code}\n' -m 30 -X POST http://100.97.87.120:8000/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4-flash","input":"hi","max_output_tokens":1}'
# 期望：200。若 404/501（vLLM 未开 responses），把 Codex profile 改 wire_api="chat"（见 Task 5 备选）。
```

（本沙箱实测连不通 DGX —— tailnet/时段问题，执行前以本机/集群内重试为准。）

- [ ] **Step 1b: 确认 Mac OMLX 上游可达（第二个来源）**

```bash
curl -s -m 10 http://100.89.15.120:8000/v1/models
# 期望：列表含 mlx-community__Qwen3.6-35B-A3B-nvfp4（若没有：模型未加载，笔记本按需换入，
#       或 OMLX 进程假死 —— 重启方式见 runbooks/open-notebook-ingest.md）
curl -s -o /dev/null -w '%{http_code}\n' -m 60 -X POST http://100.89.15.120:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community__Qwen3.6-35B-A3B-nvfp4","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
# 期望：200 + 真补全（笔记本 35B 首 token 可能 30s+，给足超时）
```

> ⚠️ 两个上游都必须在同一次执行里确认，因为它们是一个 fallback 链的两端——单测一个"活"，链的另一半可能
> 已长期不可用而不自知（Mac 尤其：笔记本，无告警，掉线是常事）。

- [ ] **Step 2: 生成并写入 Vault 密钥**

```bash
# 随机口令（UI 强口令；master key 手工生成 sk- 前缀随机串）
openssl rand -hex 24    # → 用作 ui_password
openssl rand -hex 24    # → 用作 db_password
export LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24)"

vault kv put secret/homelab/litellm \
  master_key="$LITELLM_MASTER_KEY" \
  ui_username=matthew \
  ui_password=<上面第一个 hex>

vault kv put secret/homelab/litellm-db \
  db_password=<上面第二个 hex> \
  database_url="postgresql://litellm:<上面第二个 hex>@litellm-pg.litellm.svc:5432/litellm"
```

> ⚠️ `database_url` 里的密码要 percent-encode（无特殊字符时 hex 安全）。Vault 写入后**本地不落盘**，
> master key 记住（或暂存到密码管理器），因为它就是管理/生成虚拟 key 的凭据。

- [ ] **Step 3: 记录当前消费方取值（备查）**

```bash
rg -n "LITELLM_VK|codex-dgx" ~/.zshrc
cat ~/.codex/litellm.config.toml
```
期望：`LITELLM_VK=sk-…`；profile model `custom_dgx/deepseek-v4-flash`、`base_url https://llm.meirong.dev/v1`。

---

## Task 2 — 新增 `k8s/helm/manifests/litellm/` 清单

**Files（全部新建）：**
- Create: `k8s/helm/manifests/litellm/litellm.yaml`（ConfigMap + Deployment + Service）
- Create: `k8s/helm/manifests/litellm/litellm-pg.yaml`（PVC + Deployment + Service）
- Create: `k8s/helm/manifests/litellm/externalsecrets.yaml`（2 个 ExternalSecret）
- Create: `k8s/helm/manifests/litellm/route.yaml`（HTTPRoute）

> HTTPRoute 与 Service 同命名空间 → 无需 ReferenceGrant（旧网关那份是多余的）。

- [ ] **Step 1: `litellm.yaml` — proxy（config.yaml 进 git）**

```yaml
# LiteLLM — self-hosted LLM gateway (homelab), replaces legacy gateway (2026-08-01).
#
# Public surface: llm.meirong.dev (Cloudflare Tunnel → Cilium Gateway → HTTPRoute).
# Auth model (旧网关的 oauth2-proxy 已砍掉 — LiteLLM 管理面自带认证):
#   - inference (/v1/*, /openai, /anthropic, /genai): master key + virtual keys,
#     Authorization: Bearer sk-…  (LITELLM_MASTER_KEY 已设 ⇒ 默认强制 key 鉴权)
#   - admin UI (/ui): LiteLLM 自带登录 (UI_USERNAME/UI_PASSWORD, Vault→ESO)
# Config: config.yaml in git (model_list); keys/spend live in Postgres (litellm-pg).
# 升版：改 image digest + 注释 tag → git push。不要追 main-stable。
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: litellm
data:
  # ⚠️ api_base 必须带 /v1 后缀 —— LiteLLM 不会像旧网关那样自动补。
  # api_key: dummy 不是机密（DGX vLLM 与 Mac OMLX 都忽略鉴权，"any token works"），因此可留在 git。
  # 强制 key 鉴权由 env LITELLM_MASTER_KEY 实现（general_settings.master_key 语义=require a key for all calls）。
  config.yaml: |
    model_list:
      # ── DGX（主，向后兼容：custom_dgx/ 前缀原名不变）──
      - model_name: custom_dgx/deepseek-v4-flash
        litellm_params:
          model: openai/deepseek-v4-flash
          api_base: http://100.97.87.120:8000/v1
          api_key: dummy
      # ── 无前缀别名 deepseek-v4-flash：DGX 主 + Mac 兜底（fallbacks 键 = 严格的"主→兜底"，非轮询）──
      - model_name: deepseek-v4-flash
        litellm_params:
          model: openai/deepseek-v4-flash
          api_base: http://100.97.87.120:8000/v1
          api_key: dummy
          fallbacks: ["mac/qwen3.6-35b"]
      # ── Mac 兜底（也是独立可用的实际模型）──
      - model_name: mac/qwen3.6-35b
        litellm_params:
          model: openai/mlx-community__Qwen3.6-35B-A3B-nvfp4
          api_base: http://100.89.15.120:8000/v1
          api_key: dummy
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: litellm
  labels:
    app: litellm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
    spec:
      containers:
        - name: litellm
          # litellm/litellm:v1.94.1 @ 2026-08-01（官方 Python proxy；Rust 网关当前仅 /v1/realtime）
          image: litellm/litellm@sha256:29b7f41dd84601550354b98a8e7c767256a18300ad20a5821fbb652ec0a3ea93
          args: ["--config", "/app/config.yaml", "--port", "4000"]
          ports:
            - containerPort: 4000
              name: http
          env:
            - name: LITELLM_MASTER_KEY
              valueFrom:
                secretKeyRef: { name: litellm-secret, key: master-key }
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef: { name: litellm-db-secret, key: database-url }
            - name: UI_USERNAME
              valueFrom:
                secretKeyRef: { name: litellm-secret, key: ui-username }
            - name: UI_PASSWORD
              valueFrom:
                secretKeyRef: { name: litellm-secret, key: ui-password }
            # DB 迁移失败即退出（fail-closed），避免无表静默跑
            - name: ENFORCE_PRISMA_MIGRATION_CHECK
              value: "true"
          volumeMounts:
            - name: config
              mountPath: /app/config.yaml
              subPath: config.yaml
              readOnly: true
          resources:
            requests: { cpu: 200m, memory: 384Mi }
            limits: { cpu: "1", memory: 1Gi }
          livenessProbe:
            httpGet:
              path: /health/liveness
              port: 4000
            initialDelaySeconds: 30
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /health/readiness
              port: 4000
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: litellm-config
---
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: litellm
spec:
  type: ClusterIP
  selector:
    app: litellm
  ports:
    - port: 4000
      targetPort: 4000
      name: http
```

- [ ] **Step 2: `litellm-pg.yaml` — Postgres 17（local-path）**

```yaml
# LiteLLM 的 keys/spend DB。单副本 + RWO PVC → Recreate。
# homelab local-path（全集群唯一 SC，restic 唯一安全网 —— 见 CONVENTIONS）。
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: litellm-pg-data-local
  namespace: litellm
  annotations:
    # DB 是运行时数据，禁止 ArgoCD prune 级联删除
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm-pg
  namespace: litellm
  labels:
    app: litellm-pg
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm-pg
  strategy:
    type: Recreate # 单 RWO PVC
  template:
    metadata:
      labels:
        app: litellm-pg
    spec:
      containers:
        - name: postgres
          # postgres:17-alpine @ 2026-08-01（backup 容器 alpine:3.22 自带 pg17 客户端，版本匹配）
          image: postgres:17-alpine@sha256:af194ccf3e2d7fe367012c7b88ce8b816c5c889b18a5b316799a1f0d7eac746a
          ports:
            - containerPort: 5432
              name: postgres
          env:
            - name: POSTGRES_DB
              value: litellm
            - name: POSTGRES_USER
              value: litellm
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: litellm-db-secret, key: postgres-password }
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { cpu: 500m, memory: 1Gi }
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "litellm", "-d", "litellm"]
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: litellm-pg-data-local
---
apiVersion: v1
kind: Service
metadata:
  name: litellm-pg
  namespace: litellm
spec:
  type: ClusterIP
  selector:
    app: litellm-pg
  ports:
    - port: 5432
      targetPort: 5432
      name: postgres
```

- [ ] **Step 3: `externalsecrets.yaml` — Vault → K8s Secret**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: litellm-secret
  namespace: litellm
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: litellm-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: master-key
      remoteRef: { key: secret/homelab/litellm, property: master_key }
    - secretKey: ui-username
      remoteRef: { key: secret/homelab/litellm, property: ui_username }
    - secretKey: ui-password
      remoteRef: { key: secret/homelab/litellm, property: ui_password }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: litellm-db-secret
  namespace: litellm
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: litellm-db-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: database-url
      remoteRef: { key: secret/homelab/litellm-db, property: database_url }
    - secretKey: postgres-password
      remoteRef: { key: secret/homelab/litellm-db, property: db_password }
```

- [ ] **Step 4: `route.yaml` — HTTPRoute（单条 catch-all）**

```yaml
# llm.meirong.dev → litellm:4000（inference + /ui 同一后端；鉴权各自在 LiteLLM 内完成）。
# 同命名空间引用 Service，无需 ReferenceGrant。
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: litellm
  namespace: litellm
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: homelab-gateway
      namespace: kube-system
      port: 80
  hostnames:
    - "llm.meirong.dev"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: litellm
          port: 4000
          weight: 1
```

---

## Task 3 — ArgoCD 换血：删旧网关、注册 litellm（原子提交）

**Files：**
- Create: `argocd/applications/litellm.yaml`
- Delete: 被删除的旧网关 App 清单
- Delete: 被删除的旧网关 manifest 目录（整目录）

> 两 App 同主机名，不能共存，必须**一个提交**完成"加 litellm、删旧网关"（ArgoCD 3 分钟轮询，同一 sync 内收敛；
> 中间有极短空窗，网关本就无真实流量，可接受）。

- [ ] **Step 1: `argocd/applications/litellm.yaml`**（镜像旧网关 App 清单的骨架）

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: litellm
  namespace: argocd
  finalizers:
    - resources-finalizer.argoproj.io
spec:
  project: homelab
  source:
    repoURL: https://github.com/meirongdev/homelab
    targetRevision: main
    path: k8s/helm/manifests/litellm
  destination:
    server: https://kubernetes.default.svc
    namespace: litellm
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: 删除旧网关的相关资源**（App 清单、manifest 目录、Vault secret、ZITADEL client、脚本）

```bash
# 删除旧网关 App 清单与 manifest 目录
```

- [ ] **Step 3: 提交并推送**

```bash
git add argocd/applications/litellm.yaml
git commit -m "feat: replace legacy LLM gateway with litellm (llm.meirong.dev)"
git push
```

- [ ] **Step 4: 等 ArgoCD 收敛并核对**（3 分钟轮询；必要时 `just argocd-sync`）

```bash
kubectl --context k3s-homelab -n argocd get app | rg -i "litellm"
# 期望：litellm Synced/Healthy；旧网关不再存在
kubectl --context k3s-homelab get ns litellm
# 期望：litellm ns 存在且旧网关 ns 已随 App 删除级联清理（含旧网关 PVC —— 不回退，符合预期）
kubectl --context k3s-homelab -n litellm get pods,pvc
# 期望：litellm Running + Ready、litellm-pg Running/Ready、litellm-pg-data-local Bound
```

> ⚠️ 确认 litellm pod 真正 Ready 再进下一步（首次启动会跑 Prisma migration，几十秒）。

---

## Task 4 — 端到端验证

**目的**：证明"入口可达 + key 门生效 + 真推理通 + responses 通 + **双上游各自可真推 + fallback 自动切换** + UI 可登"。

- [ ] **Step 1: 代理内网冒烟（绕过公网）**

```bash
kubectl --context k3s-homelab -n litellm port-forward svc/litellm 4000:4000 &
curl -s localhost:4000/health/readiness        # 期望 200 OK
MASTER_KEY=$(vault kv get -field=master_key secret/homelab/litellm)
curl -s localhost:4000/v1/models -H "Authorization: Bearer $MASTER_KEY"
# 期望：data 含 deepseek-v4-flash、custom_dgx/deepseek-v4-flash、mac/qwen3.6-35b（三个都该在）
```

- [ ] **Step 2: 生成一个虚拟 key**（覆盖两个源头模型）

```bash
curl -s -X POST localhost:4000/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"models":["custom_dgx/deepseek-v4-flash","deepseek-v4-flash","mac/qwen3.6-35b"],"max_budget":0}'
# 记下返回的 "key": "sk-…" → 后续 Task 5 写入消费方
```

- [ ] **Step 3: key 门验证（对照旧网关当时的 401/200 验收）**

```bash
# 无 key → 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"custom_dgx/deepseek-v4-flash","messages":[{"role":"user","content":"hi"}]}'
# 期望：401

# 虚拟 key → 200 且是真推理（走 pod→tailnet→100.97.87.120）
curl -s -X POST localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $VK" -H 'Content-Type: application/json' \
  -d '{"model":"custom_dgx/deepseek-v4-flash","messages":[{"role":"user","content":"say hi"}],"max_tokens":8}'
# 期望：200 + choices[0].message.content 非空
```

- [ ] **Step 4: `/v1/responses`（Codex 路径）**

```bash
curl -s -X POST localhost:4000/v1/responses \
  -H "Authorization: Bearer $VK" -H 'Content-Type: application/json' \
  -d '{"model":"custom_dgx/deepseek-v4-flash","input":"say hi","max_output_tokens":8}'
# 期望：200 + output 数组
```

- [ ] **Step 4b: Mac 上游独立可用（直指 `mac/qwen3.6-35b`，绕开 fallback）**

```bash
# 直指 Mac（走 pod→tailnet→100.89.15.120）；这是"第二个来源"能独立推理的证明
curl -s -X POST localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $VK" -H 'Content-Type: application/json' \
  -d '{"model":"mac/qwen3.6-35b","messages":[{"role":"user","content":"say hi"}],"max_tokens":8}'
# 期望：200 + choices[0].message.content 非空（笔记本 35B 首 token 可能 30s+，给足超时）
```

- [ ] **Step 4c: fallback 自动切换（DGX → Mac）**

```bash
# 临时把 config.yaml 里 DGX api_base 改成一个不存在的地址（如 http://10.255.255.254:1/v1），
# git push 让 ArgoCD 重载；再打逻辑名 deepseek-v4-flash（带 fallbacks 的那个）
curl -s -X POST localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $VK" -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"say hi"}],"max_tokens":8}'
# 期望：仍 200 + 内容来自 Mac（DGX 不可达 → 自动切到 fallback 上游）
# ⚠️ 验完把 api_base 改回 100.97.87.120 再 push（别把主上游留在坏地址上）
```

- [ ] **Step 5: 公网入口 + UI**

```bash
curl -sI https://llm.meirong.dev/v1/models -H "Authorization: Bearer $VK"
# 期望：200（CF 隧道 + external-dns owner 已切 httproute/litellm/litellm）
curl -s -o /dev/null -w '%{http_code}\n' https://llm.meirong.dev/ui
# 期望：200（LiteLLM 登录页）；浏览器验证 UI_USERNAME/UI_PASSWORD 可登录并生成 key
```

> 若公网域名 502/被 WAF 拦：先查 `kubectl -n kube-system get httproute -A` 与 external-dns 日志
> （`kubectl -n external-dns logs deploy/external-dns --tail=50`）。UI 登录路径若命中 CF WAF 限流规则
> （`/login,/oauth2,/signin`），属预期——人机登录频率低，不处理。

---

## Task 5 — 消费方更新（MacBook 本机，不进 repo）

- [ ] **Step 1: `~/.zshrc`**：把旧网关的 virtual key 换成 `LITELLM_VK`（值 = Task 4 的虚拟 key），注释同步改名

```bash
# 旧：export LITELLM_VK="sk-…"
# 新：
export LITELLM_VK="sk-<Task4 生成的虚拟 key>"
alias codex-dgx='codex --profile litellm'
```

- [ ] **Step 2: 消费方 config 沿用接替前的 litellm 命名**（`~/.codex/litellm.config.toml`）

```bash
# 旧网关 config 在接替时沿用 litellm 命名，无需再移动
ls -l ~/.codex/litellm.config.toml
```

编辑 `~/.codex/litellm.config.toml`：

```toml
# `codex --profile litellm` overlay — LiteLLM (homelab) → DGX deepseek-v4-flash.
model = "custom_dgx/deepseek-v4-flash"      # model 名不变（config.yaml 保留了该别名）
model_provider = "litellm"
model_context_window = 1000000
model_max_output_tokens = 32768
```

以及 `~/.codex/config.toml` 的 provider 块：`base_url`/`wire_api` 不变，把 `env_key` 设为
`"LITELLM_VK"`、`name = "LiteLLM (homelab → DGX)"`。

> 备选（仅当 Task 1 确认 vLLM 不支持 `/v1/responses`）：把该 provider 的 `wire_api` 改为 `"chat"`，
> `base_url` 保持 `https://llm.meirong.dev/v1`，其余不变。

- [ ] **Step 3: 验证消费方**

```bash
source ~/.zshrc
codex-dgx exec "reply with exactly: ok"   # 或 codex --profile litellm 打开后发一条消息
```

- [ ] **Step 4（可选）: 加一个直指 Mac 的 profile —— `codex-mac`**

想"明确用 Mac（绕开 DGX 优先的 fallback）"时，加第二个 overlay（不覆盖默认 `codex-dgx`）：

```toml
# ~/.codex/mac.config.toml — `codex-mac` → LiteLLM → Mac Qwen3.6-35B（兜底模型，非默认）
model = "mac/qwen3.6-35b"
model_provider = "litellm"
model_context_window = 262144
model_max_output_tokens = 32768
```

```bash
# ~/.zshrc
alias codex-mac='codex --profile mac'
```

> ⚠️ Mac Qwen3.6-35B 是**非默认**的兜底位：Codex 日常工作继续走 `codex-dgx`（DGX 主），
> 只有明确对比/避让 DGX 时才用 `codex-mac`。别把个人默认切到 Mac——笔记本无 SLA，掉线时
> 反而把"有网关兜底"这个优势丢掉。

---

## Task 6 — 备份接入（homelab restic）

**Files：**
- Modify: `backup/overlays/homelab/backup-script.yaml`
- Modify: `backup/overlays/homelab/external-secret.yaml`

> ⚠️ Postgres 数据目录**不能**像 sqlite 那样原样拷贝（无 WAL 自恢复）→ 必须 `pg_dump`。
> backup 容器已装 `postgresql-client`（alpine:3.22 = pg17 客户端，与服务端版本匹配）。

- [ ] **Step 1: `backup/overlays/homelab/external-secret.yaml`** 追加 DB 密码

```yaml
  # litellm DB dump 凭据（Task 1 写入 secret/homelab/litellm-db）
  - secretKey: LITELLM_DB_PASSWORD
    remoteRef: { key: secret/homelab/litellm-db, property: db_password }
```

- [ ] **Step 2: `backup/overlays/homelab/backup-script.yaml`** 两处改动

(a) sqlite 拷贝循环里删掉旧网关 PVC：

```sh
for pat in calibre-web-automated-config; do
```

(b) 在 `# --- 2) sqlite/config PVC` 段之后、restic backup 之前插入：

```sh
# --- 2.5) litellm Postgres（pg_dump，一致性 dump；旧网关 PVC 已随旧网关下线）---
echo "[backup] pg_dump litellm DB..."
export PGPASSWORD="$(cat /creds/LITELLM_DB_PASSWORD)"
pg_dump -h litellm-pg.litellm.svc -U litellm -d litellm -Fc -f /work/litellm.dump
echo "[backup]   litellm.dump = $(wc -c < /work/litellm.dump) bytes"
```

- [ ] **Step 3: 提交 + 手动跑一次验证**

```bash
git add backup/overlays/homelab
git commit -m "chore(backup): pg_dump litellm db; drop retired legacy gateway pvc"
git push
cd k8s/helm && just backup-run
kubectl --context k3s-homelab -n backup logs -l app=restic-backup --tail=30
# 期望日志： [backup] pg_dump litellm DB... litellm.dump = <N> bytes 且 restic backup 成功
```

---

## Task 7 — SLO / 告警

**Files：**
- Modify: `k8s/helm/manifests/monitoring/slos.yaml`

- [ ] **Step 1: 把旧网关的 availability 块整体替换为**

```yaml
    - name: "litellm-availability"
      objective: 99.0
      description: "LiteLLM (llm.meirong.dev) 入口可用性，error=5xx"
      sli:
        events:
          errorQuery: sum(rate(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~".*/litellm_litellm_.*", envoy_response_code_class="5"}[{{.window}}])) OR on() vector(0)
          totalQuery: sum(rate(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~".*/litellm_litellm_.*"}[{{.window}}]))
      alerting:
        name: LitellmGatewayHighErrorRate
        labels: { slo_service: litellm }
        pageAlert:
          labels: { severity: critical }
        ticketAlert:
          labels: { severity: warning }
```

（命名空间/service 名均为 `litellm` → envoy cluster 名 `*/litellm_litellm_*`；已无 oauth2-proxy 后端，删掉对应描述。）

- [ ] **Step 2: 提交并核对告警规则生成**

```bash
git add k8s/helm/manifests/monitoring/slos.yaml
git commit -m "chore(observability): litellm SLO replaces legacy gateway"
git push
kubectl --context k3s-homelab -n monitoring get prometheusrules | rg -i litellm
# 期望：Sloth 生成的规则带 litellm-availability
```

---

## Task 8 — PSA + justfile

**Files：**
- Modify: `k8s/helm/justfile`

- [ ] **Step 1: 把 `psa_baseline_ns` 里的旧网关换成 `litellm`**

```justfile
psa_baseline_ns := "default vault litellm personal-services cloudflare external-secrets argocd kyverno"
```

- [ ] **Step 2: 打标签（幂等，刻意不走 ArgoCD）**

```bash
cd k8s/helm && just harden-psa
kubectl --context k3s-homelab get ns litellm -L pod-security.kubernetes.io/enforce
# 期望：litellm  enforce=baseline
```

- [ ] **Step 3: 提交**

```bash
git add k8s/helm/justfile
git commit -m "chore(security): psa baseline litellm ns"
git push
```

---

## Task 9 — 清理旧网关残留（ZITADEL / Vault / 脚本）

> 旧网关无真实使用 → 直接清，不回退。顺序：先让 litellm 全绿（Task 4 过）再清。

- [ ] **Step 1: 删旧的 oauth2-proxy client（ZITADEL）**（console：Projects → Homelab → Applications →
  旧 client → Delete；redirect 指向 `llm.meirong.dev/oauth2/callback`，LiteLLM 不再需要）

- [ ] **Step 2: 删 Vault 旧 secret 与脚本**：删除旧网关的相关资源（Vault secret、ZITADEL client、脚本）

```bash
# 删除旧网关的 Vault secret 与 OAuth 脚本
```

- [ ] **Step 3: 更新 `zitadel/scripts/configure-github-idp.sh` 里对旧网关节点的过时注释**（LiteLLM 不走 OIDC，
  GitHub IdP 继续服务于 Grafana/ArgoCD 等其它 OIDC app；注释改为泛指）

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "chore: remove legacy gateway oauth2-proxy leftovers (zitadel client, vault secret, script)"
git push
```

---

## Task 10 — 文档与索引

**Files：** 见各 Step。

- [ ] **Step 1: 新增决策记录 `docs/decisions/litellm-llm-gateway.md`**（R3：日期/状态/Context/Decision/Consequences）

```markdown
# LLM 网关从旧网关迁移到 LiteLLM

> 日期: 2026-08-01
> 状态: ✅ 已实施
> 关联: `docs/plans/apps/2026-08-01-litellm-gateway-migration.md`

## Context
homelab LLM 网关（llm.meirong.dev）原为旧网关。其配置（enforce 开关/路由/虚拟 key）存 PVC SQLite、
管理面无鉴权需 oauth2-proxy+ZITADEL 配套，且旧网关实际未被使用。用户考虑换 LiteLLM 的契机是
"Rust 重写"，但核实：截至 2026-08-01 Rust 网关只覆盖 /v1/realtime，生产 proxy 仍是 Python。

## Decision
- 用 LiteLLM proxy（v1.94.1，官方 Python proxy）替换旧网关，hostname 不变。
- 配置进 git（config.yaml），keys/spend 落同集群 Postgres（litellm-pg, local-path）。
- 砍掉 oauth2-proxy/ZITADEL client：LiteLLM 管理面自带认证（UI_USERNAME/UI_PASSWORD, Vault→ESO），
  符合 security.md「自带认证」矩阵。备选（保留 oauth2-proxy 复用旧的 oauth2-proxy client）因双重登录+维护面被否决。
- 不接入 Rust ai-gateway（仅 /v1/realtime）。

## Consequences
- +一个 Postgres 运行时依赖（单副本 local-path，restic pg_dump 兜底）。
- admin UI 由强口令而非 SSO 守护；单用户 + CF WAF 威胁模型下可接受。
- 双自托管来源 fallback（DGX 主 + Mac Qwen3.6-35B 兜底，ROADMAP 原"双 DGX"升级为"双来源"）改由
  LiteLLM 原生 fallback 承载；Mac 的多模态模型（embedding/STT/TTS/rerank）不进网关，仍由 Open Notebook 直连。
```

- [ ] **Step 2: `docs/CONVENTIONS.md` 四处更新**
  - `§ Services` 表（约 L318）：`| LiteLLM (LLM gateway) | homelab | litellm | llm.meirong.dev (inference API + 自带认证 admin UI) |`
  - `§ GitOps` App 列表（约 L190）：旧网关行 → `litellm` App → `manifests/litellm/`（LLM gateway + Postgres）
  - `§ Identity`（约 L170）：把 "旧网关 example of this pattern" 改为说明 LiteLLM 管理面**自带认证**，
    不再需要 oauth2-proxy 模式（该模式仍适用于其它无鉴权 admin 面）；GitHub IdP 注释里的旧网关一并改。
  - `§ Storage` PVC 清单（约 L223）：旧网关 PVC → `litellm-pg-data-local`（仍 11 个或按实数列）
  - `§ SLO`（约 L281）：括号列表 `calibre-web/grafana/argocd/vault/旧网关` → `…/vault/litellm`，共 6 个服务不变

- [ ] **Step 3: `docs/reference/security.md` 两处**
  - `§ 3 身份` 原生 OIDC apps 列表：去掉 `旧网关(admin)`
  - `§ 5.1 PSA` baseline 矩阵：旧网关 → `litellm`

- [ ] **Step 4: `docs/ROADMAP.md`**：第 4 行开放项里 `旧网关双机 fallback` → `LLM 网关双机 fallback（LiteLLM）`，
  链到本计划/决策

- [x] **Step 5: 归档旧网关 plan** —— **旧网关 plan 已于 2026-08-13 先期归档，2026-08-20 起该文件已彻底删除**。
  因为旧网关节是 2026-08-08 **独立退役**的（不等本计划落地），plan 却一直挂着
  「✅ 已上线、生产运行」的假状态，故提前按 R1 归档；随后按清理要求把归档文件整体删除，
  `archive/README.md` 的对应行一并移除。接替者见本计划与 [decisions/litellm-llm-gateway.md](../../decisions/litellm-llm-gateway.md)。

- [ ] **Step 6: `cloudflare/terraform/README.md`**：`LLM gateway` 段把旧网关描述改为 LiteLLM（hostname 与
  "tailnet 直连 100.x"的论证不变），链接指到本计划/决策

- [ ] **Step 7: 更新 plans 索引与计数**
  - `docs/plans/apps/README.md`：旧网关行**已于 2026-08-13 随 Step 5 删除**；
    本计划行已先期加入索引，执行完成后把该行状态从 📐 设计 改成 ✅ 已完成
  - `docs/plans/README.md`：apps 份数按实际改（2026-08-13 归档三份后为 9；`check-docs.py` 会核）

- [ ] **Step 8: 校验 + 提交**

```bash
python3 scripts/check-docs.py        # 期望无违规，exit 0
git add -A
git commit -m "docs: litellm gateway migration decision; archive legacy gateway plan"
git push
```

---

## Task 11 — 验收清单（全绿才算完成）

- [ ] `kubectl -n argocd get app`：`litellm` Healthy/Synced，无旧网关 App
- [ ] 旧网关 ns 不存在；`kubectl -n litellm get pvc` → `litellm-pg-data-local` Bound
- [ ] 无 key `POST /v1/chat/completions` → 401；虚拟 key → 200 真推理
- [ ] `/v1/responses`（Codex 路径）→ 200
- [ ] **双上游各自可真推**：`deepseek-v4-flash`（DGX）与 `mac/qwen3.6-35b`（Mac OMLX）的
      `POST /v1/chat/completions` 都 → 200 + 非空 content
- [ ] **fallback 切换实测**：DGX api_base 故意改错时，`deepseek-v4-flash` 仍 200 且内容来自 Mac；
      恢复 api_base 后回到 DGX
- [ ] `https://llm.meirong.dev/ui` → 200，UI_USERNAME/UI_PASSWORD 可登录并可建 key
- [ ] `codex-dgx`（`--profile litellm`）可用（可选：`codex-mac` 直指 Mac）
- [ ] 夜备日志含 `litellm.dump = <N> bytes`；restic snapshot 含该文件（`restic -r /storage/restic snapshots --latest`）
- [ ] SLO 规则 `litellm-availability` 生成；PSA `litellm` ns = baseline
- [ ] external-dns 记录 owner：`cname-llm.meirong.dev` → `…/resource=httproute/litellm/litellm`
- [ ] `python3 scripts/check-docs.py` exit 0；旧网关 plan 已清理、ZITADEL client/Vault secret/脚本已清
- [ ] 更新本计划文首状态为 `✅ 已完成`（完成即冻结，不再改）并同步 `docs/plans/apps/README.md` 状态

## 附：相关文件地图

| 动作 | 路径 |
|------|------|
| 新 App 清单 | `k8s/helm/manifests/litellm/{litellm,litellm-pg,externalsecrets,route}.yaml` |
| App 注册/删除 | `argocd/applications/`（litellm 注册，旧网关删除） |
| 备份 | `backup/overlays/homelab/{backup-script,external-secret}.yaml` |
| SLO | `k8s/helm/manifests/monitoring/slos.yaml` |
| PSA | `k8s/helm/justfile`（`psa_baseline_ns`） |
| 消费方 | `~/.zshrc`、`~/.codex/litellm.config.toml`、`~/.codex/config.toml` |
| 文档 | `docs/decisions/litellm-llm-gateway.md`、`docs/CONVENTIONS.md`、`docs/reference/security.md`、`docs/ROADMAP.md`、`docs/plans/{apps,archive}/README.md`、`cloudflare/terraform/README.md` |
