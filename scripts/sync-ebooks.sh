#!/bin/bash
################################################################################
# sync-ebooks.sh — calibre-web 电子书同步脚本
#
# 将本地电子书同步到 calibre-web 的 ingest 目录（kubectl cp）。
# calibre 书库 2026-07-11 迁 local-path（原 NFS 直传路径已失效——
# storage-106 上保留的迁移前快照与 pod 实际挂载的 local-path PVC
# 早已脱钩，rsync 进去会"成功"但书永远进不了 calibre-web）。
# 传输后校验和验证 + 数据库层面确认入库。
#
# 使用:
#   ./sync-ebooks.sh --check           # 仅检查
#   ./sync-ebooks.sh --upload          # 检查 + 上传
#   ./sync-ebooks.sh --upload --cleanup  # 上传成功后删除本地文件
################################################################################
set -euo pipefail

# ============================================================================
# 配置
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/sync-ebooks.conf"

# --- 本地 ---
LOCAL_BOOKS_DIR="${HOME}/Downloads/books"
BACKUP_DIR="${HOME}/.local/share/calibre-web-sync-backup"
MANIFEST_DIR="${HOME}/.local/share/calibre-web-sync"
LOG_FILE="${MANIFEST_DIR}/sync.log"

# --- 传输目标 —— kubectl ---
KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-homelab}"
NAMESPACE="personal-services"
POD_SELECTOR="app=calibre-web"
INGEST_PATH="/cwa-book-ingest"

# --- 行为 ---
SUPPORTED_FORMATS=("pdf" "epub" "mobi" "azw" "azw3" "txt" "djvu")
MODE="check"          # check | upload
DRY_RUN=false
BACKUP=true
CLEANUP=false
VERBOSE=false
RETRY_COUNT=3
LOCK_FILE="/tmp/ebook-sync.lock"

# ============================================================================
# 颜色
# ============================================================================
RED='\033[0;31m'    GREEN='\033[0;32m'    YELLOW='\033[1;33m'
BLUE='\033[0;34m'   CYAN='\033[0;36m'     NC='\033[0m'

# ============================================================================
# 日志 / 输出
# ============================================================================
log()    { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
success(){ echo -e "${GREEN}✅ $*${NC}" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}⚠️  $*${NC}" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}❌ $*${NC}" | tee -a "$LOG_FILE"; }

# ============================================================================
# 辅助函数
# ============================================================================
load_config() {
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
}

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      error "另一个同步进程 (PID $pid) 正在运行，退出"
      exit 1
    fi
    warn "发现过期锁文件，移除"
  fi
  echo "$$" > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
}

normalize_title() {
  local t="$1"
  t="${t%.*}"                                # 移除扩展名
  t=$(echo "$t" | sed -E '
    s/ \([^)]*\)//g;                         # 移除 (Author)
    s/ \[[^]]*\]//g;                         # 移除 [Z-Library]
    s/ - [^-]*$//;                           # 尾部 - something
    s/[[:punct:]]/ /g;                       # 标点变空格
    s/[[:space:]]+/ /g;                      # 合并空格
  ')
  echo "${t,,}" | xargs                       # 小写 + trim
}

is_ebook() {
  local ext="${1##*.}"; ext="${ext,,}"
  for f in "${SUPPORTED_FORMATS[@]}"; do
    [[ "$ext" == "$f" ]] && return 0
  done
  return 1
}

is_non_ebook() {
  local fn="$1"
  # 简历
  [[ "$fn" =~ ^(BE|SRE|PM|QA)_ ]] && return 0
  [[ "$fn" =~ ^(LinkedIn|Resume|CV|简历|履历) ]] && return 0
  # Confluence 导出
  [[ "$fn" =~ -[0-9]{6}-[0-9]{6}\. ]] && return 0
  [[ "$fn" =~ confluence ]] && return 0
  # 工作文档
  [[ "$fn" =~ ^(fee|endpoint|finance|invoice) ]] && return 0
  return 1
}

checksum()  { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# ============================================================================
# 文件完整性验证
# ============================================================================
validate_epub() {
  local f="$1"
  python3 -c "
import zipfile, sys
try:
    z=zipfile.ZipFile(sys.argv[1])
    if 'mimetype' not in z.namelist(): sys.exit(1)
    if z.read('mimetype').decode()!='application/epub+zip': sys.exit(1)
    z.close()
    sys.exit(0)
except: sys.exit(1)
" "$f" 2>/dev/null
}

validate_pdf() {
  local f="$1"
  local magic
  magic=$(xxd -l 5 -p "$f" 2>/dev/null)
  [[ "$magic" == "255044462d" ]]  # 头部 %PDF-
}

validate_file() {
  local f="$1"
  local ext="${f##*.}"; ext="${ext,,}"
  case "$ext" in
    epub) validate_epub "$f";;
    pdf)  validate_pdf "$f";;
    *)    return 0;;  # 其他格式跳过验证
  esac
}

detect_epub_drm() {
  python3 -c "
import zipfile, sys
try:
    z=zipfile.ZipFile(sys.argv[1])
    files=z.namelist()
    if 'META-INF/encryption.xml' in files:
        print('ADOBE_DRM'); sys.exit(2)
    z.close()
    sys.exit(0)
except: sys.exit(1)
" "$1" 2>/dev/null
}

# ============================================================================
# 扫描本地文件
# ============================================================================
scan_local() {
  local find_expr=()
  for fmt in "${SUPPORTED_FORMATS[@]}"; do
    find_expr+=(-o -iname "*.$fmt")
  done
  find_expr=("${find_expr[@]:1}")  # 去掉首个 -o
  find "$LOCAL_BOOKS_DIR" -maxdepth 1 -type f \( "${find_expr[@]}" \) 2>/dev/null | sort
}

# ============================================================================
# 传输层
# ============================================================================

# --- 检测可用的传输通道 ---
check_kubectl_ready() {
  command -v kubectl &>/dev/null || return 1
  kubectl --context "$KUBE_CONTEXT" cluster-info &>/dev/null || return 1
  local pod
  pod=$(kubectl --context "$KUBE_CONTEXT" get pod -n "$NAMESPACE" \
    -l "$POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n "$pod" ]]
}

get_pod_name() {
  kubectl --context "$KUBE_CONTEXT" get pod -n "$NAMESPACE" \
    -l "$POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# --- kubectl cp 到 pod ---
upload_kubectl() {
  local file="$1" dest_dir="$2"
  local pod
  pod=$(get_pod_name) || return 1
  local filename; filename=$(basename "$file")
  local tar_file="/tmp/ebook_${RANDOM}.tar"
  (
    cd "$(dirname "$file")" && tar -cf "$tar_file" "$filename" 2>/dev/null
  ) || return 1
  kubectl --context "$KUBE_CONTEXT" exec -i -n "$NAMESPACE" "$pod" -- \
    sh -c "cd ${dest_dir} && tar xf -" < "$tar_file" 2>/dev/null
  local rc=$?; rm -f "$tar_file"; return $rc
}

# --- 带重试的上传 ---
upload_file() {
  local file="$1" dest="$2"
  local attempt=0 rc=1

  while (( attempt < RETRY_COUNT )); do
    ((attempt++))
    upload_kubectl "$file" "$dest"
    rc=$?
    [[ $rc -eq 0 ]] && break
    [[ $attempt -lt $RETRY_COUNT ]] && sleep $(( attempt * 3 ))
  done
  return $rc
}

# --- 传输后校验 ---
verify_transfer() {
  local file="$1" dest="$2"
  local filename; filename=$(basename "$file")
  local src_cksum; src_cksum=$(checksum "$file")

  local pod; pod=$(get_pod_name) || return 1
  local remote_cksum
  remote_cksum=$(kubectl --context "$KUBE_CONTEXT" exec -n "$NAMESPACE" "$pod" -- \
    sha256sum "${dest}/${filename}" 2>/dev/null | awk '{print $1}')
  [[ "$src_cksum" == "$remote_cksum" ]]
}

# ============================================================================
# 数据库查询（通过 calibre-web pod）
# ============================================================================
query_db() {
  local sql="$1"
  local pod; pod=$(get_pod_name) || return 1
  kubectl --context "$KUBE_CONTEXT" exec -n "$NAMESPACE" "$pod" -- \
    sqlite3 /calibre-library/metadata.db "$sql" 2>/dev/null
}

get_existing_titles() {
  query_db "SELECT title FROM books ORDER BY title" 2>/dev/null || true
}

get_db_book_count() {
  query_db "SELECT COUNT(*) FROM books" 2>/dev/null || echo "0"
}

# ============================================================================
# 检查重复
# ============================================================================
is_already_imported() {
  local filename="$1"; shift
  local titles=("$@")
  local norm; norm=$(normalize_title "$filename")
  [[ -z "$norm" ]] && return 1
  local t
  for t in "${titles[@]}"; do
    local norm_t; norm_t=$(normalize_title "$t")
    [[ "$norm" == "$norm_t" ]] && return 0
  done
  return 1
}

# ============================================================================
# 检查流程
# ============================================================================
do_check() {
  echo ""; echo "╔════════════════════════════════════════════════════╗"
  echo "║       calibre-web 电子书同步 — 检查模式             ║"
  echo "╚════════════════════════════════════════════════════╝"; echo ""

  mkdir -p "$MANIFEST_DIR"

  # 1. 扫描本地
  log "扫描本地目录: $LOCAL_BOOKS_DIR"
  IFS=$'\n' read -r -d '' -a all_files < <( scan_local && printf '\0' )
  local total=${#all_files[@]}

  if [[ $total -eq 0 ]]; then
    warn "未找到电子书文件"
    return 0
  fi
  success "本地找到 $total 本电子书"

  # 2. 连接目标
  TRANSPORT=""
  if check_kubectl_ready; then
    TRANSPORT="kubectl"
    log "传输通道: kubectl cp"
  else
    warn "kubectl 不可用，仅做文件检查"
  fi

  # 3. 获取数据库标题列表
  if [[ "$TRANSPORT" == "kubectl" ]]; then
    log "获取 calibre 数据库书籍列表..."
    IFS=$'\n' read -r -d '' -a db_titles < <( get_existing_titles && printf '\0' ) || true
    success "数据库现有 ${#db_titles[@]} 本书"
  else
    db_titles=()
    warn "跳过数据库查询（kubectl 不可用）"
  fi

  # 4. 检查 ingest 目录已有文件
  ingest_files=()
  if [[ "$TRANSPORT" == "kubectl" ]]; then
    local pod; pod=$(get_pod_name)
    IFS=$'\n' read -r -d '' -a ingest_files < <(
      kubectl --context "$KUBE_CONTEXT" exec -n "$NAMESPACE" "$pod" -- \
        sh -c "ls -1 ${INGEST_PATH} 2>/dev/null" && printf '\0'
    ) || true
  fi

  # 5. 分类
  to_upload=();  already_imported=(); in_ingest=(); corrupted=()
  local f fn
  for f in "${all_files[@]}"; do
    fn=$(basename "$f")
    is_non_ebook "$fn" && continue
    is_ebook "$fn" || continue

    # 文件完整性
    if ! validate_file "$f"; then
      corrupted+=("$f")
      continue
    fi

    # 在 ingest 中?
    local found_ingest=false
    local ifn
    for ifn in "${ingest_files[@]}"; do
      [[ "$fn" == "$ifn" ]] && { found_ingest=true; break; }
    done
    $found_ingest && { in_ingest+=("$f"); continue; }

    # 在数据库?
    if [[ ${#db_titles[@]} -gt 0 ]]; then
      is_already_imported "$fn" "${db_titles[@]}" && { already_imported+=("$f"); continue; }
    fi

    to_upload+=("$f")
  done

  # 6. 输出
  echo ""; echo "════════════════════════════════════════════════════"
  echo "  检查结果"
  echo "════════════════════════════════════════════════════"
  echo "  总计扫描:        $total"
  echo "  ✅ 已入库:        ${#already_imported[@]}"
  echo "  ⏳ 处理中 (ingest): ${#in_ingest[@]}"
  echo "  📤 待上传:        ${#to_upload[@]}"
  echo "  ❌ 文件损坏:      ${#corrupted[@]}"
  echo ""

  [[ $VERBOSE == true ]] && show_verbose_list to_upload in_ingest already_imported corrupted

  # 保存状态供 upload 阶段使用
  echo "${#to_upload[@]}" > "${MANIFEST_DIR}/pending.count"
  printf '%s\n' "${to_upload[@]}" > "${MANIFEST_DIR}/pending.txt"
  printf '%s\n' "${corrupted[@]}" > "${MANIFEST_DIR}/corrupted.txt"
}

show_verbose_list() {
  local -n arr=$1
  local label="待上传"
  case $1 in
    to_upload) label="待上传";;
    in_ingest) label="Ingest 中";;
    already_imported) label="已导入";;
    corrupted) label="损坏";;
  esac
  echo "--- $label (${#arr[@]}) ---"
  local item
  for item in "${arr[@]}"; do
    echo "  $(basename "$item")"
  done
  echo ""
}

# ============================================================================
# 上传流程
# ============================================================================
do_upload() {
  echo ""; echo "╔════════════════════════════════════════════════════╗"
  echo "║       calibre-web 电子书同步 — 上传模式             ║"
  echo "╚════════════════════════════════════════════════════╝"; echo ""

  # 如果没跑过 check，先跑
  if [[ ! -f "${MANIFEST_DIR}/pending.txt" ]]; then
    do_check
  fi

  mapfile -t pending < "${MANIFEST_DIR}/pending.txt" 2>/dev/null || true
  local total=${#pending[@]}
  if [[ $total -eq 0 ]]; then
    success "没有待上传的文件"
    rm -f "${MANIFEST_DIR}/pending.txt"
    return 0
  fi

  # 选择传输通道
  if check_kubectl_ready; then
    TRANSPORT="kubectl"
    DEST_DIR="$INGEST_PATH"
    log "传输通道: kubectl cp"
  else
    error "kubectl 不可用，无法上传"
    return 1
  fi

  # 获取上传前的数据库书籍数
  local pre_count; pre_count=$(get_db_book_count)

  # 确认
  echo ""
  warn "即将上传 $total 本电子书 → $TRANSPORT:$DEST_DIR"
  [[ $BACKUP == true ]] && echo "  备份目录: $BACKUP_DIR"
  [[ $CLEANUP == true ]] && echo "  导入后删除本地文件: 是"
  echo ""
  [[ $DRY_RUN == false ]] && { read -p "确认执行? (y/N): " -r; echo; [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "已取消"; return 0; } }

  # 备份
  if [[ $BACKUP == true && $DRY_RUN == false ]]; then
    mkdir -p "$BACKUP_DIR"
  fi

  # 批量上传
  local success_count=0 fail_count=0 skip_count=0
  local cksum_fail=0
  local idx=0

  for file in "${pending[@]}"; do
    ((idx++))
    local fn; fn=$(basename "$file")
    local filesize; filesize=$(du -h "$file" | awk '{print $1}')
    printf "  [%d/%d] %s ... " "$idx" "$total" "${fn:0:60}"

    if [[ $DRY_RUN == true ]]; then
      echo -e "${YELLOW}🟡 dry-run${NC}"
      continue
    fi

    # 上传 + 重试
    if upload_file "$file" "$DEST_DIR"; then
      # 校验和验证
      if verify_transfer "$file" "$DEST_DIR"; then
        echo -e "${GREEN}✅  ${filesize}${NC}"
        ((success_count++))
        # 备份
        [[ $BACKUP == true ]] && cp "$file" "$BACKUP_DIR/" 2>/dev/null
        # 可选 cleanup
        [[ $CLEANUP == true ]] && rm -f "$file"
      else
        echo -e "${RED}❌ checksum 不匹配${NC}"
        ((cksum_fail++))
        ((fail_count++))
      fi
    else
      echo -e "${RED}❌ 上传失败${NC}"
      ((fail_count++))
    fi
  done

  # 上报统计
  echo ""; success "上传完成"
  echo "  ✅ 成功: $success_count"
  echo "  ❌ 失败: $fail_count"
  [[ $cksum_fail -gt 0 ]] && warn "  校验和失败: $cksum_fail"

  # 验证导入
  echo ""; echo "════════════════════════════════════════════════════"
  echo "  导入验证"
  echo "════════════════════════════════════════════════════"
  local post_count; post_count=$(get_db_book_count)
  local diff=$(( post_count - pre_count ))
  log "数据库: 上传前 ${pre_count} 本 → 当前 ${post_count} 本 (新增 ${diff})"

  # 查询新入库的书名
  if [[ $diff -gt 0 ]]; then
    local new_titles
    new_titles=$(query_db "SELECT title FROM books ORDER BY id DESC LIMIT ${diff}" 2>/dev/null)
    echo "  最近入库:"
    echo "$new_titles" | head -10 | while IFS= read -r line; do
      [[ -n "$line" ]] && echo "    · $line"
    done
    [[ $(echo "$new_titles" | wc -l) -gt 10 ]] && echo "    ... 还有更多"
  fi

  rm -f "${MANIFEST_DIR}/pending.txt"
}

# ============================================================================
# CLI
# ============================================================================
usage() {
  cat << EOF
使用方法: $(basename "$0") [选项]

模式:
  --check                   仅检查（默认）
  --upload                  检查 + 上传

选项:
  --source DIR              源目录（默认: ~/Downloads/books）
  --context NAME            K8s context（默认: k3s-homelab）
  --dry-run                 模拟运行
  --backup                  备份已导入文件（默认启用）
  --no-backup               禁用备份
  --cleanup                 导入后删除本地文件
  --verbose                 详细输出
  --help                    显示帮助

示例:
  $(basename "$0") --check
  $(basename "$0") --upload
  $(basename "$0") --upload --backup --cleanup --verbose
EOF
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --check)          MODE="check"; shift;;
      --upload)         MODE="upload"; shift;;
      --source)         LOCAL_BOOKS_DIR="$2"; shift 2;;
      --context)        KUBE_CONTEXT="$2"; shift 2;;
      --dry-run)        DRY_RUN=true; shift;;
      --backup)         BACKUP=true; shift;;
      --no-backup)      BACKUP=false; shift;;
      --cleanup)        CLEANUP=true; shift;;
      --verbose)        VERBOSE=true; shift;;
      -h|--help)        usage;;
      *)                error "未知选项: $1"; usage;;
    esac
  done
}

# ============================================================================
# 主入口
# ============================================================================
main() {
  parse_args "$@"
  load_config
  acquire_lock

  mkdir -p "$MANIFEST_DIR"
  mkdir -p "$(dirname "$LOG_FILE")"
  [[ $BACKUP == true ]] && mkdir -p "$BACKUP_DIR"

  if [[ ! -d "$LOCAL_BOOKS_DIR" ]]; then
    error "源目录不存在: $LOCAL_BOOKS_DIR"
    exit 1
  fi

  do_check

  if [[ "$MODE" == "upload" ]]; then
    do_upload
  fi

  success "完成"
}

main "$@"
