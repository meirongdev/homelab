#!/bin/bash

################################################################################
# calibre-web 电子书同步脚本
# 
# 功能：将本地电子书目录中的文件同步到 calibre-web 服务
# 
# 使用: ./ebook-sync.sh [选项]
#      ./ebook-sync.sh --source ~/Downloads --check-only
#      ./ebook-sync.sh --source ~/Downloads --upload
################################################################################

set -euo pipefail

# ============================================================================
# 配置
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/ebook-sync.conf"

# 默认值
SOURCE_DIR="${HOME}/Downloads"
KUBECONFIG_CONTEXT="k3s-homelab"
NAMESPACE="personal-services"
DEPLOYMENT="calibre-web"
INGEST_DIR="/cwa-book-ingest"
TEMP_DIR="/tmp/ebook-sync-$$"
LOG_FILE="${TEMP_DIR}/sync.log"

# 支持的电子书格式
EBOOK_FORMATS=("pdf" "epub" "mobi" "azw" "azw3" "txt" "djvu" "cbz" "cbr")

# 操作模式
MODE="check"  # check, upload, cleanup
DRY_RUN=false
VERBOSE=false

# ============================================================================
# 颜色和输出
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "${LOG_FILE}"
}

success() {
    echo -e "${GREEN}✅ $*${NC}" | tee -a "${LOG_FILE}"
}

error() {
    echo -e "${RED}❌ $*${NC}" | tee -a "${LOG_FILE}"
}

warning() {
    echo -e "${YELLOW}⚠️  $*${NC}" | tee -a "${LOG_FILE}"
}

# ============================================================================
# 辅助函数
# ============================================================================

load_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        log "加载配置文件: ${CONFIG_FILE}"
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
    fi
}

validate_source_dir() {
    if [ ! -d "${SOURCE_DIR}" ]; then
        error "源目录不存在: ${SOURCE_DIR}"
        exit 1
    fi
    success "源目录验证: ${SOURCE_DIR}"
}

validate_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        error "kubectl 未安装"
        exit 1
    fi
    
    if ! kubectl --context "${KUBECONFIG_CONTEXT}" cluster-info &> /dev/null; then
        error "无法连接到 Kubernetes 集群: ${KUBECONFIG_CONTEXT}"
        exit 1
    fi
    
    success "Kubernetes 连接验证成功"
}

check_pod_running() {
    local pod_name
    pod_name=$(kubectl --context "${KUBECONFIG_CONTEXT}" get pod \
        -n "${NAMESPACE}" \
        -l app="${DEPLOYMENT}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "${pod_name}" ]; then
        error "找不到运行中的 ${DEPLOYMENT} Pod"
        exit 1
    fi
    
    echo "${pod_name}"
}

is_ebook() {
    local file="$1"
    local ext="${file##*.}"
    ext="${ext,,}"  # 转换为小写
    
    for format in "${EBOOK_FORMATS[@]}"; do
        if [ "${ext}" = "${format}" ]; then
            return 0
        fi
    done
    return 1
}

is_non_ebook() {
    local filename="$1"
    
    # 简历类
    if [[ "${filename}" =~ ^[A-Z]{1,2}_ ]] || [[ "${filename}" =~ LinkedIn_ ]] || [[ "${filename}" =~ resume|cv|履历|简历 ]]; then
        return 0
    fi
    
    # Confluence 导出
    if [[ "${filename}" =~ -[0-9]{6}-[0-9]{6}\. ]] || [[ "${filename}" =~ confluence ]]; then
        return 0
    fi
    
    # 工作文档
    if [[ "${filename}" =~ fee|endpoint|finance ]] || [[ "${filename}" =~ \.[txt]$ ]]; then
        return 0
    fi
    
    return 1
}

get_calibre_books() {
    local pod_name="$1"
    
    log "获取 calibre-web 中的书籍列表..."
    kubectl --context "${KUBECONFIG_CONTEXT}" exec -n "${NAMESPACE}" "${pod_name}" -- \
        sqlite3 /calibre-library/metadata.db \
        "SELECT title FROM books ORDER BY title;" 2>/dev/null || true
}

get_ingest_files() {
    local pod_name="$1"
    
    kubectl --context "${KUBECONFIG_CONTEXT}" exec -n "${NAMESPACE}" "${pod_name}" -- \
        sh -c 'ls /cwa-book-ingest/ 2>/dev/null' | sort || true
}

normalize_title() {
    local title="$1"
    # 移除文件扩展名
    title="${title%.*}"
    # 移除作者信息 (parentheses 内的内容)
    title=$(echo "${title}" | sed 's/ ([^)]*) / /g' | sed 's/ ([^)]*)$//g')
    # 转小写
    echo "${title,,}" | xargs
}

is_already_imported() {
    local filename="$1"
    local calibre_books="$2"
    
    local normalized_filename
    normalized_filename=$(normalize_title "${filename}")
    
    while IFS= read -r book; do
        [ -z "${book}" ] && continue
        local normalized_book
        normalized_book=$(normalize_title "${book}")
        
        if [ "${normalized_filename}" = "${normalized_book}" ]; then
            return 0
        fi
    done <<< "${calibre_books}"
    
    return 1
}

# ============================================================================
# 主要操作
# ============================================================================

scan_local_files() {
    log "扫描本地电子书文件..."
    
    local ebook_count=0
    local non_ebook_count=0
    local other_count=0
    
    local ebook_file="${TEMP_DIR}/ebooks.txt"
    local non_ebook_file="${TEMP_DIR}/non-ebooks.txt"
    local other_file="${TEMP_DIR}/others.txt"
    
    : > "${ebook_file}"
    : > "${non_ebook_file}"
    : > "${other_file}"
    
    while IFS= read -r -d '' file; do
        local filename
        filename=$(basename "${file}")
        
        if is_ebook "${file}"; then
            echo "${filename}" >> "${ebook_file}"
            ((ebook_count++))
        elif is_non_ebook "${filename}"; then
            echo "${filename}" >> "${non_ebook_file}"
            ((non_ebook_count++))
        else
            echo "${filename}" >> "${other_file}"
            ((other_count++))
        fi
    done < <(find "${SOURCE_DIR}" -maxdepth 1 -type f -print0 | sort -z)
    
    echo "${ebook_count}" > "${TEMP_DIR}/ebook_count.txt"
    echo "${non_ebook_count}" > "${TEMP_DIR}/non_ebook_count.txt"
    echo "${other_count}" > "${TEMP_DIR}/other_count.txt"
    
    success "本地文件扫描完成"
    echo "  📚 电子书: ${ebook_count} 个"
    echo "  ❌ 非电子书: ${non_ebook_count} 个"
    echo "  ❓ 其他文件: ${other_count} 个"
}

check_imported_status() {
    log "检查已导入状态..."
    
    local pod_name
    pod_name=$(check_pod_running)
    
    # 获取 calibre 中的书籍
    local calibre_books
    calibre_books=$(get_calibre_books "${pod_name}")
    
    # 获取 ingest 中的文件
    local ingest_files
    ingest_files=$(get_ingest_files "${pod_name}")
    
    # 处理电子书列表
    local ebook_file="${TEMP_DIR}/ebooks.txt"
    local new_file="${TEMP_DIR}/new_ebooks.txt"
    local already_imported="${TEMP_DIR}/already_imported.txt"
    local in_ingest="${TEMP_DIR}/in_ingest.txt"
    
    : > "${new_file}"
    : > "${already_imported}"
    : > "${in_ingest}"
    
    local new_count=0
    local imported_count=0
    local ingest_count=0
    
    while IFS= read -r filename; do
        [ -z "${filename}" ] && continue
        
        # 检查是否在 ingest 中
        if echo "${ingest_files}" | grep -q "^${filename}$"; then
            echo "${filename}" >> "${in_ingest}"
            ((ingest_count++))
            continue
        fi
        
        # 检查是否已导入
        if is_already_imported "${filename}" "${calibre_books}"; then
            echo "${filename}" >> "${already_imported}"
            ((imported_count++))
        else
            echo "${filename}" >> "${new_file}"
            ((new_count++))
        fi
    done < "${ebook_file}"
    
    success "导入状态检查完成"
    echo "  ✅ 已导入: ${imported_count} 本"
    echo "  ⏳ ingest 中: ${ingest_count} 个"
    echo "  📤 待上传: ${new_count} 个"
}

show_check_results() {
    log "显示检查结果..."
    
    local ebook_count
    ebook_count=$(cat "${TEMP_DIR}/ebook_count.txt")
    local new_count
    new_count=$(wc -l < "${TEMP_DIR}/new_ebooks.txt")
    local imported_count
    imported_count=$(wc -l < "${TEMP_DIR}/already_imported.txt")
    local ingest_count
    ingest_count=$(wc -l < "${TEMP_DIR}/in_ingest.txt")
    
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "📊 扫描结果总结"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "本地电子书统计:"
    echo "  总计: ${ebook_count} 个"
    echo "  ✅ 已导入: ${imported_count} 本"
    echo "  ⏳ 处理中 (ingest): ${ingest_count} 个"
    echo "  📤 新增: ${new_count} 个"
    echo ""
    
    if [ "${new_count}" -gt 0 ]; then
        echo "待上传的新书 (前 10 个):"
        head -10 "${TEMP_DIR}/new_ebooks.txt" | sed 's/^/  - /'
        if [ "${new_count}" -gt 10 ]; then
            echo "  ... 还有 $((new_count - 10)) 个"
        fi
        echo ""
    fi
    
    echo "====════════════════════════════════════════════════════════=="
}

upload_ebooks() {
    log "开始上传电子书..."
    
    local pod_name
    pod_name=$(check_pod_running)
    
    local ebook_file="${TEMP_DIR}/new_ebooks.txt"
    local success_file="${TEMP_DIR}/upload_success.txt"
    local failed_file="${TEMP_DIR}/upload_failed.txt"
    
    : > "${success_file}"
    : > "${failed_file}"
    
    if [ ! -s "${ebook_file}" ]; then
        warning "没有新书需要上传"
        return
    fi
    
    local total
    total=$(wc -l < "${ebook_file}")
    local count=0
    local success_count=0
    local failed_count=0
    
    echo "上传进度:"
    
    while IFS= read -r filename; do
        [ -z "${filename}" ] && continue
        ((count++))
        
        local filepath="${SOURCE_DIR}/${filename}"
        
        if upload_single_file "${pod_name}" "${filepath}" "${filename}"; then
            echo "${filename}" >> "${success_file}"
            ((success_count++))
            echo "  [${count}/${total}] ✅ ${filename:0:60}"
        else
            echo "${filename}" >> "${failed_file}"
            ((failed_count++))
            echo "  [${count}/${total}] ❌ ${filename:0:60}"
        fi
    done < "${ebook_file}"
    
    echo ""
    success "上传完成"
    echo "  ✅ 成功: ${success_count} 个"
    echo "  ❌ 失败: ${failed_count} 个"
}

upload_single_file() {
    local pod_name="$1"
    local filepath="$2"
    local filename="$3"
    
    if [ "${DRY_RUN}" = true ]; then
        return 0
    fi
    
    # 创建单个文件的 tar 包并上传
    local tar_file="/tmp/ebook_${RANDOM}.tar"
    
    (
        cd "$(dirname "${filepath}")" || return 1
        tar -cf "${tar_file}" "$(basename "${filepath}")" 2>/dev/null
    ) || return 1
    
    # 上传并提取
    if kubectl --context "${KUBECONFIG_CONTEXT}" exec -i -n "${NAMESPACE}" "${pod_name}" -- \
        sh -c "cd ${INGEST_DIR} && tar -xf -" < "${tar_file}" 2>/dev/null; then
        rm -f "${tar_file}"
        return 0
    else
        rm -f "${tar_file}"
        return 1
    fi
}

# ============================================================================
# 清理
# ============================================================================

cleanup() {
    if [ -d "${TEMP_DIR}" ] && [ "${VERBOSE}" = false ]; then
        rm -rf "${TEMP_DIR}"
    fi
}

show_temp_location() {
    if [ "${VERBOSE}" = true ]; then
        echo ""
        echo "临时文件位置: ${TEMP_DIR}"
        echo "关键文件:"
        echo "  - ebooks.txt: 本地电子书列表"
        echo "  - new_ebooks.txt: 新增电子书（待上传）"
        echo "  - already_imported.txt: 已导入书籍"
        echo "  - sync.log: 详细日志"
    fi
}

# ============================================================================
# 主程序
# ============================================================================

usage() {
    cat << EOF
使用方法: $(basename "$0") [选项]

选项:
  --source DIR              指定源目录（默认: ~/Downloads）
  --context CONTEXT         Kubernetes 上下文（默认: k3s-homelab）
  --check-only              仅检查，不执行上传（默认）
  --upload                  执行上传操作
  --dry-run                 模拟运行，不实际上传
  --verbose                 详细输出模式
  --help                    显示此帮助信息

示例:
  # 仅检查 ~/Downloads 中的电子书
  $(basename "$0") --source ~/Downloads --check-only

  # 上传新的电子书
  $(basename "$0") --source ~/Downloads --upload

  # 模拟上传（预览）
  $(basename "$0") --source ~/Downloads --upload --dry-run --verbose

配置文件:
  可在 $(dirname "$0")/ebook-sync.conf 中配置默认参数
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --source)
                SOURCE_DIR="$2"
                shift 2
                ;;
            --context)
                KUBECONFIG_CONTEXT="$2"
                shift 2
                ;;
            --check-only)
                MODE="check"
                shift
                ;;
            --upload)
                MODE="upload"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                error "未知选项: $1"
                usage
                exit 1
                ;;
        esac
    done
}

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║         calibre-web 电子书同步工具 v1.0                   ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    parse_args "$@"
    
    # 创建临时目录
    mkdir -p "${TEMP_DIR}"
    
    trap cleanup EXIT
    
    # 初始化
    load_config
    validate_source_dir
    validate_kubectl
    
    # 执行操作
    scan_local_files
    check_imported_status
    show_check_results
    
    if [ "${MODE}" = "upload" ]; then
        if [ "${DRY_RUN}" = true ]; then
            warning "DRY RUN 模式 - 不会实际上传文件"
        fi
        echo ""
        read -p "确认执行上传操作? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            upload_ebooks
        else
            warning "已取消上传操作"
        fi
    fi
    
    show_temp_location
    echo ""
}

main "$@"
