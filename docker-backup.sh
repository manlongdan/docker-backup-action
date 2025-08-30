#!/bin/bash
# Docker 多平台镜像备份脚本 v4 (支持 Skopeo + Buildx，增强容错)
set -euo pipefail

MUTABLE_TAGS=("latest" "debian" "beta" "stable" "edge")
DIGEST_CACHE_FILE="digest_cache.json"
CACHE_UPDATED=false

ENV_FILE="$(dirname "$0")/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi
if [[ -z "${DOCKER_USER:-}" || -z "${DOCKER_PASS:-}" ]]; then
  echo "❌ 请在 .env 或 GitHub Secrets 中设置 DOCKER_USER 和 DOCKER_PASS"; exit 1
fi

# 安装依赖
command -v jq >/dev/null || { echo "🛠 安装 jq..."; sudo apt-get update && sudo apt-get install -y jq; }
command -v skopeo >/dev/null || { echo "🛠 安装 skopeo..."; sudo apt-get update && sudo apt-get install -y skopeo; }
docker buildx version >/dev/null 2>&1 || {
  echo "🛠 安装 docker buildx 插件..."
  sudo apt-get update && sudo apt-get install -y docker-buildx-plugin
  docker buildx install
}

# 登录
echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin

login_resp=$(curl -s -H "Content-Type: application/json" \
  -X POST -d "{\"username\":\"$DOCKER_USER\",\"password\":\"$DOCKER_PASS\"}" \
  https://hub.docker.com/v2/users/login/)
TOKEN=$(echo "$login_resp" | jq -r .token)
[[ -z "$TOKEN" || "$TOKEN" == "null" ]] && { echo "❌ 登录失败，无法获取 JWT token"; exit 1; }

# buildx builder
docker buildx inspect backup-builder >/dev/null 2>&1 || docker buildx create --name backup-builder --use
docker buildx use backup-builder

CONFIG_FILE="${1:-$HOME/backup_repos.conf}"
[[ ! -f "$CONFIG_FILE" ]] && { echo "❌ 配置文件不存在：$CONFIG_FILE"; exit 1; }

# 初始化缓存
if [[ ! -f "$DIGEST_CACHE_FILE" ]]; then
  echo "{}" > "$DIGEST_CACHE_FILE"
  echo "🛠 未找到摘要缓存文件，已创建空的 $DIGEST_CACHE_FILE"
fi

retry_curl() {
  local max=3 delay=2 i=1
  while (( i <= max )); do
    if curl --fail --silent "$@"; then return 0; fi
    echo "⚠️ curl 失败，重试第 $i 次..."; sleep $delay; ((i++))
  done
  echo "❌ 重试失败"; return 1
}

is_mutable_tag() {
  local tag="$1"
  for mutable in "${MUTABLE_TAGS[@]}"; do
    if [[ "$tag" == "$mutable" ]]; then return 0; fi
  done
  return 1
}

push_and_update_cache() {
    local source_ref="$1"
    local target_ref="$2"
    local cache_key="$3"

    echo "🔄 正在同步: $source_ref -> $target_ref"

    # 优先使用 skopeo
    if command -v skopeo >/dev/null; then
      if skopeo copy --all "docker://$source_ref" "docker://$target_ref"; then
        echo "✅ Skopeo 已同步 $target_ref"
      else
        echo "⚠️ Skopeo 失败，尝试使用 buildx..."
        if ! docker buildx imagetools create --tag "$target_ref" "$source_ref"; then
          echo "❌ Buildx 同步失败: $source_ref"
          return 1
        fi
      fi
    else
      if ! docker buildx imagetools create --tag "$target_ref" "$source_ref"; then
        echo "❌ Buildx 同步失败: $source_ref"
        return 1
      fi
    fi

    local current_digest
    current_digest=$(docker buildx imagetools inspect "$source_ref" --format '{{.Manifest.Digest}}' 2>/dev/null || echo "not-found")
    if [[ "$current_digest" != "not-found" ]]; then
      jq --arg key "$cache_key" --arg val "$current_digest" '. + {($key): $val}' "$DIGEST_CACHE_FILE" > "$DIGEST_CACHE_FILE.tmp" && mv "$DIGEST_CACHE_FILE.tmp" "$DIGEST_CACHE_FILE"
      CACHE_UPDATED=true
      echo "   ➤ 缓存已更新: $cache_key = $current_digest"
    fi
    sleep 1
    return 0
}

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^\s*# || -z "$line" ]] && continue
  line="${line%%#*}"
  line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue

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

  # 获取 tags
  if [[ "$image_with_tag" == *:* ]]; then
    tags=()
    IFS=',' read -ra ADDR <<< "$tag_literal"
    for t in "${ADDR[@]}"; do tags+=("$(echo "$t" | xargs)"); done
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

  # 获取目标仓库 tags
  exist_tags=()
  page=1
  while :; do
    resp=$(retry_curl -H "Authorization: JWT $TOKEN" \
      "https://hub.docker.com/v2/repositories/$DOCKER_USER/$target_repo/tags?page=$page&page_size=100") || break
    if ! echo "$resp" | jq -e . >/dev/null 2>&1; then break; fi
    [[ "$(echo "$resp" | jq -r .detail 2>/dev/null)" == "Not found." ]] && break
    count=$(echo "$resp" | jq '.results | length')
    (( count == 0 )) && break
    for t in $(echo "$resp" | jq -r '.results[].name'); do exist_tags+=( "$t" ); done
    [[ "$(echo "$resp" | jq -r '.next')" == "null" ]] && break
    ((page++))
  done

  echo "--- 阶段一：检查并同步新标签 ---"
  for tag in "${tags[@]}"; do
    if [[ " ${exist_tags[*]} " =~ " $tag " ]]; then continue; fi
    
    echo "✨ 发现新标签: $tag"
    source_image_ref="$source_repo:$tag"
    target_image_ref="$target_full:$tag"
    cache_key="$source_repo:$tag"
    
    if push_and_update_cache "$source_image_ref" "$target_image_ref" "$cache_key"; then
      new_tag_synced_this_repo=true
    else
      echo "⚠️ 标签 $tag 同步失败，跳过"
      continue
    fi
  done

  if [[ "$new_tag_synced_this_repo" == "true" ]]; then
    echo "--- 阶段二：检测到更新，检查可变标签 Digest ---"
    for tag in "${tags[@]}"; do
      if ! is_mutable_tag "$tag"; then continue; fi
      echo "🔍 检查可变标签: $tag"
      source_image_ref="$source_repo:$tag"
      cache_key="$source_repo:$tag"
      current_digest=$(docker buildx imagetools inspect "$source_image_ref" --format '{{.Manifest.Digest}}' 2>/dev/null || echo "not-found")
      [[ "$current_digest" == "not-found" ]] && { echo "⚠️ 无法获取摘要: $source_image_ref"; continue; }
      cached_digest=$(jq -r --arg key "$cache_key" '.[$key]' "$DIGEST_CACHE_FILE")
      if [[ "$current_digest" != "$cached_digest" ]]; then
        echo "🔄 Digest 已更新，准备同步: $tag"
        target_image_ref="$target_full:$tag"
        push_and_update_cache "$source_image_ref" "$target_image_ref" "$cache_key" || echo "⚠️ 更新失败，跳过 $tag"
      else
        echo "✅ Digest 未变化，无需更新: $tag"
      fi
    done
  else
    echo "✅ 无新标签发现，跳过对可变标签的 Digest 检查。"
  fi

  echo "📝 同步描述信息到目标仓库..."
  repo_info=$(retry_curl -H "Authorization: JWT $TOKEN" \
    "https://hub.docker.com/v2/repositories/$namespace/$image/") || { echo "⚠️ 获取描述失败，跳过"; continue; }
  src_desc=$(echo "$repo_info" | jq -r .description)
  src_full_desc=$(echo "$repo_info" | jq -r .full_description)
  desc_json=$(jq -n --arg d "$src_desc" --arg f "$src_full_desc" '{"description": $d, "full_description": $f, "is_private": false}')

  status_code=$(curl -s -o /tmp/desc_sync.json -w "%{http_code}" \
    -X PATCH -H "Authorization: JWT $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$desc_json" \
    "https://hub.docker.com/v2/repositories/$DOCKER_USER/$target_repo/")

  if [[ "$status_code" == "200" ]]; then
    echo "✅ 描述同步成功"
  else
    echo "⚠️ 描述同步失败，状态码 $status_code"
  fi

  sleep 2
done < "$CONFIG_FILE"

if [[ "$CACHE_UPDATED" = true ]]; then
  echo "📝 Digest 缓存已更新，创建标记文件用于提交。"
  touch "digest_cache_updated.flag"
fi

docker logout
echo -e "\n🎉 所有镜像已处理完成！"
