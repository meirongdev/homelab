# Cloud — 云厂商基础设施

目前只含 **Oracle Cloud** 的 oracle-k3s 单节点集群（Ampere A1 / ARM64）。它不再只是
「轻量采集端」：2026-08-02 起承载 **ArgoCD 控制面 + Loki/Tempo + ZITADEL**，外加全部
无状态个人服务。

**目录说明与完整流程都在 [cloud/oracle/README.md](oracle/README.md)**，这里只放两条容易踩的：

- ⚠️ `cloud/oracle/terraform/` 用 **`make`**，不是 `just`——仓库里其它 terraform root 都用 `just`。
- ⚠️ 节点不可恢复时照 [runbooks/oracle-k3s-rebuild.md](../docs/runbooks/oracle-k3s-rebuild.md) 走：
  oracle 全部 PVC 是 `local-path`（无冗余、无快照），唯一安全网是 106 上的 restic 夜备。

## 快速上手

```bash
cd cloud/oracle/terraform && make init && make apply   # 预配 VM
cd cloud/oracle && just bootstrap                       # 装 K3s + Cilium + ESO + tunnel
```
