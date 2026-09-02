# 仓库根入口 —— 只做两件事：一处看全所有配方，一处冒烟全部 justfile。
#
# 日常仍然可以 `cd k8s/helm && just deploy-cilium`，两种写法等价：`mod` 执行时会切到
# 子目录，所以配方里的相对路径（`values/…`、`../../argocd/…`）行为完全一致（2026-09-02 实测）。
# 从根跑就是 `just helm deploy-cilium`。
#
# 为什么要它：12 个 justfile 散在 8 个目录，`just --list` 一次只看得见一个，
# 新来的人（和 agent）不翻目录树就不知道有哪些配方；CI 的冒烟也从循环变成一条命令。
#
# ⚠️ 加子目录 justfile 时记得在这里加一行 `mod`，否则它不在根的视野里。
# ☠️ 别把实际配方写进本文件：那会制造「同一个操作两个入口」，正是本仓库反复清理的那类重复。

mod ansible 'k8s/ansible/justfile'                    # K3s 装机 / 加 worker / kubeconfig（homelab）
mod helm 'k8s/helm/justfile'                          # 应用部署、Vault、ArgoCD、Cilium（homelab）
mod oracle 'cloud/oracle/justfile'                    # oracle-k3s：节点、CNI、bootstrap、巡检
mod oracle-ansible 'cloud/oracle/ansible/justfile'    # oracle 节点预配剧本
mod oracle-cloudflare 'cloud/oracle/cloudflare/justfile'  # oracle 侧 Tunnel terraform
mod cloudflare 'cloudflare/terraform/justfile'        # homelab 侧 DNS + Tunnel + WAF terraform
mod tailscale 'tailscale/terraform/justfile'          # ACL + 预授权密钥
mod zitadel 'zitadel/terraform/justfile'              # 身份 / SSO terraform
mod proxmox 'proxmox/terraform/justfile'              # pve 上的 VM 预配
mod proxmox-storage 'proxmox/terraform-storage/justfile'  # 106 上的 worker VM 预配
mod proxmox-ansible 'proxmox/ansible/justfile'        # pve / 106 宿主机配置
mod macbook 'macbook/ansible/justfile'                # 远程无头 M2 MacBook

# ⚠️ cloud/oracle/terraform 是全仓库唯一用 make 的 root（`cd cloud/oracle/terraform && make apply`），
# 没有 justfile，所以这里没有它的 mod。

# 渲染检查不在这里：它要联网拉 16 个 chart、约 2 分钟，单独跑 `just check-render`。
# 本仓库的全部本地检查（与 CI 同一批脚本）。push 前跑一遍
check:
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0
    for s in check-docs check-terminology check-manifests check-version-pairs check-public-ips check-embedded-scripts; do
        echo "── $s"
        uv run --with pyyaml python scripts/$s.py || fail=1
    done
    echo "── justfile 冒烟（just --list，含全部子模块）"
    just --list >/dev/null || fail=1
    if [ "$fail" -ne 0 ]; then
        echo ""
        echo "❌ 有检查未通过。规则背景：docs/RULES.md（文档）· docs/reference/manifest-safety-checks.md（清单）"
        exit 1
    fi
    echo ""
    echo "✅ 全部本地检查通过"
    echo "   ⚠️ 结构合规 ≠ 内容正确：文档与集群漂移、值写错层级这两类只能实测。"

# 渲染 ArgoCD 全部 App 并过 schema（要联网 + kubectl/helm/kubeconform，约 2 分钟）
check-render:
    uv run --with pyyaml python scripts/render-manifests.py
