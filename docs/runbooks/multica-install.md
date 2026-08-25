# Runbook — Multica 安装与配置

> Last updated: 2026-08-25
>
> **触发条件**：首次部署 Multica，或 homelab 重建后恢复它、或把它迁到另一个集群。
> **成功判定**：五条同时成立 ——
> ① `curl -s https://multica.meirong.dev/api/config` 返回 `allow_signup:false` 且
> `workspace_creation_disabled:true`；② backend 日志首行是
> `EmailService: SMTP relay ...`（不是 `no email backend configured`）；
> ③ 登录时验证码到达邮箱，且 backend 日志里 **没有** `[DEV] Verification code`；
> ④ 服务端 `agent_runtime` 表有 `status=online` 的行；⑤ 夜备能 `pg_dump` 出非零字节。
> **回滚**：删 `argocd/applications/multica.yaml` 并 push（ArgoCD 会 prune 掉整套负载）。
> ☠️ **先 `pg_dump` 再回滚** —— multica 的 PVC 是 chart 生成的，仓库里没有 `Prune=false`
> 保护（步骤 3b 是手工补的、不在 git）。详见文末「退役」。
> **集群**：homelab · ns `personal-services` · chart
> `oci://ghcr.io/multica-ai/charts/multica`（本仓库唯一 OCI chart 源）

## 前置条件 —— 兼本文的适用范围

⚠️ **这是「在本 homelab 上重建 Multica」的手册，不是通用 k8s 安装指南。**
下面每项都是**既有平台能力**，本文默认它们已经在跑，不重复其安装步骤：

| 依赖 | 用在 | 缺了会怎样（多数不报错，只是静默不对） |
|------|------|--------------------------------------|
| Vault + ESO（`ClusterSecretStore/vault-backend`） | 步骤 1 · 3 | `vault` 命令无处可用；`ExternalSecret` CRD 不存在则清单同步直接失败 |
| ArgoCD（☠️ 控制面在 **oracle-k3s**，不在 homelab） | 步骤 2 · 3 | 没人消费 Application；且 `destination.server` 必须显式写 homelab，写错会把整套装到 oracle |
| Cilium Gateway API（`homelab-gateway` @ `kube-system`） | 步骤 4 | HTTPRoute 无控制器认领 —— **旧路由照常 200、新路由静默 503** |
| external-dns + Cloudflare Tunnel | 步骤 4 | 域名不会自动出现。本文全程不用手改 DNS，正是因为有它 |
| `local-path` StorageClass | 步骤 3 | 两个 PVC 永远 `Pending`（本仓库 NFS 已于 2026-07-11 退役） |
| ns `personal-services`（由 `personal-services` App 以 `CreateNamespace=true` 创建，PSA `baseline`） | 全程 | multica App 刻意是 `CreateNamespace=false`，ns 不存在则同步失败 |
| restic 夜备（homelab overlay） | 步骤 7 | `pg_dump` 段与 `MULTICA_DB_PASSWORD` 都在那边，漏配 = **静默不备份** |
| 一台可 SSH 的 macOS 机器 | 步骤 6 | 见该步的「从零开始还需要什么」 |

**若要装到别的集群**：上述能力得先有等价物，且**至少**这些值要换 —— 域名、Vault 路径
`secret/homelab/multica`、`destination.server`、ns、`affinity` 里的节点名、Gateway 名与其 ns。
本仓库**不维护**通用化版本（R1：runbook 只回答"出事了怎么办"）；要可移植的安装说明请看上游
chart 自己的文档。

## ☠️ 先理解这件事：Multica 是两半的

| 组件 | 内容 | 跑在哪 |
|------|------|--------|
| **service** | Next.js frontend + Go backend(API/WS) + Postgres 17 (pgvector) | homelab k3s |
| **daemon**（`multica computer`） | 探测本机 AI CLI、注册为 runtime、**实际执行任务** | M2 MacBook，**不在 k8s 里** |

daemon 只做 **outbound** 注册，不监听端口、不需要入站放行 —— 所以它在 NAT/Tailscale
后面完全没问题。它不进 k8s 的原因是：它需要一台装好并登录了 AI CLI 的真实机器。

⚠️ **daemon 离线时 service 端一切正常** —— 页面 200、Uptime Kuma 全绿、ArgoCD Healthy，
只是任务永远停在待执行。这是本服务最容易误判成「已经好了」的状态，验收必须查
`agent_runtime` 表（成功判定 ④）。

⚠️ **安全边界**（上游文档原话）：*"Tasks run with the full permissions of the user
running the daemon."* 本部署按既有约定跑在 M2 的登录用户 `matthew` 下 —— 这是
**明确接受的取舍**，代价是任务能读写该用户能读写的一切（含 `~/.ssh`、各 AI CLI 凭据）。
要收紧就改用专用 Unix 用户或 VM，见
[playbook 文件头](../../macbook/ansible/playbooks/multica-daemon.yaml)。

## 步骤 1 — 写 Vault（必须最先做）

```bash
export VAULT_ADDR=https://vault.meirong.dev
vault kv put secret/homelab/multica \
  jwt_secret="$(openssl rand -hex 32)" \
  postgres_password="$(openssl rand -hex 16)" \
  vcs_secret_key="$(openssl rand -base64 32)" \
  resend_api_key="" \
  smtp_host="smtp.gmail.com" \
  smtp_port="465" \
  smtp_username="<你的 Gmail 地址>" \
  smtp_password="<16 位应用专用密码>" \
  smtp_from_email="<同一个 Gmail 地址>" \
  smtp_ehlo_name="multica.meirong.dev"
```

**顺序不能颠：Vault 必须先于清单落地。** ESO 的 `data` 项引用 Vault 里不存在的
property 时，**整个 Secret 都不生成** —— 会连 `JWT_SECRET` 一起没掉，backend 直接起不来。

四个编码/取值约束，写错了都不会有明确报错：

- **`vcs_secret_key` 必须是 `-base64 32`（44 字符），不是 `-hex 32`。** 后端要求
  base64 解码后恰好 32 字节；hex 串只含合法 base64 字符，能解码但得 48 字节，
  于是失败 —— 而后端把**所有** LoadKey 错误都打成同一句
  `MULTICA_VCS_SECRET_KEY not set`，看着像 ESO 没注入。
- **`smtp_from_email` 必须等于 `smtp_username`。** Gmail 只接受认证账号本身（或已验证
  别名）当 From，所以这里写不了 `noreply@meirong.dev`；邮件是自己发给自己。
- **`smtp_ehlo_name` 必须显式给。** 默认 EHLO `localhost` 被严格 relay 拒，而代码兜底是
  `os.Hostname()` —— 在 pod 里那是 pod 名、不是 FQDN。
- `smtp_password` 是 **Gmail 应用专用密码**（`myaccount.google.com/apppasswords`，
  需先开 2FA），不是账号密码。⚠️ 它不是只能发信的：同一串密码也能走 IMAP/POP 读该
  邮箱全部邮件。更干净的做法是用一个专用发信 Gmail（泄露时是空邮箱）。

`resend_api_key` 留空即可 —— 后端投递优先级是 **SMTP → Resend → stdout**，SMTP 有值时
不会走到它。留着这个 key 只是为了让 ESO 的映射完整。

> 邮件为什么不用 Cloudflare：Email Sending 在 **Workers Free 档不可用**，
> 见 [decisions/multica-email-delivery.md](../decisions/multica-email-delivery.md)。

## 步骤 2 — 放开 AppProject 的 chart 源（**不由 GitOps 托管**）

`ghcr.io/multica-ai/charts` 必须在 `argocd/projects/homelab.yaml` 的 `sourceRepos` 里，
否则 Application 报 `application repo ... is not permitted in project 'homelab'`。

AppProject **不在 root App 的托管路径下**（root 的 path 是 `argocd/applications/`），
所以 **`git push` 不会让它生效**，必须手工 apply：

```bash
cd /Users/matthew/projects/homelab
kubectl --context oracle-k3s apply -f argocd/projects/homelab.yaml
```

⚠️ **OCI 源的写法与 HTTP repo 不同**：`repoURL` 与 `sourceRepos` 都写**不带 `oci://`
前缀**的裸地址；公开 registry 不需要注册 repository Secret。但本地用 `helm show values`
核对时**要**带前缀 —— 两者不一致，容易来回踩。细节见
[reference/argocd-app-patterns.md](../reference/argocd-app-patterns.md)。

## 步骤 3 — 清单文件

这些文件构成完整部署，全部已在仓库里；重建时确认存在即可：

| 文件 | 作用 |
|------|------|
| [`argocd/applications/multica.yaml`](../../argocd/applications/multica.yaml) | Application。`destination.server` **必须显式写** `https://100.94.186.7:6443`（控制面在 oracle，`kubernetes.default.svc` 指的是 oracle） |
| [`k8s/helm/values/multica.yaml`](../../k8s/helm/values/multica.yaml) | chart values。**资源数值以此文件为准**，不在本文档复制 |
| [`k8s/helm/manifests/personal-services/multica-secret.yaml`](../../k8s/helm/manifests/personal-services/multica-secret.yaml) | ESO：Vault → `multica-secrets` |
| [`k8s/helm/manifests/gateway/route-multica.yaml`](../../k8s/helm/manifests/gateway/route-multica.yaml) | HTTPRoute（写它即建 DNS，别动 `cloudflare/terraform`）。**两条规则**：`/` 走 `RequestRedirect` 跳 `/homelab/issues`（收掉上游 SaaS 营销页），其余给 frontend |
| [`backup/overlays/homelab/backup-script.yaml`](../../backup/overlays/homelab/backup-script.yaml) | 夜备的 `pg_dump` 段 + uploads 目录 |
| [`backup/overlays/homelab/external-secret.yaml`](../../backup/overlays/homelab/external-secret.yaml) | 夜备用的 `MULTICA_DB_PASSWORD` |

values 里三处**必须保持**的设置（改了会静默失效或出事）：

- `ingress.enabled: false` —— chart 默认 `true` + `className: traefik`，本集群唯一入口是
  Cilium Gateway API，开着会生成一个永远不被认领的 Ingress。
- 三个 Deployment 的 `affinity` 都钉 **control-plane**。夜备 CronJob 也钉在 control-plane，
  读的是**所在节点**的 hostPath；PVC 落到 worker = 夜备静默漏备（rc=0 的假阴性）。
- `frontend.config.remoteApiUrl: ""` —— 留空即启用 frontend 的 runtime proxy，
  它转发 `/api /auth /uploads /ws`，所以**只需要一个域名**，不用给 backend 开 `api.*` 子域。

⚠️ chart 生成的两个 PVC **不在清单树里**，`check-manifests.py` 的 H4（PVC 必须有备份归属）
**查不到它们**（同 CNPG 的卷）。夜备那两段是手工加的，删了不会有任何检查报错。

```bash
cd /Users/matthew/projects/homelab
git push origin main      # ArgoCD ~3 分钟自动同步
```

### 步骤 3b — 给两个 PVC 加 `Prune=false`（**不能进 git，必须手工**）

☠️ **本仓库其它有状态服务的 PVC 都在清单里带 `Prune=false`，multica 的不是** ——
它的 PVC 由 chart 模板生成，而 chart 既不支持 PVC 注解、也没有 `existingClaim` 选项
（`claimName` 是写死的），所以没法用 GitOps 正途声明。不加保护的后果是：
**删掉 Application 或让 chart 不再渲染 PVC，库会被 prune 掉。**

pod 起来、PVC Bound 之后补上：

```bash
for p in multica-postgres-data multica-backend-uploads; do
  kubectl --context k3s-homelab -n personal-services annotate pvc "$p" \
    argocd.argoproj.io/sync-options=Prune=false --overwrite
done
```

实测（2026-08-18）这个注解能在 `hard refresh` + 同步后存活 —— chart 不渲染注解，
ArgoCD 也就不会去清它。但**它不在 git 里**：PVC 一旦重建（换节点、删卷重来）就得再加一次，
所以每次重建都要跑这一步。

⚠️ 它只防「同步时被 prune」。真正兜底的是夜备的 `pg_dump`（步骤 7），
退役前先手动 dump 一份，别只依赖这个注解。

## 步骤 4 — 验证服务端

```bash
# 三个 pod 都应在 k8s-node 上
kubectl --context k3s-homelab -n personal-services get pods -l app.kubernetes.io/name=multica -o wide

# 首次部署必查：HTTPRoute 的 ResolvedRefs（路由与工作负载由不同 App 同步，没有先后保证）
kubectl --context k3s-homelab -n personal-services get httproute multica \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}{"\n"}'   # 期望 True

# 邮件走的是哪条路（期望 SMTP relay，不是 "no email backend configured"）
kubectl --context k3s-homelab -n personal-services logs deploy/multica-backend --tail=200 | grep EmailService

curl -sS https://multica.meirong.dev/api/config | python3 -m json.tool

# 首页重定向（2026-08-25 起）：期望 302 + location: /homelab/issues
curl -sSI https://multica.meirong.dev/ | grep -iE '^(HTTP/|location:)'
```

⚠️ 这个 302 **由 Envoy 就地应答，请求到不了 pod** —— 所以它不能当存活证据（frontend 死透
了它照样 302）。Uptime Kuma 那条探测因此打的是 `/api/config` 而不是 `/`，别改回去；
理由与推广版教训见 [reference/networking-ingress.md](../reference/networking-ingress.md)。
换 workspace slug 或换落地页时，☠️ 先 curl 新路径确认不是 404 —— `/homelab` 裸路径就是 404，
dashboard 页全在 `/homelab/<page>` 之下。

若 `ResolvedRefs=False`，碰一下路由强制 reconcile（Service 后建时 Cilium 不会自动重算）：

```bash
kubectl --context k3s-homelab -n personal-services annotate httproute multica reconcile-nudge="$(date +%s)" --overwrite
kubectl --context k3s-homelab -n personal-services annotate httproute multica reconcile-nudge-
```

## 步骤 5 — 首次引导（账号 → workspace → 收口）

`values` 里 `allowSignup: false` + `allowedEmails: "<你的邮箱>"`。**allowlist 优先于
`allowSignup` 开关并直接放行**，所以这个地址就是唯一能注册进来的入口，不需要「先开后关」。
⚠️ 正因为它是旁路，这里要填**精确邮箱**而不是 `allowedEmailDomains` —— 用域名的话该域下
任何人都能注册。

1. 打开 https://multica.meirong.dev，用该邮箱登录（验证码到邮箱）。
2. 建第一个 workspace。
3. 把 `values` 的 `disableWorkspaceCreation` 改成 `true` 并 push。

第 3 步是刻意分两阶段的：`true` 会让 `POST /api/workspaces` 对**所有调用者**返回 403，
包括你自己 —— 没有管理员绕过。将来要再建 workspace 得改回 `false` → push → 等 backend
重启 → 建完再翻回来。

核对生效状态时注意**三处名字不一样**，拿错了查不到、看着像没生效：

| 位置 | 名字 |
|------|------|
| values | `disableWorkspaceCreation` |
| env / ConfigMap | `DISABLE_WORKSPACE_CREATION` |
| `/api/config` | `workspace_creation_disabled` ← **词序是反的** |

## 步骤 6 — daemon（M2 MacBook）

⚠️ **daemon 二进制是 `darwin-arm64` 预编译包**（GitHub release，固定版本 + sha256 校验，
**不走 Homebrew**）。也就是说这一步要求一台 **Apple Silicon** 机器；Intel Mac 或 Linux
需要换 release 资产，本仓库没有验证过。CLI 版本必须与 service 端 chart 同 tag（见「升级」）。

**从零开始还需要什么**（下面这些不在本文范围，全部在
[`macbook/ansible/README.md`](../../macbook/ansible/README.md)）：

1. **开 Remote Login (SSH)** —— 系统设置 → 通用 → 共享 → 远程登录。GUI-only，
   无头机器得先经 Screen Sharing 或接显示器做一次，否则 Ansible 连不上。
2. **装好并登录 Tailscale**，且勾选 *Run Tailscale when logged out* —— 这台机是无头/合盖
   运行，只经 Tailscale 访问。
3. `just packages` —— Homebrew + 基础 CLI。⚠️ **Homebrew 首次安装需要交互式 admin 密码**，
   无头 SSH 跑不过，重建机器时要单独手动跑一次。
4. **自动登录 + FileVault 关闭** —— LaunchAgent 装在 **GUI 域**，没人登录就不会起。
   机器重启后若停在登录界面，daemon 静默不上线而服务端一切正常（就是本文开头那个陷阱）。
5. `just ai-clis` —— 装 AI CLI，daemon 靠**探测 PATH** 发现它们
   （[`ai-clis.yaml`](../../macbook/ansible/playbooks/ai-clis.yaml)）。
6. **电源策略** `just power`（`pmset disablesleep`），否则机器睡过去 daemon 就掉线。

1. 在 web UI 生成一个 **PAT**（`mul_...` 开头）。
2. 存进 Vault：

```bash
export VAULT_ADDR=https://vault.meirong.dev
vault kv patch secret/homelab/multica daemon_pat="mul_..."
```

3. 一条命令到底（配方会从 Vault 现取 PAT，未认证时自动 `multica login --token`，
   然后 bootstrap LaunchAgent 并断言 daemon 到达 `running`）：

```bash
cd /Users/matthew/projects/homelab/macbook/ansible && just multica-daemon
```

☠️ **daemon 认证只走 PAT，不要用浏览器 OAuth。** `multica login` 的回调监听在 **Mac 自己的
localhost**，在别的机器打开那个 URL 是空端口；而 `--callback-host <Tailscale IP>` 虽然端口
可达，却有**认证等待超时窗口**，人机不同步就失败。PAT 无窗口、非交互、可重复。

### 验证 daemon（判据在服务端，不在 CLI）

```bash
kubectl --context k3s-homelab -n personal-services exec deploy/multica-postgres -- \
  psql -U multica -d multica -tAc \
  "select name||' | '||provider||' | '||status from agent_runtime order by name;"
```

⚠️ **别用 `multica daemon status` 的返回码当判据**：daemon 没起来时它**照样 rc=0** 并输出
`{"status":"stopped"}`。要看就看 `status` 字段本身。另外冷启动首轮的 `skipped_agents`
会虚报（下一轮心跳就正常），所以以上面这张表为准。

哪些 AI CLI 能注册取决于它们各自的 `--version` 是否秒回 —— 探测超时会被 daemon 跳过。
当前实测结果记在
[playbook 文件头](../../macbook/ansible/playbooks/multica-daemon.yaml)，不在本文档重复。

## 步骤 7 — 验证备份

不要等到夜里才知道漏备。直接跑一次夜备用的那条命令：

```bash
kubectl --context k3s-homelab -n personal-services exec deploy/multica-postgres -- \
  psql -U multica -d multica -c '\dt' | head -3      # 库通
kubectl --context k3s-homelab -n backup get secret restic-backup \
  -o jsonpath='{.data.MULTICA_DB_PASSWORD}' | wc -c  # 夜备凭据已同步（非 0）
```

完整的恢复演练走 [backup-recovery.md](backup-recovery.md)。

## 升级

chart 与 CLI 出自同一个 monorepo 的同一个 tag，**两处一起改**：

1. `argocd/applications/multica.yaml` 的 `targetRevision`
2. `macbook/ansible/playbooks/multica-daemon.yaml` 的 `md_version` + `md_sha256`
   （sha256 取自 release 的 `checksums.txt`），然后重跑 `just multica-daemon`

核对现网版本：`curl -s https://multica.meirong.dev/api/config` 的 `server_version`。

## 退役

```bash
git rm argocd/applications/multica.yaml k8s/helm/values/multica.yaml \
       k8s/helm/manifests/gateway/route-multica.yaml \
       k8s/helm/manifests/personal-services/multica-secret.yaml
# 夜备的 pg_dump 段与 uploads 目录、external-secret 的 MULTICA_DB_PASSWORD 一并摘掉
git push origin main
```

☠️ **push 之前先留一份数据**（PVC 的保护是手工注解、可能已随重建丢失）：

```bash
kubectl --context k3s-homelab -n personal-services exec deploy/multica-postgres -- \
  pg_dump -U multica -d multica -Fc > /tmp/multica-final.dump
ls -l /tmp/multica-final.dump      # 确认非零字节
```

收尾三件容易忘的：

1. **PVC**：若步骤 3b 的 `Prune=false` 还在，卷会残留、需手工删
   `multica-postgres-data` 与 `multica-backend-uploads`；若注解已丢，它们会随
   Application 一起被 prune —— 所以上面那份 dump 是唯一保险。
2. **DNS 记录不会被删** —— external-dns 是 `upsert-only`，手工清 `multica.meirong.dev`。
3. M2 上卸掉 daemon：`launchctl bootout gui/$(id -u)/ai.multica.daemon`，
   删 `~/Library/LaunchAgents/ai.multica.daemon.plist`，并吊销那个 PAT 与 Gmail 应用专用密码。

另外把 [reference/services.md](../reference/services.md) 里的行、homepage 磁贴、
Uptime Kuma 的 `MONITORS` 条目一并摘掉。
