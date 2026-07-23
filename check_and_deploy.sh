#!/bin/bash
set +x

STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"
TEMP_CONFIG="remote_registries.json"

echo "::add-mask::$COOLIFY_URL"
echo "::add-mask::$COOLIFY_TOKEN"
[ -n "$NTFY_URL" ] && echo "::add-mask::$NTFY_URL"
[ -n "$NTFY_TOKEN" ] && echo "::add-mask::$NTFY_TOKEN"

# --- Hàm gửi thông báo ntfy (Đã thêm cờ -L xử lý Redirect 301) ---
send_ntfy_notification() {
  local uuid=$1; local name=$2; local image=$3; local tag=$4; local fqdn=$5
  local p_uuid=$6; local e_uuid=$7
  local time=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

  local dashboard_link="${COOLIFY_URL}/project/${p_uuid}/environment/${e_uuid}/application/${uuid}"

  # 1. Kiểm tra xem NTFY_URL có tồn tại không
  if [ -z "$NTFY_URL" ]; then
    echo "   ❌ [NTFY DEBUG] Lỗi: Biến môi trường NTFY_URL bị RỖNG! Hãy kiểm tra GitHub Secrets."
    return
  fi

  echo "   🔍 [NTFY DEBUG] Đang kết nối tới: $NTFY_URL"

  # Chuẩn bị nội dung tin nhắn
  local body="Image: $image:$tag\nTime: $time"
  if [[ -n "$fqdn" && "$fqdn" != "null" ]]; then
    body="$body\nLive URL: $fqdn"
  fi

  # Chuẩn bị danh sách Headers
  local headers=(
    -H "Title: 🚀 New Update Deployed: $name"
    -H "Tags: rocket,coolify,package"
    -H "Click: $dashboard_link"
    -H "Markdown: yes"
  )

  # Thêm các nút bấm hành động (Actions)
  if [[ -n "$fqdn" && "$fqdn" != "null" ]]; then
    headers+=(-H "Actions: view, Visit Site, $fqdn; view, Open Dashboard, $dashboard_link")
  else
    headers+=(-H "Actions: view, Open Dashboard, $dashboard_link")
  fi

  # Thêm Auth Token nếu server yêu cầu đăng nhập
  if [ -n "$NTFY_TOKEN" ]; then
    headers+=(-H "Authorization: Bearer $NTFY_TOKEN")
  fi

  # 2. Thực thi lệnh curl (Đã thêm cờ -L để tự động follow đường dẫn 301/HTTPS)
  local response
  response=$(curl -s -L -w "\n%{http_code}" "${headers[@]}" -d "$body" "$NTFY_URL" 2>&1)

  local http_code
  http_code=$(echo "$response" | tail -n1)
  local res_body
  res_body=$(echo "$response" | sed '$d')

  # 3. Phân tích kết quả trả về
  if [ "$http_code" -eq 200 ]; then
    echo "   ✅ [NTFY DEBUG] Gửi thông báo ntfy thành công (HTTP status 200)!"
  else
    echo "   ❌ [NTFY DEBUG] Gửi ntfy thất bại! Mã HTTP: $http_code"
    echo "   📄 [NTFY DEBUG] Phản hồi từ Ntfy Server: $res_body"
  fi
}

# 1. Tải config và giải mã state
if [ -n "$CONFIG_URL" ] && [ -n "$MY_CONFIG_PAT" ]; then
    curl -s -L -o "$TEMP_CONFIG" -H "Authorization: token $MY_CONFIG_PAT" "$CONFIG_URL"
    [ -f "$TEMP_CONFIG" ] && CONFIG_FILE="$TEMP_CONFIG"
fi
if [ -f "$CONFIG_FILE" ]; then
    STATE_PWD=$(jq -r '.state_pass // empty' "$CONFIG_FILE")
    if [ -f "$STATE_FILE_ENC" ] && [ -n "$STATE_PWD" ]; then
        openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$STATE_FILE_ENC" -out "$STATE_FILE" -k "$STATE_PWD" 2>/dev/null
    fi
fi
[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# 2. Login Registries
if [ -f "$CONFIG_FILE" ]; then
    jq -c '.registries[]' "$CONFIG_FILE" 2>/dev/null | while read -r reg; do
        server=$(jq -r '.server' <<< "$reg"); user=$(jq -r '.user' <<< "$reg"); pass=$(jq -r '.pass' <<< "$reg")
        printf "%s" "$pass" | regctl registry login "$server" -u "$user" --pass-stdin > /dev/null 2>&1
    done
fi

# 3. Xây dựng Map Project/Environment
echo "📡 Mapping Project structure..."
MAP_FILE=$(mktemp)
echo "[]" > "$MAP_FILE"

PROJECTS_RES=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/projects")

# Kiểm tra xem API có lỗi không
if ! printf "%s" "$PROJECTS_RES" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "❌ Lỗi: Không thể lấy danh sách Projects. Phản hồi từ Server:"
    printf "%s\n" "$PROJECTS_RES"
    exit 1
fi

printf "%s" "$PROJECTS_RES" | jq -c '.[]' | while read -r project; do
    p_uuid=$(printf "%s" "$project" | jq -r '.uuid')
    
    envs_raw=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/projects/$p_uuid/environments")
    new_map=$(printf "%s" "$envs_raw" | jq -c --arg puuid "$p_uuid" '.[] | {id: .id, p_uuid: $puuid, e_uuid: .uuid}')
    combined=$(jq -s '.[0] + .[1]' "$MAP_FILE" <(printf "%s" "$new_map" | jq -s '.'))
    printf "%s\n" "$combined" > "$MAP_FILE"
done

# 4. Kiểm tra Updates và Trigger Deploy
echo "🔍 Scanning for applications updates..."
APPS_RES=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")

if ! printf "%s" "$APPS_RES" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "❌ Lỗi: Không thể lấy danh sách Applications. Phản hồi từ Server:"
    printf "%s\n" "$APPS_RES"
    exit 1
fi

printf "%s" "$APPS_RES" | jq -c '.[]' | while read -r app; do
    uuid=$(printf "%s" "$app" | jq -r '.uuid')
    name=$(printf "%s" "$app" | jq -r '.name')
    image=$(printf "%s" "$app" | jq -r '.docker_registry_image_name')
    tag=$(printf "%s" "$app" | jq -r '.docker_registry_image_tag')
    fqdn=$(printf "%s" "$app" | jq -r '.fqdn')
    env_id=$(printf "%s" "$app" | jq -r '.environment_id')
    build_pack=$(printf "%s" "$app" | jq -r '.build_pack')

    if [ "$build_pack" == "dockerimage" ] && [ "$image" != "null" ]; then
        remote_digest=$(regctl image digest "$image:$tag" 2>/dev/null)
        
        if [ -n "$remote_digest" ]; then
            old_digest=$(jq -r ".[\"$uuid\"] // empty" "$STATE_FILE")
            
            if [ "$remote_digest" != "$old_digest" ]; then
                p_uuid=$(jq -r --arg eid "$env_id" '.[] | select(.id == ($eid|tonumber)) | .p_uuid' "$MAP_FILE" | head -n 1)
                e_uuid=$(jq -r --arg eid "$env_id" '.[] | select(.id == ($eid|tonumber)) | .e_uuid' "$MAP_FILE" | head -n 1)

                echo "🚀 Deploying $name ($image:$tag)..."
                status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")
                
                if [ "$status" == "200" ]; then
                    tmp=$(mktemp); jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                    send_ntfy_notification "$uuid" "$name" "$image" "$tag" "$fqdn" "$p_uuid" "$e_uuid"
                    echo "   ✅ Deploy trigger successfully!"
                else
                    echo "   ❌ Deploy failed with HTTP status: $status"
                fi
            fi
        fi
    fi
done

# 5. Mã hóa lại & Dọn dẹp
if [ -n "$STATE_PWD" ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$STATE_FILE" -out "$STATE_FILE_ENC" -k "$STATE_PWD"
    rm -f "$STATE_FILE"
fi
rm -f "$TEMP_CONFIG" "$MAP_FILE"
echo "✅ CI/CD Scan Finished."
