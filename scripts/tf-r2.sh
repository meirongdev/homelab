#!/usr/bin/env bash
# terraform 的包装：带上 R2 远程后端的凭据，再 exec terraform。
#
# 全部 terraform root 的 justfile 都经它调 terraform；日常入口是
# `just <root> tf <子命令…>`（如 `just oracle-terraform tf output -raw instance_public_ip`），
# 不必直接调本脚本。它在当前目录运行，和直接敲 terraform 一样。
# 事实与踩坑：docs/reference/terraform-state.md
#
# 做两件事：
#   1. 凭据：三个 AWS_* 变量从 Vault secret/homelab/terraform-r2 现取，只活在本进程里。
#      ☠️ 三个都已在环境里时**不碰 Vault**：这是 break-glass 入口。Vault 跑在 homelab
#      集群上，而 proxmox root 恰恰是重建那台 VM 用的；Vault 不在时去 Cloudflare 控制台
#      另建一枚 token、手动 export 三个变量即可。
#   2. 快照：R2 没有对象版本，远程后端也不像本地后端那样留 terraform.tfstate.backup。
#      所以会改 state 的子命令先把当前 state 拉一份到 .tfstate-snapshots/（gitignored，
#      含明文密钥，只留最近 20 份）。拉不下来就中止，不带着失明去改。
set -euo pipefail

vault_path=secret/homelab/terraform-r2
snapshot_dir=.tfstate-snapshots
snapshot_keep=20

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${AWS_ENDPOINT_URL_S3:-}" ]]; then
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.meirong.dev}"
  if ! creds="$(vault kv get -format=json "$vault_path")"; then
    echo "tf-r2: 读不到 Vault $vault_path（见上方报错）。Vault 不可用时的 break-glass 见 docs/reference/terraform-state.md" >&2
    exit 1
  fi
  AWS_ACCESS_KEY_ID="$(jq -er '.data.data.access_key_id' <<<"$creds")"
  AWS_SECRET_ACCESS_KEY="$(jq -er '.data.data.secret_access_key' <<<"$creds")"
  AWS_ENDPOINT_URL_S3="$(jq -er '.data.data.endpoint' <<<"$creds")"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ENDPOINT_URL_S3
fi
# 本机若配过真 AWS 的 profile / 会话 token，别让它们混进对 R2 的签名。
unset AWS_PROFILE AWS_SESSION_TOKEN

mutates=false
case "${1:-}" in
  apply | destroy | import | taint | untaint) mutates=true ;;
  state)
    case "${2:-}" in
      rm | mv | push | replace-provider) mutates=true ;;
    esac
    ;;
esac

if [[ "$mutates" == true ]]; then
  umask 077
  mkdir -p "$snapshot_dir"
  # 带 PID：同一秒内连跑两次（如 oracle 的 import 配方连跑 6 次）不会互相覆盖。
  snap="$snapshot_dir/$(date +%Y%m%dT%H%M%S)-$$.tfstate"
  if ! terraform state pull >"$snap"; then
    rm -f "$snap"
    echo "tf-r2: 改 state 之前拉快照失败，已中止（没有执行 terraform $*）" >&2
    exit 1
  fi
  echo "tf-r2: 改动前的 state 快照 → $PWD/$snap" >&2
  # 文件名以定长时间戳开头，glob 的字典序就是时间序：删掉最旧的那些，只留 snapshot_keep 份。
  snaps=("$snapshot_dir"/*.tfstate)
  if ((${#snaps[@]} > snapshot_keep)); then
    for old in "${snaps[@]:0:${#snaps[@]}-snapshot_keep}"; do rm -f -- "$old"; done
  fi
fi

exec terraform "$@"
