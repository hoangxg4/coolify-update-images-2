#!/bin/bash
set +x

STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"
TEMP_CONFIG="remote_registries.json"
CONFIG_FILE=""

echo "::add-mask::$COOLIFY_URL"
echo "::add-mask::$COOLIFY_TOKEN"

echo "=========================================="
echo "🚀 Bắt đầu tiến trình kiểm tra cập nhật..."
echo "=========================================="

# 1. Tải config và giải mã state
if [ -n "$CONFIG_URL" ] && [ -n "$MY_CONFIG_PAT" ]; then
    echo "📥 Đang tải cấu hình từ CONFIG_URL..."
    curl -s -L -o "$TEMP_CONFIG" -H "Authorization: token $MY_CONFIG_PAT" "$CONFIG_URL"
    
    # Kiểm tra xem file tải về có phải JSON hợp lệ không (tránh lỗi 404/Text làm jq văng lỗi)
    if [ -f "$TEMP_CONFIG" ] && jq empty "$TEMP_CONFIG" >/dev/null 2>&1; then
        CONFIG_FILE="$TEMP_CONFIG"
        echo "✅ Tải file cấu hình JSON thành công!"
    else
        echo "⚠️ Cảnh báo: Không thể tải hoặc nội dung CONFIG_URL không phải JSON hợp lệ."
    fi
fi

if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    STATE_PWD=$(jq -r '.state_pass // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -f "$STATE_FILE_ENC" ] && [ -n "$STATE_PWD" ]; then
        echo "🔓 Đang giải mã file trạng thái ($STATE_FILE_ENC)..."
        openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$STATE_FILE_ENC" -out "$STATE_FILE" -k "$STATE_PWD" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "✅ Giải mã file state thành công!"
        else
            echo "❌ Đăng nhập/Giải mã file state thất bại. Sẽ tạo state mới."
        fi
    fi
fi

if [ ! -f "$STATE_FILE" ]; then
    echo "ℹ️ Khởi tạo file state mới..."
    echo "{}" > "$STATE_FILE"
fi

# 2. Login Registries
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    echo "🔑 Đang kiểm tra danh sách Private Registry..."
    jq -c '.registries[]?' "$CONFIG_FILE" 2>/dev/null | while read -r reg; do
        [ -z "$reg" ] && continue
        server=$(jq -r '.server // empty' <<< "$reg")
        user=$(jq -r '.user // empty' <<< "$reg")
        pass=$(jq -r '.pass // empty' <<< "$reg")
        
        if [ -n "$server" ] && [ -n "$user" ] && [ -n "$pass" ]; then
            echo "  ➡️ Đang đăng nhập Registry: $server"
            printf "%s" "$pass" | regctl registry login "$server" -u "$user" --pass-stdin > /dev/null 2>&1
        fi
    done
fi

# 3. Kiểm tra Updates và Trigger Deploy
echo "🔍 Đang kết nối Coolify API để lấy danh sách ứng dụng..."
APPS_RES=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")

if ! printf "%s" "$APPS_RES" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "❌ Lỗi: Không thể lấy danh sách Applications. Phản hồi từ Server Coolify:"
    printf "%s\n" "$APPS_RES"
    exit 1
fi

echo "📦 Đã tìm thấy danh sách ứng dụng. Bắt đầu so sánh Image Digest..."

printf "%s" "$APPS_RES" | jq -c '.[]' | while read -r app; do
    uuid=$(printf "%s" "$app" | jq -r '.uuid')
    name=$(printf "%s" "$app" | jq -r '.name')
    image=$(printf "%s" "$app" | jq -r '.docker_registry_image_name')
    tag=$(printf "%s" "$app" | jq -r '.docker_registry_image_tag')
    build_pack=$(printf "%s" "$app" | jq -r '.build_pack')

    if [ "$build_pack" == "dockerimage" ] && [ "$image" != "null" ]; then
        echo "  👉 Checking [$name] ($image:$tag)..."
        remote_digest=$(regctl image digest "$image:$tag" 2>/dev/null)
        
        if [ -n "$remote_digest" ]; then
            old_digest=$(jq -r ".[\"$uuid\"] // empty" "$STATE_FILE")
            
            if [ "$remote_digest" != "$old_digest" ]; then
                echo "     🚀 Phát hiện thay đổi Digest! Đang gửi lệnh Deploy $name..."
                status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")
                
                if [ "$status" == "200" ]; then
                    tmp=$(mktemp); jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                    echo "     ✅ Trigger Deploy thành công! (HTTP Status 200)"
                else
                    echo "     ❌ Deploy thất bại với mã HTTP Status: $status"
                fi
            else
                echo "     ✨ Không có bản cập nhật mới (Digest giữ nguyên)."
            fi
        else
            echo "     ⚠️ Không thể lấy Remote Digest từ Registry cho $image:$tag"
        fi
    fi
done

# 4. Mã hóa lại & Dọn dẹp
if [ -n "$STATE_PWD" ]; then
    echo "🔒 Đang mã hóa lại file state để lưu vào Git Repo..."
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$STATE_FILE" -out "$STATE_FILE_ENC" -k "$STATE_PWD" 2>/dev/null
    rm -f "$STATE_FILE"
fi

rm -f "$TEMP_CONFIG"
echo "=========================================="
echo "✅ HOÀN THÀNH CI/CD SCAN & DEPLOY."
echo "=========================================="
