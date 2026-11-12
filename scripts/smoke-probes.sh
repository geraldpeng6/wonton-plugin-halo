# shellcheck shell=bash disable=SC2034  # MCP_TOOL/MCP_ARGS 由冒烟套件读取
# Halo 的冒烟探针。首页断言主题真实结构；身份表单登录后调 Halo 当前用户接口；
# 数据经 API 发一篇文章，断言首页能看到、重装后还在。MCP 调 Halo MCP 插件的只读工具 halo_list_posts。

# init 一次性服务推导管理员用户名的规则和 init.sh 保持一致：下划线换连字符，
# 不满足 Halo 的用户名规则（小写字母数字连字符、至少 4 位）就套 wonton- 前缀。
_halo_admin() {
    local admin="${SMOKE_OWNER:-}"
    admin="$(printf '%s' "$admin" | tr '_' '-')"
    if ! printf '%s' "$admin" | grep -qE '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' || [ "${#admin}" -lt 4 ]; then
        admin="wonton-$admin"
    fi
    printf '%s' "$admin"
}

# 管理员密码是核心生成、注入给 init 容器的（secrets 不经任何接口返回）。
# init 容器退出后配置还在，从容器环境里读。容器名按核心打的标签找，实例名缺了就从 SMOKE_BASE 推。
_container() { # <插件 id> <服务名>
    local inst="${SMOKE_INSTANCE:-}" args=(--filter "label=wonton.plugin=$1" --filter "label=wonton.service=$2")
    if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
        inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
    fi
    [[ -z "$inst" ]] || args+=(--filter "label=wonton.instance=${inst//-/}")
    docker ps -a --format '{{.Names}}' "${args[@]}" | head -1
}

admin_key() {
    local cid
    cid="$(_container "$SMOKE_PLUGIN_ID" init)" || return 1
    [[ -n "$cid" ]] || return 1
    docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' \
        | grep '^PASSWORD=' | cut -d= -f2-
}

# Halo 2.27 起默认关闭 HTTP Basic；网页走表单登录，密码用登录页里的公钥 RSA 加密，
# CSRF 令牌取同一页渲染的 _csrf。登录后的会话存在 SMOKE_JAR，后续 web_get 自带。
halo_login() { # 失败时输出原因，返回 1
    local pass pk csrf jar html der pem enc
    pass="$(admin_key)" || { echo "读不到管理员密码：init 容器不在？"; return 1; }
    jar="${SMOKE_JAR:?没有会话 jar}"
    # jar 跨探针复用，前面可能已经登录过：已登录就直接用（这时 GET /login 会被 Halo 跳走，拿不到表单）。
    if web_get /apis/api.console.halo.run/v1alpha1/users/- 2>/dev/null | grep -q "\"name\":\"$(_halo_admin)\""; then
        return 0
    fi
    # 临时文件用固定路径（探针串行跑，不并发，残留下次覆盖）。
    html="$SMOKE_DIR/.wonton/halo-login.html"
    der="$SMOKE_DIR/.wonton/halo-pubkey.der"
    pem="$SMOKE_DIR/.wonton/halo-pubkey.pem"
    enc="$SMOKE_DIR/.wonton/halo-password.enc"
    if ! curl_t "$SMOKE_WEB_MAX_TIME" "$SMOKE_WEB_ORIGIN/login" --noproxy '*' -b "$jar" -c "$jar" -o "$html"; then
        echo "登录页拉不到"; return 1
    fi
    pk="$(grep -o 'const publicKey = "[^"]*";' "$html" | sed 's/.*const publicKey = "//;s/";$//;s/\\//g')"
    csrf="$(grep -o 'name="_csrf" value="[^"]*"' "$html" | sed 's/.*value="//;s/"//')"
    [[ -n "$pk" && -n "$csrf" ]] || { echo "登录页里没有公钥或 CSRF 令牌"; return 1; }
    if ! printf '%s' "$pk" | base64 -d >"$der" 2>/dev/null ||
        ! openssl pkey -pubin -inform DER -in "$der" -out "$pem" 2>/dev/null; then
        echo "公钥解析不了"; return 1
    fi
    printf '%s' "$pass" | openssl pkeyutl -encrypt -pubin -inkey "$pem" 2>/dev/null | base64 | tr -d '\n' >"$enc" || {
        echo "密码加密失败"; return 1
    }
    # curl 的 名字@文件 形式会读文件内容再做 URL 编码，密文里的 +/= 不会被改坏。
    curl_t "$SMOKE_WEB_MAX_TIME" "$SMOKE_WEB_ORIGIN/login" --noproxy '*' -b "$jar" -c "$jar" \
        --data-urlencode "username=$(_halo_admin)" \
        --data-urlencode "password@$enc" \
        --data-urlencode "_csrf=$csrf" >/dev/null || true
    web_get /apis/api.console.halo.run/v1alpha1/users/- | grep -q "\"name\":\"$(_halo_admin)\"" || {
        echo "登录后当前用户不是管理员 $(_halo_admin)"; return 1
    }
}

web_assert() { # 标准输入：probes_web 取回的首页（登录会话）；一次读入再断言，stdin 只能读一遍
    local home
    home="$(cat)"
    grep -q 'id="header-menu"' <<<"$home" || { echo "首页没有主题的 header-menu"; return 1; }
    grep -q '我的博客' <<<"$home" || { echo "首页没有站点标题"; return 1; }
}

identity_check() { # 走表单登录拿会话，再调当前用户接口，断言认出的就是 init 建的账号
    halo_login || return 1
    local out user
    out="$(web_get /apis/api.console.halo.run/v1alpha1/users/-)" ||
        { echo "当前用户接口失败：$(head -c 200 <<<"$out")"; return 1; }
    user="$(jq -r '.user.metadata.name // empty' <<<"$out")"
    [[ "$user" == "$(_halo_admin)" ]] || { echo "当前用户是 $user，不是管理员 $(_halo_admin)：$(head -c 200 <<<"$out")"; return 1; }
}

MCP_TOOL=halo_list_posts
MCP_ARGS='{}'
mcp_assert() { # halo_list_posts 的结果：正文里带 "Listed N posts"，结构化内容里有 items
    grep -q '"Listed ' <<<"$(cat)" || { echo "结果里没有 Listed：$(head -c 200)"; return 1; }
}

data_write() { # 经 API 发一篇带随机标记的文章并发布，标记写进 $SMOKE_STATE
    local marker name slug title out
    halo_login || return 1
    marker="smoke-$(date +%s)-$RANDOM"
    title="冒烟 $marker"
    slug="$marker"
    out="$(web_get /apis/api.console.halo.run/v1alpha1/posts \
        -H 'Content-Type: application/json' \
        --data-binary "$(printf '{"post":{"spec":{"title":"%s","slug":"%s","allowComment":true,"deleted":false,"excerpt":{"autoGenerate":true},"pinned":false,"publish":false,"visible":"PUBLIC","priority":0,"tags":[]},"apiVersion":"post.halo.run/v1alpha1","kind":"Post","metadata":{"generateName":"post-"}},"content":{"raw":"# %s","content":"<p>%s</p>","rawType":"markdown"}}' "$title" "$slug" "$marker" "$marker")")" ||
        { echo "建文章失败：$(head -c 300 <<<"$out")"; return 1; }
    name="$(jq -r '.metadata.name // empty' <<<"$out")"
    [[ -n "$name" ]] || { echo "建文章没返回名字：$(head -c 300 <<<"$out")"; return 1; }
    out="$(web_get "/apis/api.console.halo.run/v1alpha1/posts/$name/publish" -X PUT)" ||
        { echo "发布文章失败：$(head -c 300 <<<"$out")"; return 1; }
    printf '%s\n' "$marker" >"$SMOKE_STATE"
}

data_check() { # 从 $SMOKE_STATE 读标记，断言首页能看到这篇已发布的文章
    local marker home
    marker="$(cat "$SMOKE_STATE")"
    home="$(dweb / -L)" || { echo "请求首页失败"; return 1; }
    grep -q "$marker" <<<"$home" ||
        { echo "首页看不到标记 $marker，开头：$(head -c 200 <<<"$home" | tr '\n' ' ')"; return 1; }
}
