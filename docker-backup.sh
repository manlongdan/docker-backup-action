#!/bin/bash
# Docker 多平台镜像备份脚本 v3 (采用两阶段同步优化，支持 Digest 按需对比)
set -euo pipefail

# --- 新增：定义可变标签列表 ---
# 你可以在这里添加或修改你认为内容会变化的标签
MUTABLE_TAGS=("latest" "debian" "stable" "edge")

# --- 缓存文件定义 ---
DIGEST_CACHE_FILE="digest_cache.json"
CACHE_UPDATED=false

# 加载环境变量
ENV_FILE="$(dirname "$0")/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi
if [[ -z "${DOCKER_USER:-}" || -z "${DOCKER_PASS:-}" ]]; then
  echo "❌ 请在 .env 或 GitHub Secrets 中设置 DOCKER_USER 和 DOCKER_PASS"; exit 1
fi

# 安装依赖
command -v jq >/dev/null || { echo "🛠 安装 jq..."; sudo apt-get update && sudo apt-get install -y jq; }
docker buildx version >/dev/null 2>&1 || {
  echo "🛠 安装 docker buildx 插件..."
  sudo apt-get update && sudo apt-get install -y docker-buildx-plugin
  docker buildx install
}

# 登录并获取 token
echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
login_resp=$(curl -s -H "Content-Type: application/json" \
  -X POST -d "{\"username\":\"$DOCKER_USER\",\"password\":\"$DOCKER_PASS\"}" \
  https://hub.docker.com/v2/users/login/)
TOKEN=$(echo "$login_resp" | jq -r .token)
[[ -z "$TOKEN" || "$TOKEN" == "null" ]] && { echo "❌ 登录失败，无法获取 JWT token"; exit 1; }

# 切换或创建 buildx builder
docker buildx inspect backup-builder >/dev/null 2>&1 || docker buildx create --name backup-builder --use
docker buildx use backup-builder

# 配置文件
CONFIG_FILE="${1:-$HOME/backup_repos.conf}"
[[ ! -f "$CONFIG_FILE" ]] && { echo "❌ 配置文件不存在：$CONFIG_FILE"; exit 1; }

# 初始化缓存文件
if [[ ! -f "$DIGEST_CACHE_FILE" ]]; then
  echo "{}" > "$DIGEST_CACHE_FILE"
  echo "🛠 未找到摘要缓存文件，已创建空的 $DIGEST_CACHE_FILE"
fi

# 通用 curl 重试函数
retry_curl() {
  local max=3 delay=2 i=1
  while (( i <= max )); do
    # 使用 --fail 选项，当 HTTP 状态码为错误时，curl 会返回非零值
    if curl --fail --silent "$@"; then return 0; fi
    echo "⚠️ curl 失败，重试第 $i 次..."; sleep $delay; ((i++))
  done
  echo "❌ 重试失败"; return 1
}

# 辅助函数：检查一个标签是否为可变标签
is_mutable_tag() {
  local tag="$1"
  for mutable in "${MUTABLE_TAGS[@]}"; do
    if [[ "$tag" == "$mutable" ]]; then
      return 0
    fi
  done
  return 1
}

# 辅助函数：推送镜像并更新缓存
push_and_update_cache() {
    local source_ref="$1"
    local target_ref="$2"
    local cache_key="$3"

    echo "🔄 正在同步: $source_ref -> $target_ref"
    
    local err_msg
    err_msg=$(docker buildx imagetools create --tag "$target_ref" "$source_ref" 2>&1 >/dev/null) || {
      echo "❌ 推送失败：$target_ref"
      if [[ "$err_msg" == *"429 Too Many Requests"* ]]; then
        echo "🚨 已达到 Docker Hub 拉取速率限制，终止脚本。"
        exit 1
      fi
      return 1
    }

    local current_digest
    current_digest=$(docker buildx imagetools inspect "$source_ref" --format '{{.Manifest.Digest}}' 2>/dev/null)
    
    echo "✅ 已推送到 $target_ref"
    jq --arg key "$cache_key" --arg val "$current_digest" '. + {($key): $val}' "$DIGEST_CACHE_FILE" > "$DIGEST_CACHE_FILE.tmp" && mv "$DIGEST_CACHE_FILE.tmp" "$DIGEST_CACHE_FILE"
    CACHE_UPDATED=true
    echo "   ➤ 缓存已更新: $cache_key = $current_digest"
    sleep 1
    return 0
}


while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^\s*# || -z "$line" ]] && continue
  line="${line%%#*}"
  line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue

  # 解析镜像
  if [[ "$line" == */* ]]; then
    namespace="${line%%/*}"; image_with_tag="${line#*/}"
  else
    namespace="library"; image_with_tag="$line"
  fi
  image="${image_with_tag%%:*}"
  tag_literal="${image_with_tag##*:}"
  source_repo="$namespace/$image"
  target_repo="${namespace}_${image}"
  target_full="$DOCKER_USER/$target_repo"

  echo -e "\n🌀 备份镜像: $source_repo → $target_full"
  
  new_tag_synced_this_repo=false

  # 获取源仓库 tags
  if [[ "$image_with_tag" == *:* ]]; then
    tags=()
    IFS=',' read -ra ADDR <<< "$tag_literal"
    for t in "${ADDR[@]}"; do
      tags+=("$(echo "$t" | xargs)")
    done
  else
    tags=()
    page=1
    while :; do
      resp=$(retry_curl "https://hub.docker.com/v2/repositories/$namespace/$image/tags?page=$page&page_size=100") || { echo "❌ 获取源标签失败，跳过仓库 $source_repo"; continue 2; }
      count=$(echo "$resp" | jq '.results | length')
      (( count == 0 )) && break
      for t in $(echo "$resp" | jq -r '.results[].name'); do tags+=( "$t" ); done
      [[ "$(echo "$resp" | jq -r '.next')" == "null" ]] && break
      ((page++))
    done
  fi

  # 获取目标仓库已有 tags
  exist_tags=()
  page=1
  while :; do
    resp=$(retry_curl -H "Authorization: JWT $TOKEN" \
      "https://hub.docker.com/v2/repositories/$DOCKER_USER/$target_repo/tags?page=$page&page_size=100")
    if ! echo "$resp" | jq -e . > /dev/null 2>&1; then break; fi
    [[ "$(echo "$resp" | jq -r .detail 2>/dev/null)" == "Not found." ]] && break
    count=$(echo "$resp" | jq '.results | length')
    (( count == 0 )) && break
    for t in $(echo "$resp" | jq -r '.results[].name'); do exist_tags+=( "$t" ); done
    [[ "$(echo "$resp" | jq -r '.next')" == "null" ]] && break
    ((page++))
  done

  # --- 阶段一：仅同步全新的标签 ---
  echo "--- 阶段一：检查并同步新标签 ---"
  for tag in "${tags[@]}"; do
    if [[ " ${exist_tags[*]} " =~ " $tag " ]]; then
      continue
    fi
    
    # 发现新标签，执行同步
    echo "✨ 发现新标签: $tag"
    source_image_ref="docker.io/$source_repo:$tag"
    target_image_ref="$target_full:$tag"
    cache_key="$source_repo:$tag"
    
    if push_and_update_cache "$source_image_ref" "$target_image_ref" "$cache_key"; then
      new_tag_synced_this_repo=true
    fi
  done

  # --- 阶段二：如果阶段一有更新，则检查可变标签的 Digest ---
  if [[ "$new_tag_synced_this_repo" == "true" ]]; then
    echo "--- 阶段二：检测到更新，检查可变标签 Digest ---"
    for tag in "${tags[@]}"; do
      if ! is_mutable_tag "$tag"; then
        continue
      fi

      echo "🔍 检查可变标签: $tag"
      source_image_ref="docker.io/$source_repo:$tag"
      cache_key="$source_repo:$tag"

      current_digest=$(docker buildx imagetools inspect "$source_image_ref" --format '{{.Manifest.Digest}}' 2>/dev/null || echo "not-found")
      if [[ "$current_digest" == "not-found" ]]; then
        echo "⚠️ 无法获取源镜像摘要: $source_image_ref，跳过"
        continue
      fi

      cached_digest=$(jq -r --arg key "$cache_key" '.[$key]' "$DIGEST_CACHE_FILE")

      if [[ "$current_digest" != "$cached_digest" ]]; then
        echo "🔄 Digest 已更新，准备同步: $tag"
        echo "   旧 Digest: ${cached_digest:-未缓存}"
        echo "   新 Digest: $current_digest"
        target_image_ref="$target_full:$tag"
        push_and_update_cache "$source_image_ref" "$target_image_ref" "$cache_key"
      else
        echo "✅ Digest 未变化，无需更新: $tag"
      fi
    done
  else
    echo "✅ 无新标签发现，跳过对可变标签的 Digest 检查。"
  fi

  # ... (描述信息同步逻辑保持不变) ...

done < "$CONFIG_FILE"

# 如果缓存更新了，创建标记文件
if [[ "$CACHE_UPDATED" = true ]]; then
  echo "📝 Digest 缓存已更新，创建标记文件用于提交。"
  touch "digest_cache_updated.flag"
fi

docker logout
echo -e "\n🎉 所有镜像已处理完成！"
