#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"
TEMP_CONFIG="remote_registries.json"

echo "::add-mask::$COOLIFY_URL"
echo "::add-mask::$COOLIFY_TOKEN"

# Hàm deploy: POST /api/v1/deploy?uuid=...&force=true (Coolify v4), xử lý rate-limit 429
deploy_resource() {
    local uuid="$1"
    local display_name="$2"
    local tmpfile
    tmpfile=$(mktemp)
    local status

    status=$(curl -sS --max-time 120 -o "$tmpfile" -w "%{http_code}" -X POST \
        -H "Authorization: Bearer $COOLIFY_TOKEN" \
        "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true" || true)

    if [ "$status" == "200" ]; then
        rm -f "$tmpfile"
        return 0
    fi

    if [ "$status" == "429" ]; then
        echo "   ⏳ Rate limited (HTTP 429), waiting 60s and retrying once..."
        sleep 60
        status=$(curl -sS --max-time 120 -o "$tmpfile" -w "%{http_code}" -X POST \
            -H "Authorization: Bearer $COOLIFY_TOKEN" \
            "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true" || true)
        if [ "$status" == "200" ]; then
            rm -f "$tmpfile"
            return 0
        fi
    fi

    echo "   ❌ Deploy failed for $display_name with HTTP status: $status"
    echo "   Response body:"
    cat "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
    return 1
}

# Hàm deploy riêng cho Compose Service: dùng endpoint /services/{uuid}/restart?latest=true
# (tương đương nút "Pull Latest Images & Restart" trên UI).
# Lý do: POST /api/v1/deploy với Service KHÔNG pull image mới (StartService::run thiếu
# pullLatestImages=true) -> service chỉ bị restart với image cache cũ.
# Fallback về /deploy nếu server Coolify cũ chưa có endpoint này (404/405).
deploy_service() {
    local uuid="$1"
    local display_name="$2"
    local tmpfile
    tmpfile=$(mktemp)
    local status

    status=$(curl -sS --max-time 120 -o "$tmpfile" -w "%{http_code}" -X POST \
        -H "Authorization: Bearer $COOLIFY_TOKEN" \
        "$COOLIFY_URL/api/v1/services/$uuid/restart?latest=true" || true)

    if [ "$status" == "404" ] || [ "$status" == "405" ]; then
        echo "   ⚠️ Endpoint /services/$uuid/restart not available (HTTP $status), falling back to /deploy..."
        rm -f "$tmpfile"
        deploy_resource "$uuid" "$display_name"
        return $?
    fi

    if [ "$status" == "200" ]; then
        rm -f "$tmpfile"
        return 0
    fi

    if [ "$status" == "429" ]; then
        echo "   ⏳ Rate limited (HTTP 429), waiting 60s and retrying once..."
        sleep 60
        status=$(curl -sS --max-time 120 -o "$tmpfile" -w "%{http_code}" -X POST \
            -H "Authorization: Bearer $COOLIFY_TOKEN" \
            "$COOLIFY_URL/api/v1/services/$uuid/restart?latest=true" || true)
        if [ "$status" == "200" ]; then
            rm -f "$tmpfile"
            return 0
        fi
    fi

    echo "   ❌ Deploy failed for $display_name with HTTP status: $status"
    echo "   Response body:"
    cat "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
    return 1
}

# 1. Tải config và giải mã state
if [ -n "${CONFIG_URL:-}" ] && [ -n "${MY_CONFIG_PAT:-}" ]; then
    curl -sS -L --max-time 120 -o "$TEMP_CONFIG" -H "Authorization: token $MY_CONFIG_PAT" "$CONFIG_URL" || true
    [ -s "$TEMP_CONFIG" ] && CONFIG_FILE="$TEMP_CONFIG"
fi
if [ -f "${CONFIG_FILE:-}" ]; then
    STATE_PWD=$(jq -r '.state_pass // empty' "$CONFIG_FILE" 2>/dev/null || true)
    export STATE_PWD # dùng -pass env: thay vì -k để mật khẩu không xuất hiện trong process list
    if [ -f "$STATE_FILE_ENC" ] && [ -n "$STATE_PWD" ]; then
        openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$STATE_FILE_ENC" -out "$STATE_FILE" -pass env:STATE_PWD 2>/dev/null || true
    fi
fi
[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# Đọc cấu hình Git / Compose (mặc định BẬT tracking nếu config không khai báo)
GIT_ENABLED="true"
GIT_MODE="commit"
GIT_APPS_RAW="[]"
GIT_TOKENS_JSON="{}"
COMPOSE_ENABLED="true"
COMPOSE_SERVICES_RAW="[]"
COMPOSE_FILTER_TEMPLATES="true"
if [ -f "${CONFIG_FILE:-}" ]; then
    GIT_ENABLED=$(jq -r 'if .git.enabled? == false then "false" else "true" end' "$CONFIG_FILE" 2>/dev/null || true)
    GIT_MODE=$(jq -r '.git.mode? // "commit"' "$CONFIG_FILE" 2>/dev/null || true)
    GIT_APPS_RAW=$(jq -c '.git.apps? // []' "$CONFIG_FILE" 2>/dev/null || true)
    GIT_TOKENS_JSON=$(jq -c '.git.tokens? // {}' "$CONFIG_FILE" 2>/dev/null || true)
    COMPOSE_ENABLED=$(jq -r 'if .compose.enabled? == false then "false" else "true" end' "$CONFIG_FILE" 2>/dev/null || true)
    COMPOSE_SERVICES_RAW=$(jq -c '.compose.services? // []' "$CONFIG_FILE" 2>/dev/null || true)
    COMPOSE_FILTER_TEMPLATES=$(jq -r 'if .compose.filter_templates? == false then "false" else "true" end' "$CONFIG_FILE" 2>/dev/null || true)
    [ -z "$GIT_APPS_RAW" ] && GIT_APPS_RAW="[]"
    [ -z "$GIT_TOKENS_JSON" ] && GIT_TOKENS_JSON="{}"
    [ -z "$COMPOSE_SERVICES_RAW" ] && COMPOSE_SERVICES_RAW="[]"
fi

# 2. Login Registries
if [ -f "${CONFIG_FILE:-}" ]; then
    while read -r reg; do
        server=$(jq -r '.server' <<< "$reg" 2>/dev/null || true)
        user=$(jq -r '.user' <<< "$reg" 2>/dev/null || true)
        pass=$(jq -r '.pass' <<< "$reg" 2>/dev/null || true)
        [ -n "$server" ] && printf "%s" "$pass" | regctl registry login "$server" -u "$user" --pass-stdin > /dev/null 2>&1 || true
    done < <(jq -c '.registries[]' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 3. Kiểm tra Updates và Trigger Deploy
echo "🔍 Scanning for applications updates..."
APPS_RES=$(curl -sS --max-time 60 -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications" || true)

if ! printf "%s" "$APPS_RES" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "❌ Lỗi: Không thể lấy danh sách Applications. Phản hồi từ Server:"
    printf "%s\n" "$APPS_RES"
    exit 1
fi

while read -r app; do
    uuid=$(jq -r '.uuid' <<< "$app" 2>/dev/null || true)
    name=$(jq -r '.name' <<< "$app" 2>/dev/null || true)
    image=$(jq -r '.docker_registry_image_name' <<< "$app" 2>/dev/null || true)
    tag=$(jq -r '.docker_registry_image_tag' <<< "$app" 2>/dev/null || true)
    build_pack=$(jq -r '.build_pack' <<< "$app" 2>/dev/null || true)
    git_repository=$(jq -r '.git_repository' <<< "$app" 2>/dev/null || true)
    git_branch=$(jq -r '.git_branch' <<< "$app" 2>/dev/null || true)
    [ -z "$uuid" ] && continue

    # 3a. App dạng Docker Image
    if [ "$build_pack" == "dockerimage" ] && [ "$image" != "null" ] && [ -n "$image" ]; then
        if [ -n "$tag" ] && [ "$tag" != "null" ]; then
            ref="$image:$tag"
        else
            ref="$image"
        fi
        remote_digest=$(regctl image digest "$ref" 2>/dev/null || true)

        if [ -n "$remote_digest" ]; then
            old_digest=$(jq -r --arg u "$uuid" '.[$u] // empty' "$STATE_FILE" || true)

            if [ "$remote_digest" != "$old_digest" ]; then
                echo "🚀 Deploying $name ($ref)..."
                if deploy_resource "$uuid" "$name"; then
                    tmp=$(mktemp)
                    jq --arg u "$uuid" --arg d "$remote_digest" '.[$u] = $d' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                    echo "   ✅ Success!"
                fi
            fi
        fi
    fi

    # 3b. App dạng Git Repository (tùy chọn)
    if [ "$GIT_ENABLED" == "true" ] && [ "$build_pack" != "dockerimage" ] && [ "$git_repository" != "null" ] && [ -n "$git_repository" ]; then
        in_whitelist=$(printf "%s" "$GIT_APPS_RAW" | jq -r --arg u "$uuid" '(length == 0) or (index($u) != null)' 2>/dev/null || true)
        if [ "$in_whitelist" != "true" ]; then
            continue
        fi

        branch="${git_branch:-main}"
        [ "$branch" == "null" ] && branch="main"

        # Token cho private repo (nếu có): dùng url.insteadOf để token không lộ trong URL
        git_token=""
        case "$git_repository" in
            https://*)
                repo_host=$(printf "%s" "$git_repository" | sed -E 's|^https://([^/]+)/.*|\1|')
                [ -n "$repo_host" ] && git_token=$(printf "%s" "$GIT_TOKENS_JSON" | jq -r --arg h "$repo_host" '.[$h] // empty' 2>/dev/null || true)
                ;;
        esac

        if [ -n "$git_token" ]; then
            echo "::add-mask::$git_token"
            case "$repo_host" in
                *gitlab*) git_user="oauth2" ;;
                *) git_user="x-access-token" ;;
            esac
            sha=$(GIT_TERMINAL_PROMPT=0 timeout 20 git -c "url.https://${git_user}:${git_token}@${repo_host}/.insteadOf=https://${repo_host}/" ls-remote "$git_repository" "refs/heads/$branch" 2>/dev/null | awk '{print $1}' || true)
        else
            sha=$(GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote "$git_repository" "refs/heads/$branch" 2>/dev/null | awk '{print $1}' || true)
        fi

        if [ -z "$sha" ]; then
            echo "⚠️ skip $name: cannot resolve git sha (repo unreachable or private?)"
            continue
        fi

        old_sha=$(jq -r --arg u "$uuid" '.[$u] // empty' "$STATE_FILE" || true)

        if [ "$GIT_MODE" == "always" ] || [ "$sha" != "$old_sha" ]; then
            echo "🚀 Deploying $name ($git_repository@$branch)..."
            if deploy_resource "$uuid" "$name"; then
                tmp=$(mktemp)
                jq --arg u "$uuid" --arg s "$sha" '.[$u] = $s' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                echo "   ✅ Success!"
            fi
        fi
    fi
done < <(printf "%s" "$APPS_RES" | jq -c '.[]' 2>/dev/null || true)

# 3c. Compose Services (tùy chọn)
if [ "$COMPOSE_ENABLED" == "true" ]; then
    echo "🔍 Scanning compose services..."
    SERVICES_RES=$(curl -sS --max-time 60 -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/services" || true)

    if ! printf "%s" "$SERVICES_RES" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "❌ Lỗi: Không thể lấy danh sách Services. Phản hồi từ Server:"
        printf "%s\n" "$SERVICES_RES"
        exit 1
    fi

    while read -r svc; do
        svc_uuid=$(jq -r '.uuid' <<< "$svc" 2>/dev/null || true)
        svc_name=$(jq -r '.name' <<< "$svc" 2>/dev/null || true)
        svc_type=$(jq -r '.service_type' <<< "$svc" 2>/dev/null || true)
        [ -z "$svc_uuid" ] && continue
        [ "$svc_name" == "null" ] && svc_name="$svc_uuid"

        # Chỉ xử lý: uuid trong whitelist (nếu có), hoặc service tùy biến (service_type == null)
        # COMPOSE_FILTER_TEMPLATES=true: lọc bỏ template/marketplace service (service_type != null)
        if [ "$COMPOSE_SERVICES_RAW" != "[]" ]; then
            in_whitelist=$(printf "%s" "$COMPOSE_SERVICES_RAW" | jq -r --arg u "$svc_uuid" 'index($u) != null' 2>/dev/null || true)
            if [ "$in_whitelist" != "true" ]; then
                continue
            fi
        elif [ "$COMPOSE_FILTER_TEMPLATES" == "true" ]; then
            [ "$svc_type" != "null" ] && continue
        fi

        svc_detail=$(curl -sS --max-time 60 -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/services/$svc_uuid" || true)

        declare -A current_digests=()
        changed="false"
        while read -r img; do
            [ -z "$img" ] && continue
            digest=$(regctl image digest "$img" 2>/dev/null || true)
            if [ -z "$digest" ]; then
                echo "⚠️ skip image $img: cannot resolve digest"
                continue
            fi
            current_digests["$img"]="$digest"
            old_digest=$(jq -r --arg s "$svc_uuid" --arg i "$img" '.[$s][$i] // empty' "$STATE_FILE" || true)
            if [ "$digest" != "$old_digest" ]; then
                changed="true"
            fi
        done < <(printf "%s" "$svc_detail" | jq -r '.applications[]?.image // empty, .databases[]?.image // empty' 2>/dev/null | sort -u || true)

        # Không tìm thấy image nào -> bỏ qua
        if [ "${#current_digests[@]}" -eq 0 ]; then
            continue
        fi

        if [ "$changed" == "true" ]; then
            echo "🚀 Deploying compose service $svc_name ($svc_uuid)..."
            if deploy_service "$svc_uuid" "$svc_name"; then
                tmp=$(mktemp)
                # Chỉ merge digest đã resolve, GIỮ nguyên digest cũ của image
                # chưa resolve được trong lần chạy này (tránh mất mốc so sánh)
                jq --arg s "$svc_uuid" '.[$s] //= {}' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                for img in "${!current_digests[@]}"; do
                    tmp=$(mktemp)
                    jq --arg s "$svc_uuid" --arg i "$img" --arg d "${current_digests[$img]}" '.[$s][$i] = $d' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                done
                echo "   ✅ Success!"
            fi
        fi
    done < <(printf "%s" "$SERVICES_RES" | jq -c '.[]' 2>/dev/null || true)
fi

# 4. Mã hóa lại & Dọn dẹp
if [ -n "${STATE_PWD:-}" ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$STATE_FILE" -out "$STATE_FILE_ENC" -pass env:STATE_PWD
    rm -f "$STATE_FILE"
fi
rm -f "$TEMP_CONFIG"
echo "✅ CI/CD Scan Finished."
