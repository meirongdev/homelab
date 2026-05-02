#!/bin/bash
set -euo pipefail

CONTEXT="${1:-k3s-homelab}"
DRY_RUN="${2:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}ℹ${NC} 扫描重复书籍..."

POD=$(kubectl --context $CONTEXT get pod -n personal-services -l app=calibre-web -o jsonpath='{.items[0].metadata.name}')

# 获取重复的标题列表和对应的IDs
# 使用临时文件避免管道问题
TEMP_FILE="/tmp/dup-titles-$$.txt"
kubectl --context $CONTEXT exec -n personal-services $POD -- bash -c '
sqlite3 /calibre-library/metadata.db << SQL
SELECT title, GROUP_CONCAT(id, ",") as ids
FROM books
WHERE title IN (
  SELECT title FROM books 
  GROUP BY title 
  HAVING COUNT(*) > 1
)
GROUP BY title;
SQL
' > "$TEMP_FILE" 2>/dev/null || true

if [ ! -s "$TEMP_FILE" ]; then
  echo -e "${GREEN}✓${NC} 没有重复书籍"
  rm -f "$TEMP_FILE"
  exit 0
fi

# 统计重复
DELETE_IDS=()
while IFS='|' read -r title ids; do
  if [ -z "$ids" ]; then
    continue
  fi
  # 跳过第一个ID，收集其余的
  first=1
  for id in $(echo "$ids" | tr ',' ' '); do
    if [ $first -eq 1 ]; then
      first=0
    else
      DELETE_IDS+=("$id")
    fi
  done
done < "$TEMP_FILE"

rm -f "$TEMP_FILE"

if [ ${#DELETE_IDS[@]} -eq 0 ]; then
  echo -e "${GREEN}✓${NC} 没有需要删除的重复书籍"
  exit 0
fi

DELETE_COUNT=${#DELETE_IDS[@]}
echo -e "${BLUE}ℹ${NC} 发现 $DELETE_COUNT 本重复书籍"
echo -e "${BLUE}ℹ${NC} 待删除 IDs: ${DELETE_IDS[@]}"

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo -e "${GREEN}✓${NC} 测试模式完成"
  exit 0
fi

echo -e "${YELLOW}⚠${NC} 即将删除 $DELETE_COUNT 本重复书籍"
read -p "继续? (y/N): " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${BLUE}ℹ${NC} 已取消"
  exit 0
fi

# 备份
echo -e "${BLUE}ℹ${NC} 备份数据库..."
mkdir -p ~/.local/share/calibre-cleanup
kubectl --context $CONTEXT cp personal-services/$POD:/calibre-library/metadata.db \
  ~/.local/share/calibre-cleanup/metadata-$(date +%Y%m%d-%H%M%S).db 2>/dev/null || true

# 删除
echo -e "${BLUE}ℹ${NC} 删除重复书籍..."
for id in "${DELETE_IDS[@]}"; do
  kubectl --context $CONTEXT exec -n personal-services $POD -- \
    sqlite3 /calibre-library/metadata.db "DELETE FROM books WHERE id = $id;" 2>/dev/null || true
done

# 重启
echo -e "${BLUE}ℹ${NC} 重启 pod..."
kubectl --context $CONTEXT rollout restart deployment/calibre-web -n personal-services 2>/dev/null || true
kubectl --context $CONTEXT rollout status deployment/calibre-web -n personal-services --timeout=120s 2>/dev/null || true

echo -e "${GREEN}✓${NC} 完成！已删除 $DELETE_COUNT 本重复书籍"
