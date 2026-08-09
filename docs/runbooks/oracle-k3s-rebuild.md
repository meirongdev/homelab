# Oracle-k3s 节点重建（OCI Free Tier）

> **触发条件**：oracle-k3s 节点（OCI Always Free A1）不可恢复——VM 被终止/重建、
> OS 损坏、boot volume 丢失，或需要从零重做集群。
> **成功判定**：`just argocd-status`（`cd k8s/helm`）28 个 App 全部 Synced/Healthy；
> `argocd.meirong.dev` 可登录；`just clustermesh-status`（`cd cloud/oracle`）双集群
> connected；夜备恢复后跑一次 `just backup-run` 通过。
> **回滚**：恢复类 runbook 本身即回滚——重建中途失败就回到本流程第 1 步重跑，
> 数据一律从 restic 恢复（见 [backup-recovery.md](backup-recovery.md)），
> 无更早状态可退。注豁免。
>
> Last updated: 2026-08-03
> Status: 生效 SOP

## 现状（一句话）

2026-08-02 之后 oracle-k3s 不再是「轻量采集端」，它承载 **ArgoCD 控制面 + ZITADEL(身份)
+ Loki/Tempo(日志/追踪) + Calibre-Web**。重建的丢数据风险很高：oracle 全部 PVC 都是
`local-path`（无冗余、无 ZFS 快照），唯一安全网是 106 上的 restic 夜备。

## 0. 数据盘点（先做，别跳过）

oracle-k3s 的 local-path PVC（15 个，2026-08-06 对着 live 集群重新生成——上一版有三处漂移：
`uptime-kuma-data` 实为 `uptime-kuma-data-v2`、漏了 `readlist-data`、`miniflux-db-pvc` 已退役）：

`storage-loki-0` · `storage-tempo-0` · `opencost-pvc` · `calibre-books-local` ·
`calibre-web-automated-config-local` · `stirling-pdf-configs` · `timeslot-pvc` ·
`trends-data` · `uptime-kuma-data-v2` · `karakeep-data` · `meilisearch-data` ·
`readlist-data` · `data-trivy-server-0` · `apps-pg-1` · `zitadel-pg-1`

> **两个 CNPG 卷（`apps-pg-1` / `zitadel-pg-1`）的恢复方式不同**：它们由 operator 按
> `Cluster` CR 自动创建，**不要试图把 PVC 内容拷回去**。正确做法是让 ArgoCD 同步出
> `Cluster` 对象（空库自动起来），再把 restic 里的 `miniflux.sql` / `zitadel.sql`
> 用 `psql` 灌进去。核对清单用 `kubectl --context oracle-k3s get pvc -A`。

- 若 **boot volume 保留**（VM 只是 OS 层损坏/重装、或从 OCI 快照恢复）：
  `local-path` 数据在 `/var/lib/rancher/k3s/storage/` 还在 → 不需要恢复，跳过第 7 步。
- 若 **VM 终止重建 / boot volume 删除**：必须先确认 restic 仓库里有最近快照
  （106 上 `RESTIC_PASSWORD=… restic -r /storage/restic snapshots`），然后走
  [backup-recovery.md](backup-recovery.md) 的 restore SOP。
- 对照 [reference/services.md](../reference/services.md) 的服务清单（唯一真相源），逐项确认恢复/重建覆盖。

## 1. 重建 OCI VM（仅 VM 没了才做）

```bash
cd cloud/oracle/terraform
make plan    # 核对实例形状/是否保留 boot volume
make apply
```

- ⚠️ terraform state 在本地（ROADMAP 开放项 #2，未离站）——这台 Mac 丢了 state 就得
  按 `cloud/oracle/terraform/IMPORT.md` 重新 import。
- 若 VM 还在、只是 OS 层损坏：跳过本步，`cd cloud/oracle/ansible && just cleanup-k3s`
  后直接进第 2 步。

## 2. 节点配置（K3s + firewalld + Gateway API CRD + sysctl）

```bash
cd cloud/oracle
just setup-node          # = cd ansible && just setup-k3s
just fetch-kubeconfig
kubectl --context oracle-k3s get nodes    # 应 Ready
```

`setup-k3s.yaml` 会一并装好：firewalld 放行（K3s/Cilium 端口 + 10.52/10.53 CIDR 信任）、
Gateway API CRD v1.2.1（standard channel）、falco 依赖的 `fs.inotify.max_user_instances=8192`。
⚠️ 不要改 playbook 里 `disable: traefik` 那段——Gateway API CRD 由 playbook 独立安装，
让 traefik 托管会在 k3s 重启时级联删 CRD、路由全断（2026-06-04 踩过）。

## 3. Tailscale

```bash
cd cloud/oracle
just setup-tailscale <authkey>    # 加入 tailnet + 只广播自身 VCN IP /32（10.0.0.26/32，VXLAN 外层目的；Pod CIDR 不广播）
```

验证：homelab 上 `tailscale status` 能看到 `100.107.166.37`。

## 4. Cilium CNI

```bash
cd cloud/oracle
just deploy-cilium
just cilium-status    # Cilium ready
```

## 5. ESO + Vault token + 全量 manifests（bootstrap）

```bash
cd cloud/oracle
just install-eso
VAULT_TOKEN=<homelab 侧 token> just create-vault-token
just deploy-manifests    # kubectl apply -k manifests/
```

`deploy-manifests` 会整树 apply（base/gateway/cloudflare-tunnel/vault-store/external-dns +
全部应用 + `argocd/` 的 ns 与 homelab-cluster ESO 凭据）。

- ⚠️ **bootstrap 依赖不入 git**：
  - `vault-token` Secret（`rss-system`）——从 homelab Vault 手工取（Vault 在 homelab，
    不受这次重建影响）。
  - ZITADEL `login-client` Secret（`zitadel` ns，Login V2 PAT）——从 homelab 备份拷入，
    否则已恢复的 DB 上 setup job 不会重建它。见 `cloud/oracle/manifests/kustomization.yaml`
    头注。

## 6. Cloudflare tunnel

```bash
cd cloud/oracle
just deploy-cloudflare-tunnel    # cloudflare terraform（DNS + 通配路由）+ connector
```

## 7.（仅数据丢失时）从 restic 恢复关键 PVC

按 [backup-recovery.md](backup-recovery.md) 恢复，优先：`storage-loki-0`（日志）、
`storage-tempo-0`（追踪）、`zitadel-pg-1`（身份 DB）、`calibre-books-local`（书库）、
其余 sqlite 卷。

## 8. ArgoCD 控制面重装（重建后 oracle 上还没有 GitOps 控制器）

```bash
cd k8s/helm
just deploy-argocd          # chart + AppProject（只装控制面，不含 Application 注册）
just deploy-argocd-apps     # 注册 28 个 Application
just argocd-status          # 等全部 Synced/Healthy
```

- 完整 bootstrap 依赖（homelab 侧 `kube-system/argocd-manager` SA/CRB/token → Vault
  `secret/homelab/argocd-homelab-cluster` → ESO `homelab-cluster` Secret）见
  [argocd-control-plane-on-oracle.md](argocd-control-plane-on-oracle.md) 的「bootstrap 依赖」。
- ☠️ destination 语义：`kubernetes.default.svc` = **oracle（控制面所在集群）**；
  homelab 负载必须显式写 `https://100.94.186.7:6443`。写错会把 homelab 全套负载装到 oracle。

## 9. ClusterMesh 重连

```bash
cd cloud/oracle
just connect-clustermesh 100.94.186.7:32379 100.107.166.37:32379
just clustermesh-status
```

（source = homelab，destination = oracle；两个端点参数都要给。重建后状态是 disconnected，
必须重跑。）

## 10. 验证

1. 服务清单对照 [reference/services.md](../reference/services.md)：`kubectl --context <ctx> get httproute -A`。
2. `argocd.meirong.dev` 等公网入口可登录（Uptime Kuma provisioner 是 PostSync hook，
   ArgoCD 同步时自动重建 monitor）。
3. dead-man's switch：Watchdog → `status.meirong.dev/api/push/…` 链路恢复。
4. 夜备恢复后手动触发一次备份确认仓库健康：
   `kubectl --context oracle-k3s -n backup create job --from=cronjob/restic-backup <name>`。
5. external-dns：域名由 HTTPRoute 声明，无手工 DNS 步骤。
