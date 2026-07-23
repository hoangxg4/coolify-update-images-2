#!/bin/bash
set +x

STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"
TEMP_CONFIG="remote_registries.json"

echo "::add-mask::$COOLIFY_URL"
echo "::add-mask::$COOLIFY_TOKEN"

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
    build_pack=$(printf "%s" "$app" | jq -r '.build_pack')

    if [ "$build_pack" == "dockerimage" ] && [ "$image" != "null" ]; then
        remote_digest=$(regctl image digest "$image:$tag" 2>/dev/null)
        
        if [ -n "$remote_digest" ]; then
            old_digest=$(jq -r ".[\"$uuid\"] // empty" "$STATE_FILE")
            
            if [ "$remote_digest" != "$old_digest" ]; then
                echo "🚀 Deploying $name ($image:$tag)..."
                status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")
                
                if [ "$status" == "200" ]; then
                    tmp=$(mktemp); jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                    echo "   ✅ Deploy triggered successfully!"
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
