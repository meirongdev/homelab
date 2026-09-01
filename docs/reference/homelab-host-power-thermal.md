# Homelab 宿主机功耗与散热 (Homelab Host Power & Thermal)

> Last updated: 2026-09-01
> Status: 生效事实
> Scope: homelab 的物理宿主（Proxmox `pve`，Ryzen 5600H 笔记本）。homelab 温度/功耗/内存容量约束的
> **唯一真相源**，AGENTS/ARCHITECTURE/security 里的硬约束从这里引用，别在别处再写一份数字。

## 物理形态

- 宿主机是 Ryzen 5600H 笔记本（Proxmox VE `pve`，192.168.50.4 / TS 100.118.193.51），
  只跑一个 k8s-node VM（VMID 100，10 vCPU / 13GB，cputype=host）。
- **风扇由 BIOS/EC 控制，不暴露给 OS**：hwmon 只有 `ADP0 / BAT0 / nvme / k10temp / amdgpu`，
  没有 fan 接口 → 软件层无法脚本控风扇，风冷曲线改不了。
- 环境：新加坡，室温 ~30°C。

## 内存容量（宿主 → VM 的分配链）

| 层 | 值 | 出处 / 判据 |
|----|----|-----------|
| 物理 | 16GB（2×8GB SO-DIMM） | `dmidecode -t 17`。⚠️ `dmidecode -t 16` 报 `Maximum Capacity: 16 GB` 且两槽插满。**"5600H 通常能上 32GB"是未针对本机型验证的泛化说法**，下单前必须先核实 Lenovo 该型号规格（BIOS `GZCN14WW`, 2021-02-03） |
| OS 可见 | 15.0GB（`MemTotal` 15717940 kB） | 差额是核显（Cezanne/Vega）UMA 显存。已从 2GB 收到 512MB（BIOS 改，2026-07-12 做、2026-08-13 复测确认生效）。这台是无头服务器，核显显存纯属浪费 |
| k8s-node VM | 13312MB 硬分配，`balloon: 0` | `proxmox/terraform/terraform.tfvars`。无 balloon = 宿主拿不回来 |
| 宿主余量 | 薄，别再挤 | ⚠️ **以 `free -m` 的 available 为准**，别写死数字也别信 `kubectl top node`（那是 requests 视角）。历史参考：UMA 回收前 available 曾低到 ~987Mi |

> 加组件前的判据不是"VM 里还有多少 requests 没分配"，而是**宿主还剩多少 available**，
> 这两个数能差好几百 Mi。requests/limits 的原则见
> [k8s-qos-resource-management.md](k8s-qos-resource-management.md)。

## 当前生效的省电配置（2026-08-09 实测）

| 项 | 值 |
|----|----|
| 调频驱动 | `amd-pstate-epp`（active） |
| governor | `powersave` |
| energy_performance_preference | `power`（已是最省电档） |
| 频率 | min 1.108 GHz / max 已限 2.8 GHz（5600H 原生 boost 4.2GHz） |
| iGPU | amdgpu，空闲 PPT 4–14W |

已经是该平台能到的最优档位，**不需要再往下调**。

## 实测读数（2026-08-09）

| 指标 | 值 |
|------|----|
| CPU Tctl | 空闲 ~60–62°C（随负载在 57–62°C 波动） |
| iGPU edge | 57–59°C |
| NVMe | 46–48°C |
| CPU RAPL package | 空闲 ~5W（SSH 直读 15s 采样） |
| 整机墙上估算 | RAPL + iGPU + ~15–20W 外设/风扇/损耗 ≈ 空闲 ~25W |

> **历史「idle ~74°C」已过时**：那是 AGENTS/security 里的旧值，很可能是硅脂/灰尘老化 +
> 30°C 室温 + 当时负载叠加。2026-08-09 实测空闲 60–62°C。62°C 对 5600H 属正常
> （crit 105°C，一般 95°C 才降频），离危险远。

## 降温度抓手（按收益排序）

1. **物理散热（收益最大，也是唯一能显著拉低空闲温度的手段）**
   - 清灰 + 换硅脂（这台笔记本用了几年，硅脂老化是主要嫌疑）
   - 垫高/改善进风、保证出风口通畅
   - 环境温度（新加坡室温高，开空调最直接）
2. **软件（削峰值发热，对空闲帮助有限）**
   - 频率上限 2.8 → ~2.2–2.4GHz（需持久化，如 systemd unit 开机 `cpupower frequency-set -u`）；
     对 ~9% 平均负载无体感
   - 限 k8s VM 瞬时突发：`qm set 100 --cpulimit 500`（当前 kvm 会瞬时飙到 ~3 核）
   - 找周期尖峰源（trivy 扫描 / restic 备份 / Prometheus 评估）错峰
3. **不用动**：governor / EPP / min-freq 已最优；iGPU / NVMe 不是热源

## 监控

- proxmox host 温度/磁盘温度已进 Prometheus（node-exporter + smartctl，192.168.50.4），
  Grafana `Hardware` 看板。
- **RAPL 已采集（2026-08-12 修复）**：`node_rapl_package_joules_total{cluster="homelab"}` 有数据，
  Grafana `Hardware` 的 Power Overview 看板正常。此前空了很久的根因不是没开 collector：
  collector 一直开着，卡的是权限：`energy_uj` 自内核 5.10 起 root-only（PLATYPUS 缓解，
  CVE-2020-8694），而 node_exporter 以非特权用户跑 → `node_scrape_collector_success{collector="rapl"} 0`，
  一条 `node_rapl_*` 都不产出，且完全静默。修法是 udev 规则把 `energy_uj` 放给 `node_exporter`
  组（`proxmox/ansible/playbooks/node-exporter-deploy.yaml` 两个 play 均有，playbook 内置断言防回归）。
  ⚠️ 排查同类问题时**先看 `node_scrape_collector_success{collector="..."}`**，别只看指标有没有。
- ⚠️ 本机是 Ryzen，powercap 只有 `package-0` + `core` 两个域，没有 dram/uncore
  （storage-106 是 Intel，四个域齐全）。查不到 pve 的 DRAM 功耗是硬件如此，不是故障。

## 相关

- [cost-and-rightsizing.md](cost-and-rightsizing.md) — 功耗定价模型（45W 占位、校准步骤）
- [security.md](security.md) — 安全组件「fail-open + 控 CPU」硬约束出处
- [networking-ingress.md](networking-ingress.md) — 宿主机地址速查
