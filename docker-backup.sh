#!/bin/bash
# Docker 多平台镜像备份脚本（支持 tag 跳过、速率限制、拉取限额保护）
set -euo pipefail

# 加载环境变量
ENV_FILE="$(dirname "$0")/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

if [[ -z "${DOCKER_USER:-}" || -z "${DOCKER_PASS:-}" ]]; then
  echo "❌ 请在 .env 中设置 DOCKER_USER 和 DOCKER_PASS"; exit 1
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

# 通用 curl 重试函数
retry_curl() {
  local max=3 delay=2 i=1
  while (( i <= max )); do
    if curl "$@"; then return 0; fi
    echo "⚠️ curl 失败，重试第 $i 次..."; sleep $delay; ((i++))
  done
  echo "❌ 重试失败"; return 1
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

  # 获取源仓库 tags
  if [[ "$image_with_tag" == *:* ]]; then
    tags=( "$tag_literal" )
  else
    tags=()
    page=1
    while :; do
      resp=$(retry_curl -s "https://hub.docker.com/v2/repositories/$namespace/$image/tags?page=$page&page_size=100")
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
    resp=$(retry_curl -s -H "Authorization: JWT $TOKEN" \
      "https://hub.docker.com/v2/repositories/$DOCKER_USER/$target_repo/tags?page=$page&page_size=100")
    [[ "$(echo "$resp" | jq -r .detail 2>/dev/null)" == "Not found." ]] && break
    count=$(echo "$resp" | jq '.results | length')
    (( count == 0 )) && break
    for t in $(echo "$resp" | jq -r '.results[].name'); do exist_tags+=( "$t" ); done
    [[ "$(echo "$resp" | jq -r '.next')" == "null" ]] && break
    ((page++))
  done

  for tag in "${tags[@]}"; do
    if [[ " ${exist_tags[*]} " =~ " $tag " ]]; then
      echo "✅ 跳过已存在标签: $tag"
      continue
    fi

    echo "🔄 处理标签: $tag"

    # 尝试获取平台信息
    if pf=$(docker buildx imagetools inspect "docker.io/$source_repo:$tag" 2>/tmp/pf_err); then
      platforms=$(echo "$pf" | awk '/Platform:/ {print $NF}' | sort | uniq | paste -sd, -)
    else
      platforms="未知"
      echo "⚠ 平台信息无法获取"
    fi
    echo "   ➤ 平台: $platforms"

    # 推送镜像（检测 429）
    err_msg=$(docker buildx imagetools create --tag "$target_full:$tag" \
              "docker.io/$source_repo:$tag" 2>&1 >/dev/null) || {
      echo "❌ 推送失败：$target_full:$tag"
      if [[ "$err_msg" == *"429 Too Many Requests"* ]]; then
        echo "🚨 已达到 Docker Hub 拉取速率限制，终止脚本。"
        exit 1
      fi
      continue
    }
    echo "✅ 已推送到 $target_full:$tag"
    sleep 1
  done

  # 同步描述信息
  echo "📝 同步描述信息到目标仓库..."
  repo_info=$(retry_curl -s -H "Authorization: JWT $TOKEN" \
    "https://hub.docker.com/v2/repositories/$namespace/$image/")
  src_desc=$(echo "$repo_info" | jq -r .description)
  src_full_desc=$(echo "$repo_info" | jq -r .full_description)
  desc_json=$(jq -n --arg d "$src_desc" --arg f "$src_full_desc" \
    '{"description": $d, "full_description": $f, "is_private": false}')

  status_code=$(retry_curl -s -o /tmp/desc_sync.json -w "%{http_code}" \
    -X PATCH -H "Authorization: JWT $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$desc_json" \
    "https://hub.docker.com/v2/repositories/$DOCKER_USER/$target_repo/")

  if [[ "$status_code" == "200" ]]; then
    echo "✅ 描述同步成功"
  elif [[ "$status_code" == "403" ]]; then
    echo "⚠ 描述同步失败（403 Forbidden），尝试初始化仓库..."
    init_payload='{"description":"初始化","full_description":"初始化","is_private":false}'
    curl -s -X PATCH -H "Authorization: JWT $TOKEN" \
         -H "Content-Type: application/json" \
         -d "$init_payload" \
         "https://hub.docker.com/v2/repositories/$DOCKER_USER/$target_repo/" > /dev/null

    retry_status=$(retry_curl -s -o /tmp/desc_sync.json -w "%{http_code}" \
      -X PATCH -H "Authorization: JWT $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$desc_json" \
      "https://hub.docker.com/v2/repositories/$DOCKER_USER/$target_repo/")
    if [[ "$retry_status" == "200" ]]; then
      echo "✅ 描述初始化后同步成功"
    else
      echo "❌ 描述初始化后仍失败，状态码 $retry_status"
      cat /tmp/desc_sync.json
    fi
  else
    echo "❌ 描述同步失败，状态码 $status_code"
    cat /tmp/desc_sync.json
  fi

  sleep 2
done < "$CONFIG_FILE"

docker logout
echo -e "\n🎉 所有镜像已处理完成！"
