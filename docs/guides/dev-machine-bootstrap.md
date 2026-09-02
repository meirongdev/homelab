# 新机器开发环境 bootstrap（配到能改 homelab repo）

> Last updated: 2026-09-02
> 面向「换了一台 Mac，要把本机环境配到能 clone、改、验证这个 repo」的流程。
> 排障/恢复类走 [runbooks/](../runbooks/README.md)；AI 助手上下文见 [../AGENTS.md](../AGENTS.md)（唯一上下文文件，细节按域在 [reference/](../reference/README.md)）。

## 1. 前置：账号与密钥

- **SSH key**：所有节点（homelab/oracle/pve/106/DGX）共用 `~/.ssh/vgio`。没有就把
  现有机器的 `~/.ssh/vgio` + `~/.ssh/vgio.pub` 拷过来，权限 `600`/`644`。
- **GitHub**：`meirongdev` 账号、能访问私有 `homelab` repo 的 key。
- **Tailscale**：加入 tailnet（设备归属 `meirongdev@`），否则跨集群路由/裸机抓取不通。
- **Cloudflare / OCI / Proxmox** 账号（按需，改对应 terraform 时才要）。

## 2. 工具链

```bash
brew install just uv terraform helm kubectl git python3
uv tool install ansible        # 提供 ansible-playbook（justfile 直接调它）
```

- `just`：repo 的主任务运行器（**不是 make**；只有 `cloud/oracle/terraform/` 用 make）。
- `uv`：`check-manifests.py` 用 `uv run --with pyyaml`；ansible 建议 `uv tool install` 隔离。
- `terraform`：7 个 root 都用它：`proxmox/terraform`、`proxmox/terraform-storage`
  （106 上的 worker VM，2026-08-15 新增）、`cloudflare/terraform`、`tailscale/terraform`、
  `zitadel/terraform`、`cloud/oracle/terraform`、`cloud/oracle/cloudflare`。
  （⚠️ `2026-08-03-tf-state-r2.md` 的迁移表只列了其中 5 个：它写在
  `proxmox/terraform-storage` 存在之前，也没覆盖 `zitadel/terraform`。）
- `kubectl`：context 名固定为 `k3s-homelab` 与 `oracle-k3s`。

☠️ **macOS 本地网络授权（TCC）会让 terraform/kubectl 连内网 100% `no route to host`**。
未获授权的**非 Apple 签名**二进制（terraform / kubectl / Homebrew python）访问 LAN 一律
`EHOSTUNREACH`，而 `ping`/`curl`/`ssh`/`nc` 是 Apple 自带故全通：这个差异极具迷惑性，
当年据此误判成「网络正常，是 provider 的锅」。Tailscale 与 loopback 不受限，所以平时无感。
**根治**：系统设置 → 隐私与安全性 → 本地网络，给终端（及 IDE）授权。
不依赖授权的绕法（SSH 隧道 / Tailscale 寻址）已固化进 `proxmox/terraform-storage`。
→ [复盘](../records/2026-08-13-macos-local-network-tcc.md)

## 3. Clone 与接入 kubeconfig

```bash
git clone git@github.com:meirongdev/homelab.git && cd homelab

# homelab（在家庭 LAN 内）：走 pve 跳板
cd k8s/ansible && just fetch-kubeconfig
# 远程（不在 LAN）：改连 Tailscale IP
#   just setup-k8s-remote 只是装集群；fetch 用: ansible-playbook playbooks/fetch-kubeconfig.yaml -e ansible_host=100.94.186.7 -e "ansible_ssh_common_args="

# oracle-k3s：走公网
cd cloud/oracle && just fetch-kubeconfig

# 验证
kubectl --context k3s-homelab get nodes
kubectl --context oracle-k3s get nodes
```

⚠️ 两个集群的 kubeconfig 都要能拿。缺一个不影响改 repo，但 `just argocd-status` /
`just clustermesh-status` 这类跨集群命令会报错。

## 4. 本地验证（提交前跑 CI 同款检查）

```bash
# 全部本地检查（与 CI 同一批脚本），在仓库根跑
just check

# 单跑某一条 / 看哪几条只能靠人
python3 scripts/check-docs.py --list

# 渲染检查：把 ArgoCD 真正会 apply 的对象渲染出来过 schema。
# 单独一条是因为它要联网拉 16 个 chart、约 2 分钟。需要 kubectl / helm / kubeconform。
just check-render
```

**装上 pre-push 钩子**（clone 后一次性，让 `just check` 在 push 前自动跑）：

```bash
git config core.hooksPath .githooks
```

☠️ 它是 **pre-push 不是 pre-commit**，这不是随手选的：`check-docs.py` 的 STAMP 那条按
「该文件最后一次**内容提交**的日期」判定，而未提交的改动没有提交日期 —— 在工作区里改完
就跑，STAMP 永远不报，一 push 就红（真红过两次）。放 pre-push 时改动已经有 commit 日期，
本地与 CI 的判据才一致。单次跳过用 `git push --no-verify`。

## 5. 需要从旧机器带过来的东西（gitignored，新 clone 没有）

- `cloudflare/terraform/.env`：Cloudflare token（justfile `dotenv-load` 注入；裸跑
  `terraform plan` 会读到 tfvars 里的失效值而报错）。
- **有本地 state 的 5 个 root 的 `terraform.tfstate*`**：`proxmox/terraform`、
  `cloudflare/terraform`、`tailscale/terraform`、`cloud/oracle/terraform`、
  `cloud/oracle/cloudflare`。**state 只在本地**（ROADMAP 开放项 #2，未离站）：漏拷哪个，
  那个 root 就只能 `terraform import` 重建（见 `cloud/oracle/terraform/IMPORT.md`）。
  另两个 root（`zitadel/terraform`、`proxmox/terraform-storage`）**当前没有 state 文件**，
  拷不到不是漏了；判据是 `find . -name terraform.tfstate -not -path '*/.terraform/*'`。
- 各 terraform root 的 `terraform.tfvars`（含明文密钥，勿提交）：对着
  `terraform.tfvars.example` 重建或直接拷。

## 6. 可选：Vault 操作

需要动 Vault（解封、写 secret、`create-vault-token`）时，从已解封的 homelab Vault 拿
token（`just vault-init` / `just vault-unseal` 只在 homelab 上跑）。日常 GitOps 不需要。

## 7. 就绪自查

```bash
cd k8s/helm && just status          # monitoring ns 状态
cd k8s/helm && just argocd-status   # 全部 App 的 Sync/Health（条数对 argocd/applications/ 的文件数）
cd cloud/oracle && just clustermesh-status   # 双集群 connected
```

都绿就说明这台机器能正常改、验、推这个 repo 了。
