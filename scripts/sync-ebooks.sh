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
KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-homelab}"

# 支持的电子书格式
SUPPORTED_FORMATS=("pdf" "epub" "mobi" "azw" "azw3")

# 标志
DRY_RUN=false
BACKUP=true
CLEANUP=false
VERBOSE=false
SKIP_VALIDATION=false

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
  -n, --dry-run       显示会做什么，但不实际执行
  -b, --backup        备份已导入的电子书 (默认: 启用)
  --no-backup         禁用备份
  -c, --cleanup       导入后删除本地文件
  --skip-validation   跳过文件完整性验证（不推荐）
  -v, --verbose       详细输出
  -h, --help          显示帮助信息

示例:
  # 查看会导入的文件
  $(basename "$0") --dry-run

  # 导入并备份（包含验证）
  $(basename "$0") --backup

  # 导入、备份并删除本地文件（包含验证）
  $(basename "$0") --backup --cleanup

  # 不备份直接导入
  $(basename "$0") --no-backup

  # 跳过文件验证（快速模式）
  $(basename "$0") --skip-validation

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
            --skip-validation)
                SKIP_VALIDATION=true
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
    [ "$SKIP_VALIDATION" = true ] && warn "跳过验证模式: 不检查文件完整性"
    return 0
}

# 验证环境
check_env() {
    # 检查 kubectl
    if ! command -v kubectl &> /dev/null; then
        error "kubectl 未安装"
        return 1
    fi
    
    # 检查 kubernetes 连接
    if ! kubectl --context "$KUBE_CONTEXT" cluster-info &> /dev/null; then
        error "无法连接到 Kubernetes 集群 ($KUBE_CONTEXT)"
        return 1
    fi
    
    # 检查本地目录
    if [ ! -d "$LOCAL_BOOKS_DIR" ]; then
        warn "本地目录不存在: $LOCAL_BOOKS_DIR"
        return 1
    fi
    
    # 检查 Python（用于验证）
    if [ "$SKIP_VALIDATION" = false ]; then
        if ! command -v python3 &> /dev/null; then
            warn "Python3 未安装，将跳过文件验证"
            SKIP_VALIDATION=true
        fi
    fi
    
    success "环境检查完成"
    return 0
}

# 获取 calibre-web pod
get_calibre_pod() {
    local pod=$(kubectl --context "$KUBE_CONTEXT" get pods -n "$INGEST_POD_NAMESPACE" \
        -l "$INGEST_POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$pod" ]; then
        error "找不到 calibre-web pod (context: $KUBE_CONTEXT)"
        return 1
    fi
    
    echo "$pod"
}

# 检测 EPUB 文件中的 DRM 保护
detect_epub_drm() {
    local filepath="$1"

    python3 - "$filepath" << 'PYTHON_EOF'
import zipfile
import sys

filepath = sys.argv[1]

try:
    with zipfile.ZipFile(filepath, 'r') as zf:
        files = zf.namelist()

        # Adobe DRM 标记
        if 'META-INF/encryption.xml' in files:
            print("ADOBE_DRM")
            sys.exit(2)

        # Apple DRM 标记
        if 'META-INF/rights.xml' in files:
            print("APPLE_DRM")
            sys.exit(2)

        # 数字签名
        if 'META-INF/signatures.xml' in files:
            print("SIGNED")
            sys.exit(2)

        # 检查 OPF 中的加密声明
        opf_files = [f for f in files if f.endswith('.opf')]
        if opf_files:
            try:
                with zf.open(opf_files[0]) as f:
                    content = f.read().decode('utf-8', errors='ignore')
                    if 'encryption' in content.lower():
                        print("DRM_MARKED")
                        sys.exit(2)
            except:
                pass

        print("NO_DRM")
        sys.exit(0)

except zipfile.BadZipFile:
    print("NOT_ZIP")
    sys.exit(1)
except Exception:
    print("ERROR")
    sys.exit(1)
PYTHON_EOF

    return $?
}
validate_epub() {
    local filepath="$1"

    # 使用 Python 验证 EPUB 是否为有效的 ZIP 文件并包含必要的 EPUB 结构
    python3 - "$filepath" << 'PYTHON_EOF'
import sys
import zipfile
import os

filepath = sys.argv[1]

try:
    # 检查文件是否存在
    if not os.path.exists(filepath):
        sys.exit(1)

    # 检查文件大小
    file_size = os.path.getsize(filepath)
    if file_size == 0:
        sys.exit(1)

    # 尝试打开为 ZIP
    with zipfile.ZipFile(filepath, 'r') as zf:
        # 测试 ZIP 完整性
        result = zf.testzip()
        if result is not None:
            sys.exit(1)

        # 检查 EPUB 必要文件
        file_list = zf.namelist()

        # EPUB 必须至少有 mimetype 文件
        if 'mimetype' not in file_list:
            sys.exit(1)

        # 检查 META-INF/container.xml（EPUB2/3 标准要求）
        has_container = any('META-INF/container.xml' in f or 'container.xml' in f for f in file_list)
        if not has_container:
            sys.exit(1)

        sys.exit(0)

except zipfile.BadZipFile:
    sys.exit(1)
except Exception as e:
    sys.exit(1)
PYTHON_EOF

    # 检查 Python 脚本的返回值
    local result=$?
    return $result
}

# 验证 PDF 文件完整性
validate_pdf() {
    local filepath="$1"
    
    # 检查 PDF 魔数（PDF 文件应该以 %PDF 开头）
    local magic=$(head -c 4 "$filepath" 2>/dev/null)
    if [ "$magic" != "%PDF" ]; then
        return 1
    fi
    
    # 基本验证：检查 %%EOF 标记
    if ! tail -c 100 "$filepath" 2>/dev/null | grep -q "%%EOF"; then
        # 有些 PDF 没有完整的 EOF 标记，但仍然有效，所以不是硬错误
        return 0
    fi
    
    return 0
}

# 验证电子书文件
validate_ebook() {
    local filepath="$1"
    local filename=$(basename "$filepath")
    local extension="${filename##*.}"
    extension="${extension,,}"  # 转换为小写
    
    # 如果跳过验证，直接返回成功
    if [ "$SKIP_VALIDATION" = true ]; then
        return 0
    fi
    
    case "$extension" in
        epub)
            validate_epub "$filepath"
            return $?
            ;;
        pdf)
            validate_pdf "$filepath"
            return $?
            ;;
        *)
            # 其他格式暂不进行验证
            return 0
            ;;
    esac
}

# 获取验证错误描述
get_validation_error() {
    local filepath="$1"

    python3 - "$filepath" 2>/dev/null << 'PYTHON_EOF' || echo "验证过程出错"
import sys
import zipfile
import os

filepath = sys.argv[1]

try:
    if not os.path.exists(filepath):
        print("文件不存在")
    elif os.path.getsize(filepath) == 0:
        print("文件为空")
    else:
        try:
            with zipfile.ZipFile(filepath, 'r') as zf:
                result = zf.testzip()
                if result is not None:
                    print(f"ZIP损坏")
                else:
                    file_list = zf.namelist()
                    if 'mimetype' not in file_list:
                        print("缺少mimetype文件")
                    else:
                        print("文件结构不完整")
        except zipfile.BadZipFile:
            print("不是有效的ZIP文件")
        except Exception as e:
            print(f"验证失败: {str(e)}")
except:
    print("验证过程出错")
PYTHON_EOF
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
    local count=$(kubectl --context "$KUBE_CONTEXT" exec -n "$INGEST_POD_NAMESPACE" "$pod" -- \
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
    kubectl --context "$KUBE_CONTEXT" exec -n "$INGEST_POD_NAMESPACE" "$pod" -- \
        sqlite3 /calibre-library/metadata.db \
        "SELECT DISTINCT title FROM books;" 2>/dev/null || true
}

# 扫描电子书
scan_ebooks() {
    # 构建查找条件
    local find_expr=()
    for fmt in "${SUPPORTED_FORMATS[@]}"; do
        find_expr+=(-o -name "*.$fmt")
    done
    
    # 删除第一个 -o
    if [ ${#find_expr[@]} -gt 0 ]; then
        find_expr=("${find_expr[@]:1}")
    fi
    
    # 使用 find 查找所有支持的格式
    find "$LOCAL_BOOKS_DIR" -maxdepth 1 -type f \( "${find_expr[@]}" \) 2>/dev/null | sort
}

# 同步电子书
sync_ebooks() {
    local pod=$(get_calibre_pod) || return 1
    
    # 保存当前 IFS 并在完成后恢复
    local OLDIFS="$IFS"
    IFS=$'\n'
    local files=($(scan_ebooks))
    IFS="$OLDIFS"
    
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
    local corrupted_count=0
    
    # 处理每个文件
    for file in "${files[@]}"; do
        local filename=$(basename "$file")
        local filesize=$(du -h "$file" | awk '{print $1}')
        
        # 移除文件扩展名获取标题
        local book_title="${filename%.*}"
        # 移除常见的元信息后缀（如 (Author Name), [Z-Library] 等）
        book_title=$(echo "$book_title" | sed -E 's/ \([^)]*\)$//; s/ \[[^]]*\]$//; s/ - [^-]*$//')
        
        # 检查是否已存在于 ingest 目录
        if kubectl --context "$KUBE_CONTEXT" exec -n "$INGEST_POD_NAMESPACE" "$pod" -- \
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
        
        # 验证文件完整性
        local extension="${filename##*.}"
        extension="${extension,,}"
        if [[ "$extension" == "epub" || "$extension" == "pdf" ]]; then
            if ! validate_ebook "$file" &>/dev/null; then
                local error_msg=$(get_validation_error "$file")
                error "  ✗ $filename (文件损坏或无效: $error_msg)"
                log "ERROR" "CORRUPTED_FILE: $filename ($error_msg)"
                ((corrupted_count++))
                continue
            fi
            
            # 如果是EPUB，检查DRM保护
            if [[ "$extension" == "epub" ]]; then
                local drm_result=$(detect_epub_drm "$file" 2>&1)
                if [ $? -eq 2 ]; then
                    warn "  ⚠ $filename (DRM保护: $drm_result - 可能无法打开)"
                    log "WARN" "DRM_PROTECTED: $filename ($drm_result)"
                fi
            fi
        fi
        
        if [ "$DRY_RUN" = true ]; then
            info "  ▶ $filename ($filesize)"
        else
            # 复制文件到 pod
            if kubectl --context "$KUBE_CONTEXT" cp "$file" "$INGEST_POD_NAMESPACE/$pod:${INGEST_PATH}/${filename}" 2>/dev/null; then
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
    [ $corrupted_count -gt 0 ] && warn "  损坏: $corrupted_count"
    info "  跳过 (ingest): $skipped_count"
    info "  重复 (数据库): $duplicate_count"
    
    return 0
}

# 验证导入
verify_import() {
    local pod=$(get_calibre_pod) || return 1
    
    info "验证导入..."
    
    # 获取 ingest 目录中的文件数
    local ingest_count=$(kubectl --context "$KUBE_CONTEXT" exec -n "$INGEST_POD_NAMESPACE" "$pod" -- \
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

# 仅当脚本被直接执行（而非源引入）时运行 main 函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
