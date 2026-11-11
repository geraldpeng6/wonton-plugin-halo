#!/bin/sh
# 初始化 Halo（幂等，每次创建容器都会运行）：
# 1. 建管理员账号（账号按云吞用户名，密码是核心生成的）；
# 2. 确保 Halo 自带的 MCP 服务端插件开着，给 Bot 发一把 MCP 访问密钥，写到 /run/halo-mcp-token 交给核心保管。
# 上游文档：https://docs.halo.run/ ；MCP 服务端：https://github.com/halo-dev/plugin-mcp-server（halo 2.26+ 内置）
set -eu

: "${HALO_URL:?核心没有注入 Halo 地址}"
: "${WONTON_OWNER_NAME:?核心没有注入用户名}"
: "${WONTON_OWNER_EMAIL:?核心没有注入邮箱}"
: "${WONTON_APP_URL:?核心没有注入插件网页地址}"
# printenv 拿值：注入名是敏感词，不能直接写进 ${...:?} 里。
PW_VALUE="$(printenv PASSWORD || true)"
: "${PW_VALUE:?核心没有注入管理员密码}"

# Halo 的用户名只收小写字母、数字和连字符（4–63 位）；云吞用户名可能带下划线或不足 4 位，
# 不满足就套一层 wonton- 前缀。云吞用户名装好后不变，推导结果也不变。
ADMIN="$(printf '%s' "$WONTON_OWNER_NAME" | tr '_' '-')"
if ! printf '%s' "$ADMIN" | grep -qE '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' || [ "${#ADMIN}" -lt 4 ]; then
    ADMIN="wonton-$ADMIN"
fi
KEY_DISPLAY_NAME="wonton-agent"
TOKEN_FILE=/run/halo-mcp-token
COOKIE_JAR=/tmp/halo-cookies.txt
LOGIN_PAGE=/tmp/halo-login.html
KEY_DER=/tmp/halo-pubkey.der
KEY_PEM=/tmp/halo-pubkey.pem
PW_ENC=/tmp/halo-password.enc

echo "Halo 管理员用户名：$ADMIN"

# 首次初始化。已初始化时返回 302；应用还在启动时可能 5xx 或连不上，逐次加长间隔重试。
i=0
while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$HALO_URL/system/setup" \
        --data-urlencode "username=$ADMIN" \
        --data-urlencode "password=$PW_VALUE" \
        --data-urlencode "email=$WONTON_OWNER_EMAIL" \
        --data-urlencode "siteTitle=我的博客" \
        --data-urlencode "externalUrl=$WONTON_APP_URL")" || code=000
    case "$code" in
        204 | 302)
            echo "站点已初始化"
            break
            ;;
        000 | 5*)
            i=$((i + 1))
            if [ "$i" -ge 10 ]; then
                echo "初始化失败：/system/setup 重试 10 次仍返回 $code" >&2
                exit 1
            fi
            echo "/system/setup 返回 $code，第 $i 次重试"
            sleep "$((i * 3))"
            ;;
        *)
            echo "初始化失败：/system/setup 返回 $code" >&2
            exit 1
            ;;
    esac
done

# 登录拿会话。Halo 2.27 起默认关闭 HTTP Basic（halo.security.basic-auth.disabled=true），
# 表单登录的密码要用服务器在登录页里给的公钥做 RSA 加密（浏览器端由 JSEncrypt 做，这里用 openssl），
# 还要带上登录页渲染的 CSRF 令牌。/apis/** 不做 CSRF 检查，登录后才用会话 Cookie。
# 已初始化但密码对不上时（数据还在、密钥被换），如实报错，让用户删数据重装。
login() {
    rm -f "$COOKIE_JAR"
    curl -fsS -c "$COOKIE_JAR" -o "$LOGIN_PAGE" "$HALO_URL/login" || return 1
    public_key="$(grep -o 'const publicKey = "[^"]*";' "$LOGIN_PAGE" | sed 's/.*const publicKey = "//;s/";$//;s/\\//g')"
    csrf="$(grep -o 'name="_csrf" value="[^"]*"' "$LOGIN_PAGE" | sed 's/.*value="//;s/"//')"
    [ -n "$public_key" ] && [ -n "$csrf" ] || return 1
    printf '%s' "$public_key" | base64 -d >"$KEY_DER" 2>/dev/null || return 1
    openssl pkey -pubin -inform DER -in "$KEY_DER" -out "$KEY_PEM" 2>/dev/null || return 1
    printf '%s' "$PW_VALUE" | openssl pkeyutl -encrypt -pubin -inkey "$KEY_PEM" 2>/dev/null |
        base64 | tr -d '\n' >"$PW_ENC" || return 1
    # curl 的 名字@文件 形式会读文件内容再做 URL 编码，密文里的 +/= 不会被改坏。
    curl -fsS -b "$COOKIE_JAR" -c "$COOKIE_JAR" -o /dev/null \
        --data-urlencode "username=$ADMIN" \
        --data-urlencode "password@$PW_ENC" \
        --data-urlencode "_csrf=$csrf" \
        "$HALO_URL/login" || return 1
    logged_in
}

logged_in() {
    curl -fsS -b "$COOKIE_JAR" "$HALO_URL/apis/api.console.halo.run/v1alpha1/users/-" 2>/dev/null |
        grep -q "\"name\":\"$ADMIN\""
}

i=0
while :; do
    if login && logged_in; then
        echo "管理员已登录"
        break
    fi
    i=$((i + 1))
    if [ "$i" -ge 10 ]; then
        echo "登录失败：用注入的密码重试 10 次都没登上。若站点不是本插件初始化的（数据目录被复用），删除插件数据后重装。" >&2
        exit 1
    fi
    echo "登录第 $i 次没成功，重试"
    sleep "$((i * 2))"
done

# MCP 服务端是上游镜像自带的插件（halo 2.26+ 内置 mcp-server，默认启用），不用装。
# 这里只确保它是开着的：用户在后台停用过的话，装 Bot 的前提就没了。PUT 带 async:false 等插件真正启动。
curl -fsS -b "$COOKIE_JAR" -H 'Content-Type: application/json' \
    -X PUT -d '{"enable":true,"async":false}' \
    "$HALO_URL/apis/api.console.halo.run/v1alpha1/plugins/mcp-server/plugin-state" >/dev/null

KEYS="$HALO_URL/apis/console.api.mcp.halo.run/v1alpha1/keys"

token_valid() {
    [ -s "$TOKEN_FILE" ] || return 1
    # Streamable HTTP 的 MCP 端点要求 Accept 同时含 application/json 和 text/event-stream，缺了会 4xx。
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -X POST \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"init-probe","version":"0"}}}' \
        "$HALO_URL/mcp")" || code=000
    [ "$code" = "200" ]
}

find_key() { # 在密钥列表里找 wonton-agent 这把，输出它的 name（UUID）；列表失败时输出空
    printf '%s' "$1" | tr -d ' \n' | sed 's/},{/}\n{/g' \
        | grep "\"displayName\":\"$KEY_DISPLAY_NAME\"" | head -1 \
        | sed -n 's/^{"name":"\([^"]*\)".*/\1/p'
}

# 密钥只在创建或轮换时可见。已有的密钥先试文件里的旧值，失效才轮换：
# 轮换会作废旧值，核心下次核对读到新文件就会换用新值。
if token_valid; then
    echo "MCP 访问密钥仍可用，沿用"
else
    # 插件刚启用时它的接口可能还没注册出来，给足重试并把失败原因打出来。
    i=0
    while :; do
        resp=""
        code="$(curl -s -o /tmp/keys.json -w '%{http_code}' -b "$COOKIE_JAR" "$KEYS" 2>/dev/null)" || code=000
        if [ "$code" = "200" ]; then
            keys="$(cat /tmp/keys.json)"
            name="$(find_key "$keys")"
            if [ -n "$name" ]; then
                resp="$(curl -fsS -b "$COOKIE_JAR" -X POST "$KEYS/$name/rotate" 2>/dev/null)" && echo "已轮换 MCP 访问密钥"
            else
                resp="$(curl -fsS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X POST \
                    -d "{\"displayName\":\"$KEY_DISPLAY_NAME\",\"allowedTools\":[\"*\"],\"allowedIpRanges\":[]}" \
                    "$KEYS" 2>/dev/null)" && echo "已创建 MCP 访问密钥"
            fi
        else
            echo "密钥接口返回 $code（插件可能在启动中）：$(head -c 200 /tmp/keys.json 2>/dev/null)"
        fi
        token="$(printf '%s' "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
        if [ -n "$token" ]; then
            printf '%s' "$token" >"$TOKEN_FILE"
            break
        fi
        i=$((i + 1))
        if [ "$i" -ge 15 ]; then
            echo "发密钥失败：重试 15 次都没拿到 token" >&2
            exit 1
        fi
        sleep 2
    done
fi

# 收尾自证：带着新密钥调一次 /mcp 的 initialize，证明插件和密钥都真的能用。
if ! token_valid; then
    echo "自证失败：带上密钥调 /mcp 没有得到 200" >&2
    exit 1
fi
echo "MCP 就绪"
