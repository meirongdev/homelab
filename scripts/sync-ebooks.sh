#!/bin/bash
################################################################################
# sync-ebooks.sh — calibre-web 电子书同步脚本
#
# 将本地电子书同步到 calibre-web 的 ingest 目录（tar | kubectl exec -i，**不是** kubectl cp）。
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
# 2026-08-02: calibre 迁 oracle-k3s（书库 23G，homelab 那台笔记本 VM 磁盘吃紧）。
# 仍可用 --context / KUBE_CONTEXT 覆盖。
KUBE_CONTEXT="${KUBE_CONTEXT:-oracle-k3s}"
NAMESPACE="personal-services"
POD_SELECTOR="app=calibre-web"
INGEST_PATH="/cwa-book-ingest"
DB_PATH="/calibre-library/metadata.db"

# --- 行为 ---
# 2026-09-08 取两份实现的并集：txt/djvu 来自本脚本，cbz/cbr 来自已退役的 sync_ebooks.py。
SUPPORTED_FORMATS=("pdf" "epub" "mobi" "azw" "azw3" "txt" "djvu" "cbz" "cbr")
MODE="check"          # check | upload
DRY_RUN=false
BACKUP=true
CLEANUP=false
VERBOSE=false
FILTER_NON_EBOOKS=true   # 简历/Confluence 导出等；--no-filter-non-ebooks 关掉
RETRY_COUNT=3
LOCK_FILE="/tmp/ebook-sync.lock"

# --- 超时（2026-09-08 从 sync_ebooks.py 并入）---
# 为什么必须有：查询/exec 走 Tailscale，撞上 MTU 黑洞时 TCP 连得上但 TLS handshake 永挂，
# 没有超时的话脚本会静默卡死而不是报错（那个黑洞的判别与修法见
# docs/reference/tailscale-network.md）。
TIMEOUT=60            # kubectl 查询 / exec
CP_TIMEOUT=600        # 单文件传输（大书）

# ============================================================================
# 颜色
# ============================================================================
RED='\033[0;31m'    GREEN='\033[0;32m'    YELLOW='\033[1;33m'
BLUE='\033[0;34m'   NC='\033[0m'

# ============================================================================
# 日志 / 输出
# ============================================================================
# ☠️ 四个日志函数都必须 `|| true` 收尾（2026-09-08 修）：它们管道给 `tee -a "$LOG_FILE"`，
# 日志目录还没建（或不可写）时 tee 返回非零，`set -e` 下**一句告警就能让整个脚本静默退出**。
# 实测踩到：启动时的「无 timeout」告警发生在 mkdir 之前，脚本当场死掉、只留一行 tee 报错。
# 日志函数没有资格终止流程 —— 写不进日志是小事，静默退出不是。
log()    { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
success(){ echo -e "${GREEN}✅ $*${NC}" | tee -a "$LOG_FILE" 2>/dev/null || true; }
warn()   { echo -e "${YELLOW}⚠️  $*${NC}" | tee -a "$LOG_FILE" 2>/dev/null || true; }
error()  { echo -e "${RED}❌ $*${NC}" | tee -a "$LOG_FILE" 2>/dev/null || true; }

# ============================================================================
# 辅助函数
# ============================================================================
load_config() {
  # shellcheck source=/dev/null
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
  # ☠️ 这个 `return 0` 是**整个脚本能不能跑**的关键，别删（2026-09-08 修）：
  # 函数最后一条命令是 `[[ -f ... ]] && ...`，配置文件不存在时它返回 1，成为函数返回值；
  # 在 `set -e` 下这会让脚本在 main() 的第二行**静默退出，exit 1、零输出**。
  # 而 sync-ebooks.conf 从来不在 git 里 —— 所以任何全新克隆上这个脚本都跑不起来，
  # 连带 `just sync-ebooks{,-dry-run,-cleanup,-no-backup}` 四条配方全是空转。
  # 症状极难认：没有报错、没有日志、退出码 1，看着像"没有新书"。
  return 0
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

# ☠️ 循环变量必须 `local`（2026-09-08 修的真缺陷）：原来用的是裸 `f`，而调用它的
# `do_check` 的循环变量也叫 `f`（文件全路径）。bash 里未声明的赋值写的是**调用方**那个
# 局部变量，于是 `is_ebook` 一返回，`$f` 就从 "/path/to/Book.epub" 变成了 "epub"。
# 后果是全链条崩坏且症状完全指错方向：`validate_file "$f"` 收到 "epub" → 报文件不存在
# → 每本书都进"损坏"桶；侥幸过关的还会把字面量 "epub" 写进 pending.txt 去上传。
# 这也是"每本 epub 都损坏"的第二个独立成因（另一个是 validate_epub 的裸 except）。
is_ebook() {
  local ext="${1##*.}"; ext="${ext,,}"
  local fmt
  for fmt in "${SUPPORTED_FORMATS[@]}"; do
    [[ "$ext" == "$fmt" ]] && return 0
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
# kubectl 包装：统一加超时
# ============================================================================
# 两层超时，因为单独任何一层都不够（2026-09-08 实测定的）：
#
# 第一层 `kubectl --request-timeout`：**原生、不依赖外部命令**，所以在这台开发机上
#   也真的生效。它给每个 API 请求加 `?timeout=Ns`，防的是「无限挂死」——正是 Tailscale
#   MTU 黑洞的失败形态（TCP 连得上、TLS handshake 永不返回）。
#   ⚠️ 它**不封顶总时长**：实测拿一个黑洞地址跑 `--request-timeout=3s`，命令总耗时 15s，
#   因为 kubectl 的 discovery 会连发数个请求、每个各自计时。所以别把这个数当墙钟预算。
#
# 第二层外部 `timeout`：唯一能硬封顶总时长的。☠️ **macOS 自带的 BSD 用户态没有它**
#   （GNU coreutils 才有，brew 装完叫 `gtimeout`），本机实测两个都没有。缺了不假装有：
#   启动时告警一次，说明退化成"每请求超时"而不是"总时长超时"。
TIMEOUT_BIN=""
init_timeout_bin() {
  if command -v timeout &>/dev/null; then
    TIMEOUT_BIN="timeout"
  elif command -v gtimeout &>/dev/null; then
    TIMEOUT_BIN="gtimeout"
  else
    warn "无 timeout/gtimeout（brew install coreutils 可补）——超时退化为「每个 API 请求」级"
    warn "  仍能防挂死，但总耗时可能是 --timeout 的数倍（kubectl discovery 会发多个请求）"
  fi
}

# kt <秒> <kubectl 参数...>
kt() {
  local secs="$1"; shift
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$secs" kubectl --context "$KUBE_CONTEXT" --request-timeout="${secs}s" "$@"
  else
    kubectl --context "$KUBE_CONTEXT" --request-timeout="${secs}s" "$@"
  fi
}

# ============================================================================
# 文件完整性验证
# ============================================================================
# 校验失败时往 stdout 打一句原因，返回非零。原因要能直接看懂，
# 「损坏」两个字没法排查（2026-09-08 并入 sync_ebooks.py 的做法）。
#
# ☠️☠️ **绝不要把 `sys.exit()` 放进 `try` 里再配裸 `except:`**（2026-09-08 修的真缺陷）：
# `sys.exit(0)` 抛的是 `SystemExit`，而**裸 `except:` 捕获 BaseException，连它一起吞**，
# 于是走到 `except` 分支变成 `sys.exit(1)` —— 结果是**每一本合法 epub 都被判成损坏**，
# 这个脚本自诞生起就传不上任何 epub。症状看着像"下载的书全坏了"，不像脚本 bug。
# 现在的写法把 exit 移出 try，从结构上不可能再犯。
validate_epub() {
  python3 -c "
import zipfile, sys
reason = ''
try:
    z = zipfile.ZipFile(sys.argv[1])
    bad = z.testzip()                      # 逐条 CRC，抓真截断/坏块
    names = z.namelist()
    if bad:
        reason = 'CRC 坏块: ' + bad
    elif 'mimetype' not in names:
        reason = '缺 mimetype'
    elif z.read('mimetype').decode(errors='replace') != 'application/epub+zip':
        reason = 'mimetype 内容不对'
    elif not any('container.xml' in n for n in names):
        reason = '缺 META-INF/container.xml'
    z.close()
except zipfile.BadZipFile:
    reason = '不是有效的 ZIP'
except Exception as e:
    reason = type(e).__name__ + ': ' + str(e)
if reason:
    print(reason)
sys.exit(1 if reason else 0)
" "$1" 2>/dev/null
}

validate_pdf() {
  local magic
  magic=$(xxd -l 5 -p "$1" 2>/dev/null)
  if [[ "$magic" != "255044462d" ]]; then   # 头部 %PDF-
    echo "缺 %PDF- 头（实际前 5 字节: ${magic:-空})"
    return 1
  fi
  return 0
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

# （原 detect_epub_drm 已删，2026-09-08：定义了但**从未被调用**。留着比删了更坏——
#   读脚本的人会以为 DRM 电子书会被拦下来，实际它们照样上传、然后在 ingest 里静默失败。
#   真要做 DRM 检测得接进 validate_file 并决定「拦下还是只告警」，那是新功能不是合并。）

# ============================================================================
# 扫描本地文件
# ============================================================================
scan_local() {
  local find_expr=()
  local fmt                     # ⚠️ 必须 local，见 is_ebook 的注释
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
# ☠️ 三种失败必须分开报，否则全都长成「没有 pod」：2026-08 的 Tailscale MTU 黑洞下
#    kubectl 连得上但 handshake 永挂，当时这个脚本报的是误导性的 "no Running pod"，
#    白查了一轮 pod 状态。判别与修法 → docs/reference/tailscale-network.md
check_kubectl_ready() {
  if ! command -v kubectl &>/dev/null; then
    error "kubectl 不在 PATH 上"
    return 1
  fi
  if ! kt "$TIMEOUT" cluster-info &>/dev/null; then
    error "连不上集群 $KUBE_CONTEXT（${TIMEOUT}s 内无响应）"
    warn  "  这**不是**「没有 pod」。常见成因：Tailscale MTU 黑洞（TCP 通、TLS handshake 全挂，"
    warn  "  用 \`ping -D -s 1200 <节点>\` 一测就知）、或 6443 被防火墙挡。"
    warn  "  绕法：ssh 到节点用 \`sudo k3s kubectl\`。见 docs/reference/tailscale-network.md"
    return 1
  fi
  local pod; pod=$(get_pod_name)
  if [[ -z "$pod" ]]; then
    error "集群可达，但 $NAMESPACE 里没有 Running 的 pod 匹配 '$POD_SELECTOR'"
    warn  "  用 \`kubectl --context $KUBE_CONTEXT -n $NAMESPACE get pod -l $POD_SELECTOR\` 看真实状态"
    return 1
  fi
  return 0
}

# 只取 Running 的 pod（2026-09-08 从 sync_ebooks.py 并入 --field-selector）。
# 不加这条会挑到 Terminating/Pending 的那个，然后 exec 报一句看不懂的错。
get_pod_name() {
  kt "$TIMEOUT" get pod -n "$NAMESPACE" \
    -l "$POD_SELECTOR" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# --- 传到 pod：tar 打包 → `kubectl exec -i` 的 stdin 解包 ---
# ☠️ 刻意**不用 `kubectl cp`**：它在非 ASCII 文件名上退出码 0 却什么都没拷。
upload_kubectl() {
  local file="$1" dest_dir="$2"
  local pod
  pod=$(get_pod_name) || return 1
  local filename; filename=$(basename "$file")
  local tar_file="/tmp/ebook_${RANDOM}.tar"
  (
    cd "$(dirname "$file")" && tar -cf "$tar_file" "$filename" 2>/dev/null
  ) || return 1
  kt "$CP_TIMEOUT" exec -i -n "$NAMESPACE" "$pod" -- \
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
  remote_cksum=$(kt "$TIMEOUT" exec -n "$NAMESPACE" "$pod" -- \
    sha256sum "${dest}/${filename}" 2>/dev/null | awk '{print $1}')
  [[ "$src_cksum" == "$remote_cksum" ]]
}

# ============================================================================
# 数据库查询（通过 calibre-web pod）
# ============================================================================
query_db() {
  local sql="$1"
  local pod; pod=$(get_pod_name) || return 1
  kt "$TIMEOUT" exec -n "$NAMESPACE" "$pod" -- \
    sqlite3 "$DB_PATH" "$sql" 2>/dev/null
}

# ☠️ **失败必须往外传，不能 `|| true`**（2026-09-08 修）。原来这里吞掉错误，于是一次
#    瞬时 kubectl 失败 → 标题列表为空 → 打印「数据库现有 0 本书」（长得像空书库）→
#    下游 `[[ ${#db_titles[@]} -gt 0 ]]` 这个守卫直接跳过去重 → **整批书重复上传**。
#    退出码是唯一的判据，调用方负责 abort（同已退役的 sync_ebooks.py 的取向）。
get_existing_titles() {
  query_db "SELECT title FROM books ORDER BY title"
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
    log "传输通道: tar | kubectl exec -i（传后校验 sha256）"
  else
    warn "kubectl 不可用，仅做文件检查"
  fi

  # 3. 获取数据库标题列表
  #    ☠️ 查不到就**退出**，不能当成空书库继续：空列表会让下面的去重守卫整段跳过，
  #    结果是整批重复上传。宁可报错让人重跑。
  if [[ "$TRANSPORT" == "kubectl" ]]; then
    log "获取 calibre 数据库书籍列表..."
    local db_raw
    if ! db_raw=$(get_existing_titles); then
      error "读取 calibre 数据库失败（$DB_PATH @ $KUBE_CONTEXT/$NAMESPACE）"
      error "拒绝继续：没有标题列表 = 去重被绕过 = 整批重复入库。"
      exit 1
    fi
    IFS=$'\n' read -r -d '' -a db_titles < <( printf '%s' "$db_raw" && printf '\0' ) || true
    if [[ ${#db_titles[@]} -eq 0 ]]; then
      error "数据库查询成功但返回 0 个标题 —— 这几乎不可能（书库有两万余本）。"
      error "更像是查错了库或 sqlite3 静默失败。拒绝继续（同上，去重会被绕过）。"
      exit 1
    fi
    success "数据库现有 ${#db_titles[@]} 本书"
  else
    error "kubectl 不可用 —— 无法做去重，拒绝继续（详见上面的判别提示）"
    error "只想看本地文件清单可用 \`ls ~/Downloads/books\`；本脚本的检查依赖书库对账。"
    exit 1
  fi

  # 4. 检查 ingest 目录已有文件
  ingest_files=()
  if [[ "$TRANSPORT" == "kubectl" ]]; then
    local pod; pod=$(get_pod_name)
    # ⚠️ 必须走 kt（否则这一句没有超时——2026-09-08 用 bash -x 核对每个 kubectl
    #    调用时发现它是唯一漏网的那个）。
    IFS=$'\n' read -r -d '' -a ingest_files < <(
      kt "$TIMEOUT" exec -n "$NAMESPACE" "$pod" -- \
        sh -c "ls -1 ${INGEST_PATH} 2>/dev/null" && printf '\0'
    ) || true
  fi

  # 5. 分类
  to_upload=();  already_imported=(); in_ingest=(); corrupted=(); filtered=(); corrupted_why=()
  local f fn
  for f in "${all_files[@]}"; do
    fn=$(basename "$f")
    # ⚠️ 命中启发式的文件进 filtered 桶并计数，**不再静默 continue**（2026-09-08）：
    #    原来一本正常书只要名字像简历就无声消失，看输出根本发现不了。
    if [[ $FILTER_NON_EBOOKS == true ]] && is_non_ebook "$fn"; then
      filtered+=("$f"); continue
    fi
    is_ebook "$fn" || continue

    # 文件完整性（失败原因一并记下，"损坏"两个字排查不了）
    local vreason
    if ! vreason=$(validate_file "$f"); then
      corrupted+=("$f")
      corrupted_why+=("$(basename "$f"): ${vreason:-未知原因}")
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
  echo "  🚫 按名过滤:      ${#filtered[@]}$([[ $FILTER_NON_EBOOKS == true ]] || echo '  (过滤已关)')"
  echo ""

  # 损坏的一律带原因列出来（无条件，不看 --verbose）：判成损坏 = 这本书不会被上传，
  # 而 2026-09-08 之前 epub 校验恒假、每本都进这个桶，却没有任何一行说明原因。
  if [[ ${#corrupted_why[@]} -gt 0 ]]; then
    echo "--- 完整性校验未通过，已跳过 ---"
    local why
    for why in "${corrupted_why[@]}"; do echo "  $why"; done
    echo ""
  fi

  # 过滤掉的一律列出来：这是启发式，误伤要看得见（--no-filter-non-ebooks 可关）
  if [[ ${#filtered[@]} -gt 0 ]]; then
    echo "--- 按文件名判为非电子书（简历/导出/工作文档），已跳过 ---"
    local ff
    for ff in "${filtered[@]}"; do echo "  $(basename "$ff")"; done
    echo "  ⚠️ 误伤了？加 --no-filter-non-ebooks 重跑。"
    echo ""
  fi

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
    log "传输通道: tar | kubectl exec -i（传后校验 sha256）"
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
  local success_count=0 fail_count=0
  local cksum_fail=0
  local idx=0

  local file                    # ⚠️ 必须 local，见 is_ebook 的注释
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
  --context NAME            K8s context（默认: oracle-k3s，calibre 2026-08-02 起在那）
  --namespace NS            calibre-web 所在 ns（默认: personal-services）
  --selector SEL            找 pod 的标签选择器（默认: app=calibre-web，只取 Running）
  --ingest-path PATH        pod 内 ingest 目录（默认: /cwa-book-ingest）
  --db-path PATH            pod 内 metadata.db（默认: /calibre-library/metadata.db）
  --backup-dir DIR          本地备份目录
  --exts LIST               逗号分隔的扩展名（覆盖默认列表）
  --timeout SEC             kubectl 查询/exec 超时（默认: 60）
  --cp-timeout SEC          单文件传输超时（默认: 600）
  --dry-run                 模拟运行
  --backup                  备份已导入文件（默认启用）
  --no-backup               禁用备份
  --cleanup                 导入后删除本地文件
  --no-filter-non-ebooks    不按文件名过滤简历/导出件（默认过滤，且会列出被跳过的）
  --verbose                 详细输出
  --help                    显示帮助

示例:
  $(basename "$0") --check
  $(basename "$0") --upload
  $(basename "$0") --upload --backup --cleanup --verbose

说明:
  传输走 \`tar | kubectl exec -i\` 而**不是** \`kubectl cp\`，且传完逐个比对 sha256。
  \`kubectl cp\` 会在非 ASCII 文件名上退出码为 0 却什么都没拷（实测 1/41 个文件、
  32% 字节），所以这里刻意不用它。
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
      --namespace)      NAMESPACE="$2"; shift 2;;
      --selector)       POD_SELECTOR="$2"; shift 2;;
      --ingest-path)    INGEST_PATH="$2"; shift 2;;
      --db-path)        DB_PATH="$2"; shift 2;;
      --backup-dir)     BACKUP_DIR="$2"; shift 2;;
      --exts)           IFS=',' read -r -a SUPPORTED_FORMATS <<< "${2//./}"; shift 2;;
      --timeout)        TIMEOUT="$2"; shift 2;;
      --cp-timeout)     CP_TIMEOUT="$2"; shift 2;;
      --dry-run)        DRY_RUN=true; shift;;
      --backup)         BACKUP=true; shift;;
      --no-backup)      BACKUP=false; shift;;
      --cleanup)        CLEANUP=true; shift;;
      --no-filter-non-ebooks) FILTER_NON_EBOOKS=false; shift;;
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

  # ⚠️ 建目录必须排在**任何会写日志的调用之前**（init_timeout_bin 会告警）：
  # 顺序错了就是上面日志函数注释里那个静默退出。
  mkdir -p "$MANIFEST_DIR"
  mkdir -p "$(dirname "$LOG_FILE")"

  init_timeout_bin
  acquire_lock

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
