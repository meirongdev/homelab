# 采纳 Renovate 管版本钉扎（配 CI 配对断言）

> 日期: 2026-08-13
> 状态: 🚧 执行中（配置已合入并通过官方 validator；**待人工装一次 GitHub App**，见下）
> 关联: [ROADMAP 开放项 #12](../ROADMAP.md)（原列在"低优先/可选"里）·
> [manifest-safety-checks.md](../reference/manifest-safety-checks.md)（V1-V3 规则全文）·
> [records/2026-08-11-gateway-api-crd-stall.md](../records/2026-08-11-gateway-api-crd-stall.md)

## Context

版本钉扎全靠人肉记账，而**漂移是静默的**。三次实例，一次比一次说明问题：

1. **2026-08-11**：Cilium 1.20 升级漏配 Gateway API CRD（现网 v1.2.1 vs 要求 v1.6.1），
   operator 的 Gateway API 控制器整个不初始化 **30 小时**。旧路由照常 200、无任何告警，
   只有新增路由静默 503。
2. **2026-08-13**：复查发现 `cloud/oracle/ansible/playbooks/setup-k3s.yaml` **仍钉着
   v1.2.1**，而注释写着"与 homelab 一致"。同一事实散在三处（两个 justfile + 一个剧本），
   两处已改、一处漏改，且漏的那处**只在重建集群时才爆**。最坏的一类缺陷。
3. **同日扫全仓**又发现 `node_exporter` 在三套 ansible 里是 1.11.1 / 1.10.0 / 1.11.1。

规模已经过了人肉能管住的线：28 个 ArgoCD App、两套 ansible、四个 justfile。
[技术债盘点](../plans/architecture/2026-07-07-tech-debt-and-evolution.md) 早就写明
"这类漂移必然复发"，2026-07-07 的实测也确认过（照 pin 重跑会降级）。

## Decision

**Renovate 只开 PR，配一个 CI 检查器兜存量。** 两者视角不同，缺一不可：

| | 管什么 | 什么时候响 |
|---|---|---|
| `scripts/check-version-pairs.py` | 多处副本**互相**不一致、cilium↔gateway-api 不符合兼容表 | PR 当场红 |
| Renovate | 上游**有新版本**了 | 每周一开 PR |

只有 Renovate 会漏掉"两处副本一起停在旧版本"（它不知道哪两处该相等）；
只有检查器则永远发现不了上游已经发新版。

**配置**：`.github/renovate.json5`（JSON5 是为了能写理由注释，与本仓库其它配置同风格）。
内置 manager 管 ArgoCD chart 版本与清单镜像；自定义 regex manager 管 justfile / ansible
里的版本变量，约定是**版本行上面一行**写 `# renovate: datasource=… depName=…`：
把来源写在版本旁边，改版本的人当场就能看到它从哪来。实测识别 16 条自定义依赖 +
内置 manager 覆盖的 chart/镜像。

### 三条刻意的自我约束

1. **永不 automerge**。仓库有一批 manual-helm 组件（Cilium / Vault / ESO / ArgoCD 本体），
   合并只改 git、现网不动。自动合并会制造"git 说新版、现网是旧版"的假象。
   那种挂着"✅ 生产运行"的死文档误导过 5 天，同一类伤害。
   这批的 PR 打 `manual-helm` label + PR 正文写明"合并 ≠ 部署"。
2. **不开 `pinDigests`**。仓库要求 arm64 关键镜像钉多架构 index digest，
   让 Renovate 给所有镜像铺 digest 会淹掉 PR 队列；已有 digest 的它会自动跟着升。
3. **不管 `docs/`**。`plans/` 是写完即冻结的快照，改它们是错的（R1）。

### 分组策略（按"必须一起改"分，不按包名分）

- **cilium + gateway-api 一个 PR**：它们是配对关系，分开升就是 08-11 的复现路径。
  PR 正文列了合并后的四步人工动作（跑 CRD 配方、手动 helm、给兼容表加行、看 operator 日志验收）。
- **同名 chart 跨集群一个 PR**（external-dns / opencost / trivy-operator 各两份）：
  天然满足检查器的 V1。
- **exporters 一个 PR**：那三套 ansible 的漂移就是这么来的。
- **k3s 单独且不进周更批次**：升级要维护窗口。

### 排除项（写下来免得以后当成漏配）

- CI 里 `just` 与 `shellcheck` 的版本**刻意不标**：它们的版本在同一行出现两次
  （release tag + 解出的目录名 / 镜像 tag），regex manager 只替第一处，PR 会带一条拼不出来
  的下载 URL。那种 PR 比不开 PR 更浪费时间。要管得先把版本抽成 env 变量，属独立改动。
- `eso_version` / `node_exporter_version` **不进检查器的配对组**（但归 Renovate 管）：
  两集群的 ESO、三套机队的 exporter 各自独立，不一致是"该升级了"而非"配置错了"。
  把它算违规就会制造一条谁都不看的红灯。

## 待人工完成的一步

配置已在仓库里且通过 `renovate-config-validator`，但**Renovate 还没有运行者**。二选一：

- **装 Mend 托管的 GitHub App**（推荐，零维护）：<https://github.com/apps/renovate> →
  只授权 `meirongdev/homelab`。它会自动发现 `.github/renovate.json5`，首个 PR 是
  "Configure Renovate"（Dependency Dashboard）。
- **自托管**：加一个 workflow 跑 `renovate/renovate`，需要一个有 `repo` + `workflow`
  权限的 PAT 存进 Actions secret。省掉第三方 App 授权，代价是多一份 CI 维护。

## Consequences

- ✅ 上游发版不再靠人想起来；"等上游修 CVE"的 trivyignore 豁免会在上游真重建镜像时
  **自动变成一个 digest 更新 PR**：复审从日历纪律变成事件驱动。
- ✅ 三处 `gateway_api_version` 现在会在**同一个 PR** 里一起改，且 CI 会拦漏改。
- ⚠️ 每周多出 PR 队列要处理（`prConcurrentLimit: 3` + 分组压噪音）。**PR 绿 ≠ 可以合**：
  manual-helm 那批合完必须手动部署。
- ⚠️ 检查器的 `CILIUM_GATEWAY_API` 兼容表需要人**在升级时加行**（查不到行就报错，
  这是特意的：强迫读一遍上游前置条件，而不是假设旧 CRD 还能用）。
- ⚠️ 字段名用了 `fileMatch` 而非新版的 `managerFilePatterns`：本地 validator 实测 37.x
  只认前者、41+ 仍兼容它。等确认运行的是 41+ 再换名（换名时正则要加 `/…/` 定界符）。
