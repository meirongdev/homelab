#!/bin/bash

# 电子书同步脚本
# 功能: 从 ~/Downloads/books 同步电子书到 calibre-web
# 使用: ./sync-ebooks.sh [--dry-run] [--backup] [--cleanup]

set -euo pipefail

# 配置
LOCAL_BOOKS_DIR="${HOME}/Downloads/books"
BACKUP_DIR="${HOME}/.local/share/calibre-web-sync-backup"
INGEST_POD_NAMESPACE="personal-services"
INGEST_POD_SELECTOR="app=calibre-web"
INGEST_PATH="/cwa-book-ingest"
LOG_FILE="${HOME}/.local/share/calibre-web-sync.log"

# 支持的电子书格式
SUPPORTED_FORMATS=("pdf" "epub" "mobi" "azw" "azw3")

# 标志
DRY_RUN=false
BACKUP=true
CLEANUP=false
VERBOSE=false

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}ℹ${NC} $@" >&2
    log "INFO" "$@"
}

success() {
    echo -e "${GREEN}✓${NC} $@" >&2
    log "SUCCESS" "$@"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $@" >&2
    log "WARN" "$@"
}

error() {
    echo -e "${RED}✗${NC} $@" >&2
    log "ERROR" "$@"
}

# 帮助信息
usage() {
    cat << EOF
电子书同步脚本

用法: $(basename "$0") [选项]

选项:
  -n, --dry-run      显示会做什么，但不实际执行
  -b, --backup       备份已导入的电子书 (默认: 启用)
  --no-backup        禁用备份
  -c, --cleanup      导入后删除本地文件
  -v, --verbose      详细输出
  -h, --help         显示帮助信息

示例:
  # 查看会导入的文件
  $(basename "$0") --dry-run

  # 导入并备份
  $(basename "$0") --backup

  # 导入、备份并删除本地文件
  $(basename "$0") --backup --cleanup

  # 不备份直接导入
  $(basename "$0") --no-backup

EOF
    exit 0
}

# 解析参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -b|--backup)
                BACKUP=true
                shift
                ;;
            --no-backup)
                BACKUP=false
                shift
                ;;
            -c|--cleanup)
                CLEANUP=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                error "未知选项: $1"
                usage
                ;;
        esac
    done
}

# 初始化
init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$BACKUP_DIR"
    
    info "电子书同步脚本启动"
    info "本地目录: $LOCAL_BOOKS_DIR"
    info "备份目录: $BACKUP_DIR"
    [ "$DRY_RUN" = true ] && info "测试模式: 仅显示操作"
    [ "$CLEANUP" = true ] && info "清理模式: 导入后删除本地文件"
}

# 验证环境
check_env() {
    # 检查 kubectl
    if ! command -v kubectl &> /dev/null; then
        error "kubectl 未安装"
        return 1
    fi
    
    # 检查 kubernetes 连接
    if ! kubectl cluster-info &> /dev/null; then
        error "无法连接到 Kubernetes 集群"
        return 1
    fi
    
    # 检查本地目录
    if [ ! -d "$LOCAL_BOOKS_DIR" ]; then
        warn "本地目录不存在: $LOCAL_BOOKS_DIR"
        return 1
    fi
    
    success "环境检查完成"
    return 0
}

# 获取 calibre-web pod
get_calibre_pod() {
    local pod=$(kubectl get pods -n "$INGEST_POD_NAMESPACE" \
        -l "$INGEST_POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$pod" ]; then
        error "找不到 calibre-web pod"
        return 1
    fi
    
    echo "$pod"
}

# 检查书籍是否已存在于 calibre 数据库
check_book_exists() {
    local filename="$1"
    local pod=$(get_calibre_pod) || return 1
    
    # 提取文件名（不含路径）
    local basename=$(basename "$filename")
    
    # 移除文件扩展名
    local book_title="${basename%.*}"
    
    # 移除常见的元信息后缀（如 (Author Name), [Z-Library] 等）
    book_title=$(echo "$book_title" | sed -E 's/ \([^)]*\)$//; s/ \[[^]]*\]$//; s/ - [^-]*$//')
    
    # 在数据库中查询相同标题的书籍
    local count=$(kubectl exec -n "$INGEST_POD_NAMESPACE" "$pod" -- \
        sqlite3 /calibre-library/metadata.db \
        "SELECT COUNT(*) FROM books WHERE title = '$book_title' ESCAPE '\\\\';" 2>/dev/null || echo "0")
    
    # 如果找到相同标题的书籍，返回已存在
    if [ "$count" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# 批量查询已存在的书籍
get_existing_books() {
    local pod=$(get_calibre_pod) || return 1
    
    # 获取数据库中所有书籍的标题
    kubectl exec -n "$INGEST_POD_NAMESPACE" "$pod" -- \
        sqlite3 /calibre-library/metadata.db \
        "SELECT DISTINCT title FROM books;" 2>/dev/null || true
}

# 扫描电子书
scan_ebooks() {
    local format_pattern=""
    for fmt in "${SUPPORTED_FORMATS[@]}"; do
        if [ -z "$format_pattern" ]; then
            format_pattern="-name '*.$fmt'"
        else
            format_pattern="$format_pattern -o -name '*.$fmt'"
        fi
    done
    
    # 使用 find 查找所有支持的格式
    find "$LOCAL_BOOKS_DIR" -maxdepth 1 -type f \( $format_pattern \) 2>/dev/null | sort
}

# 同步电子书
sync_ebooks() {
    local pod=$(get_calibre_pod) || return 1
    
    local files=($(scan_ebooks))
    local total=${#files[@]}
    
    if [ $total -eq 0 ]; then
        info "未找到电子书文件"
        return 0
    fi
    
    info "找到 $total 本电子书"
    
    # 加载已存在的书籍列表以加快查询
    info "加载已存在的书籍列表..."
    local existing_books=$(get_existing_books)
    
    echo ""
    
    # 统计
    local success_count=0
    local failed_count=0
    local skipped_count=0
    local duplicate_count=0
    
    # 处理每个文件
    for file in "${files[@]}"; do
        local filename=$(basename "$file")
        local filesize=$(du -h "$file" | awk '{print $1}')
        
        # 移除文件扩展名获取标题
        local book_title="${filename%.*}"
        # 移除常见的元信息后缀（如 (Author Name), [Z-Library] 等）
        book_title=$(echo "$book_title" | sed -E 's/ \([^)]*\)$//; s/ \[[^]]*\]$//; s/ - [^-]*$//')
        
        # 检查是否已存在于 ingest 目录
        if kubectl exec -n "$INGEST_POD_NAMESPACE" "$pod" -- \
            test -f "${INGEST_PATH}/${filename}" 2>/dev/null; then
            warn "  ⊘ $filename (已在 ingest 目录中)"
            ((skipped_count++))
            continue
        fi
        
        # 检查是否在数据库中已存在
        if echo "$existing_books" | grep -F -q "$book_title"; then
            warn "  ⊘ $filename (已存在于 calibre 数据库)"
            ((duplicate_count++))
            continue
        fi
        
        if [ "$DRY_RUN" = true ]; then
            info "  ▶ $filename ($filesize)"
        else
            # 复制文件到 pod
            if kubectl cp "$file" "$INGEST_POD_NAMESPACE/$pod:${INGEST_PATH}/${filename}" 2>/dev/null; then
                # 备份文件
                if [ "$BACKUP" = true ]; then
                    cp "$file" "$BACKUP_DIR/" 2>/dev/null
                fi
                
                success "  ✓ $filename ($filesize)"
                ((success_count++))
                
                # 清理本地文件
                if [ "$CLEANUP" = true ]; then
                    rm -f "$file"
                fi
            else
                error "  ✗ $filename (导入失败)"
                ((failed_count++))
            fi
        fi
    done
    
    echo ""
    info "同步统计:"
    info "  成功: $success_count"
    info "  失败: $failed_count"
    info "  跳过 (ingest): $skipped_count"
    info "  重复 (数据库): $duplicate_count"
    
    return 0
}

# 验证导入
verify_import() {
    local pod=$(get_calibre_pod) || return 1
    
    info "验证导入..."
    
    # 获取 ingest 目录中的文件数
    local ingest_count=$(kubectl exec -n "$INGEST_POD_NAMESPACE" "$pod" -- \
        find "${INGEST_PATH}" -maxdepth 1 -type f 2>/dev/null | wc -l)
    
    info "Ingest 目录中的文件: $ingest_count"
}

# 主函数
main() {
    parse_args "$@"
    
    init
    check_env || exit 1
    
    sync_ebooks || exit 1
    
    if [ "$DRY_RUN" = false ]; then
        verify_import
    fi
    
    success "完成"
}

# 运行
main "$@"
