# Homelab 宿主机功耗与散热 (Homelab Host Power & Thermal)

> Last updated: 2026-10-28
> Status: 生效事实
> Scope: homelab 的物理宿主（Proxmox `pve`，Ryzen 5600H 笔记本）。homelab 温度/功耗/内存容量约束的
> **唯一真相源**，AGENTS/ARCHITECTURE/security 里的硬约束从这里引用，别在别处再写一份数字。

## 物理形态

- 宿主机是 Ryzen 5600H 笔记本（Proxmox VE `pve`，192.168.50.4 / TS 100.118.193.51），
  只跑一个 k8s-node VM（VMID 100，10 vCPU / 13GB，cputype=host）。
- **风扇由 BIOS/EC 控制，不暴露给 OS**（hwmon 只有 `ADP0 / BAT0 / nvme / k10temp / amdgpu`），
  软件层改不了风冷曲线。
- 环境：新加坡，室温 ~30°C。

## 内存容量（宿主 → VM 的分配链）

| 层 | 值 | 出处 / 判据 |
|----|----|-----------|
| 物理 | 16GB（2×8GB SO-DIMM，两槽插满） | `dmidecode -t 17`；`-t 16` 报 `Maximum Capacity: 16 GB`。⚠️ 「5600H 通常能上 32GB」未针对本机型验证，下单前先核实 Lenovo 该型号规格（BIOS `GZCN14WW`, 2021-02-03） |
| OS 可见 | 15.0GB（`MemTotal`） | 差额是核显（Cezanne/Vega）UMA 显存，已在 BIOS 收到 512MB。无头服务器，核显显存纯属浪费 |
| k8s-node VM | 13312MB 硬分配，`balloon: 0` | 真值是 `proxmox/terraform/variables.tf` 的默认值。**不该开 balloon**：kubelet 按 MemTotal 算 allocatable，balloon 收走的它看不见 |
| 宿主余量 | 薄，别再挤 | ⚠️ 以 `free -m` 的 available 为准，别写死数字，也别信 `kubectl top node`（那是 requests 视角）。swap 常驻 1G 左右**不是抖动**：`/proc/pressure/memory` 全零、`vmstat` 无换入换出，是 pve 守护进程的冷页 |

> 加组件前的判据不是「VM 里还有多少 requests 没分配」，而是**宿主还剩多少 available**，
> 两者能差好几百 Mi。requests/limits 的原则见 [k8s-qos-resource-management.md](k8s-qos-resource-management.md)。

## 当前生效的省电配置

| 项 | 值 |
|----|----|
| 调频驱动 | `amd-pstate-epp`（active） |
| governor | `powersave` |
| energy_performance_preference | `power`（最省电档） |
| 频率 | min 1.108 GHz / max 封顶 2.8 GHz（5600H 原生 boost 4.2GHz） |
| iGPU | amdgpu DPM 强制 `low`，空闲 PPT 4–14W |

governor / EPP / min-freq 已是该平台的最优档位，**不需要再往下调**。持久化在 `proxmox/ansible/playbooks/power-tune-pve1.yaml`
（`cpu-epp-power` / `amdgpu-dpm-low` 两个 unit）与 `power-optimize.yaml`（关 turbo boost），
`cd proxmox/ansible && just power-tune-pve1` 可重复执行。

空闲读数（2026-08-09 实测）：CPU Tctl ~60–62°C、iGPU edge 57–59°C、NVMe 46–48°C；CPU RAPL package ~5W，
整机墙上估算 ≈ RAPL + iGPU + 15–20W 外设/风扇/损耗 ≈ 25W。62°C 对 5600H 属正常
（crit 105°C，一般 95°C 才降频）。

## 降温度抓手（按收益排序）

1. **物理散热**（收益最大，也是唯一能显著拉低空闲温度的手段）：清灰 + 换硅脂（用了几年，硅脂老化是主要
   嫌疑）、垫高并保证出风口通畅、开空调。
2. **软件**（削峰值发热，对空闲帮助有限）：
   - 频率上限 2.8 → ~2.2–2.4GHz：改 `power-tune-pve1.yaml` 里 `cpu-epp-power` 的 `2800000`。平均负载低，无体感
   - 限 k8s VM 瞬时突发：在 `pve` 上 `qm set 100 --cpulimit 500`（目前未设，kvm 会瞬时飙到 ~3 核）
   - 周期尖峰源（trivy 扫描 / restic 备份 / Prometheus 评估）错峰
3. **不用动**：iGPU / NVMe 不是热源。

## 监控

- 宿主温度/磁盘温度：node-exporter + smartctl（192.168.50.4）→ Grafana `Hardware` 看板。
- 功耗：`node_rapl_package_joules_total{cluster="homelab"}` → `Hardware` 的 Power Overview 看板。
  ☠️ `energy_uj` 自内核 5.10 起 root-only（PLATYPUS 缓解，CVE-2020-8694），node_exporter 以非特权用户跑，
  读不到时 `node_scrape_collector_success{collector="rapl"} 0`，一条 `node_rapl_*` 都不产出且完全静默。
  放权靠 udev 规则把 `energy_uj` 给 `node_exporter` 组（`proxmox/ansible/playbooks/node-exporter-deploy.yaml`
  两个 play 均有，playbook 内置断言防回归），别删。
  ⚠️ 排查同类问题**先看 `node_scrape_collector_success{collector="..."}`**，别只看指标有没有。
- ⚠️ Ryzen 的 powercap 只有 `package-0` + `core` 两个域，没有 dram/uncore（storage-106 是 Intel，四个域齐全）。
  查不到 pve 的 DRAM 功耗是硬件如此，不是故障。

## 相关

- [cost-and-rightsizing.md](cost-and-rightsizing.md) — 功耗定价模型（45W 占位、校准步骤）
- [security.md](security.md) — 安全组件「fail-open + 控 CPU」硬约束出处
- [networking-ingress.md](networking-ingress.md) — 宿主机地址速查
