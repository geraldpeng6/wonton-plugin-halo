#!/bin/sh
# 初始化 Halo（幂等，每次创建容器都会运行）：
# 1. 建管理员账号（账号按云吞用户名，密码是核心生成的）；
# 2. 装随插件包带来的 Halo 官方 MCP 插件（halo-dev/plugin-mcp-server）；
# 3. 给 Bot 发一把 MCP 访问密钥，写到 /run/halo-mcp-token 交给核心保管。
# 上游文档：https://docs.halo.run/ ；MCP 插件：https://github.com/halo-dev/plugin-mcp-server
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
AUTH="$ADMIN:$PW_VALUE"
KEY_DISPLAY_NAME="wonton-agent"
TOKEN_FILE=/run/halo-mcp-token

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

# MCP 插件：已装且版本一致就跳过，没装就装，版本不同就升级。
JAR=/seed/plugin-mcp-server-1.3.3.jar
PLUGIN_VERSION=1.3.3
PLUGIN_BASE="$HALO_URL/apis/api.console.halo.run/v1alpha1/plugins"
version=""
if body="$(curl -fsS -u "$AUTH" "$HALO_URL/api/v1alpha1/plugins/mcp-server" 2>/dev/null)"; then
    version="$(printf '%s' "$body" | tr -d ' \n' | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
fi
case "$version" in
    "$PLUGIN_VERSION")
        echo "MCP 插件已是 $PLUGIN_VERSION"
        ;;
    "")
        curl -fsS -u "$AUTH" -F "file=@$JAR" "$PLUGIN_BASE/install" >/dev/null
        echo "MCP 插件已安装（$PLUGIN_VERSION）"
        ;;
    *)
        curl -fsS -u "$AUTH" -F "file=@$JAR" "$PLUGIN_BASE/mcp-server/upgrade" >/dev/null
        echo "MCP 插件已从 $version 升级到 $PLUGIN_VERSION"
        ;;
esac

# 上游会记录期望状态：装完是停用的，这里打开。PUT 带 async:false 时等插件真正启动。
curl -fsS -u "$AUTH" -H 'Content-Type: application/json' \
    -X PUT -d '{"enable":true,"async":false}' "$PLUGIN_BASE/mcp-server/plugin-state" >/dev/null

KEYS="$HALO_URL/apis/console.api.mcp.halo.run/v1alpha1/keys"

token_valid() {
    [ -s "$TOKEN_FILE" ] || return 1
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
        -H 'Content-Type: application/json' \
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
    i=0
    while :; do
        resp=""
        if keys="$(curl -fsS -u "$AUTH" "$KEYS" 2>/dev/null)"; then
            name="$(find_key "$keys")"
            if [ -n "$name" ]; then
                resp="$(curl -fsS -u "$AUTH" -X POST "$KEYS/$name/rotate" 2>/dev/null)" || resp=""
                [ -n "$resp" ] && echo "已轮换 MCP 访问密钥"
            else
                resp="$(curl -fsS -u "$AUTH" -H 'Content-Type: application/json' -X POST \
                    -d "{\"displayName\":\"$KEY_DISPLAY_NAME\",\"allowedTools\":[\"*\"],\"allowedIpRanges\":[]}" \
                    "$KEYS" 2>/dev/null)" || resp=""
                [ -n "$resp" ] && echo "已创建 MCP 访问密钥"
            fi
        fi
        token="$(printf '%s' "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
        if [ -n "$token" ]; then
            printf '%s' "$token" >"$TOKEN_FILE"
            break
        fi
        i=$((i + 1))
        if [ "$i" -ge 5 ]; then
            echo "发密钥失败：重试 5 次都没拿到 token" >&2
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
