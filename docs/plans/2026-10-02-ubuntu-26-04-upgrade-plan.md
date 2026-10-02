# Ubuntu 26.04 LTS 升级与 IaC 适配执行方案

> 日期: 2026-10-02
> 状态: 📐 设计（待生态成熟与 IaC 适配）
> 结论: 禁止在生产节点执行原地 `do-release-upgrade`。规范演进路径为：① 在 PVE 独立实验 VM 沙盒验证 Cilium 1.20+ eBPF、Falco/Tetragon、Tailscale 与 K3s；② 补齐 Terraform 与 Ansible 对新镜像及源的支持；③ 借助 PVE VM 完整快照与 restic PVC 备份，按节点滚动重建/替换。
> 关联: [ROADMAP 开放项 #20](../ROADMAP.md)

---

## 一、背景与现状

Ubuntu 26.04.1 LTS 已发布并触发跨版本升级提醒。目前集群全部 3 个 K3s 节点均稳定运行在 **Ubuntu 24.04.4 LTS (Noble)** 基线上：

* `k8s-node`（homelab 控制面）：承载 12 个关键 `local-path` PVC（Vault raft、`apps-pg` 共享数据库、Prometheus/Grafana 监控等）；
* `k8s-worker-106`（homelab worker）：运行在 NAS 106 上的 VM，跨网段并依赖特定的 `ip rule 5240` 路由策略；
* `oracle-k3s`（oracle 控制面）：运行 ArgoCD GitOps 控制面与 Loki/Tempo 遥测中心。

当前整套 IaC（Terraform / Ansible / 镜像脚本 / Tailscale 软件源）深度绑定 24.04。

---

## 二、为什么不能直接原地升级（In-place Upgrade）

1. **Cilium eBPF 数据面挂死风险**：
   集群开启了全功能 eBPF 数据面（`kubeProxyReplacement: true` + Gateway API）。[2026-03-08 的故障](2026-03-08-cilium-gateway-clustermesh-stabilization.md) 曾证明，内核升级带来的 BPF verifier 校验规则变动极易导致 `cilium-agent` CrashLoop，使全集群网络流量瞬间归零。
2. **内核安全探针兼容性脆弱**：
   Falco 与 Tetragon 深度依赖宿主内核 kprobe 与 tracepoint。跨大版本内核变动极易导致探针失效或触发系统级内存/系统调用抖动（如 [2026-09-12 事件](../records/2026-09-12-falco-syscall-drops-apt-upgrade.md)）。
3. **第三方源被禁用与配置漂移**：
   `do-release-upgrade` 会自动禁用非官方第三方源（如 Tailscale 的 noble 源），导致节点脱离 Tailnet 失联。且原地升级导致物理机与 Terraform/Ansible 代码库彻底失步。
4. **本地存储数据损失不可逆**：
   控制面上 12 个 local-path PVC 全在 VM 盘上，系统升死后只能走耗时漫长的 restic 灾难恢复。

---

## 三、准入前提（Gate Criteria）

在正式启动实施前，必须满足以下硬性条件：

1. **生态兼容确认**：
   * Cilium 官方文档明确确认当前版本（或待升版本）完全支持 Ubuntu 26.04 默认内核的 eBPF 特性；
   * Tailscale 官方稳定仓库已正式支持 26.04 的发行版 codename；
   * K3s 官方发布针对新内核与 systemd/cgroups v2 的兼容版本。
2. **维护窗口就绪**：
   * 接受单节点计划内关机 15–30 分钟。

---

## 四、实施阶段

### Phase 0: IaC 基础设施层适配
1. **下载与模板更新**：
   * 修改 `proxmox/ansible/playbooks/download-cloud-image.yaml`，引入 Ubuntu 26.04 cloud-image；
   * 在 `proxmox/terraform/variables.tf` 与 `proxmox/terraform-storage/variables.tf` 中新增对 26.04 镜像变量的支持。
2. **软件源与配置适配**：
   * 更新 `tailscale/ansible/roles/tailscale_node/tasks/main.yaml`，使用动态发行版变量替换写死的 `noble`；
   * 核对 `setup-k3s.yaml` 中的 sysctl 配置（如 inotify、protect-kernel-defaults）在新内核下的有效性。

### Phase 1: 沙盒实验 VM 端到端验证
1. 在 PVE 宿主机上创建独立的实验 VM（如 VMID 108，不接入生产网络与集群）；
2. 完整跑通 26.04 镜像预配 + Tailscale + K3s + Cilium 部署；
3. 严格验证：
   * `cilium status --wait` 全绿，无 BPF verifier 报错；
   * 部署测试 HTTPRoute 能正常拿到 `.status`（验收判据遵从 `records/2026-08-11-gateway-api-crd-stall.md`）；
   * Falco 与 Tetragon 容器正常采集事件且无异常丢包。

### Phase 2: 生产前置保护与快照
1. **备份校验**：
   * 确认 106 上的 restic 夜备拥有最新的 12 个 local-path PVC 快照，满足灾备恢复条件。
2. **底层 VM 冷快照**：
   * 在 PVE 宿主机对待升级 VM 打全量冷快照（保留 30 秒一键秒级回滚能力）：
     ```bash
     qm stop 100
     qm snapshot 100 pre-upgrade-2604 --description "Pre-upgrade snapshot to 26.04"
     qm start 100
     ```

### Phase 3: 节点分批重建与验证
1. **升级次序**：
   * **第 1 步：`k8s-worker-106`**：无控制面核心数据，先 drain 并用新镜像重新部署加入集群；
   * **第 2 步：`oracle-k3s`**：验证跨集群 ClusterMesh 在新旧内核混合状态下的连通性；
   * **第 3 步：`k8s-node`**：停机维护，导入新配置重建，恢复 local-path PVC 数据或切换启动盘。
2. **集群验收**：
   * 运行 `just verify-node` 与 `python3 scripts/check-manifests.py`；
   * 检查 ClusterMesh 双向 `retrieved=true`；
   * 检查公网入口（Cloudflare Tunnel -> Cilium Gateway）200 响应。
