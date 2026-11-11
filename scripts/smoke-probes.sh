# shellcheck shell=bash
# Halo 的冒烟探针。首页断言主题真实结构；身份用 init 建好的管理员走 Basic 认证调 Halo 当前用户接口；
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

web_assert() { # 首页：主题的真实结构 + 站点标题；/console 未登录时是 Halo 登录页
    grep -q 'id="header-menu"' || { echo "首页没有主题的 header-menu"; return 1; }
    grep -q '我的博客' || { echo "首页没有站点标题"; return 1; }
    local console
    console="$(dweb /console -L)" || { echo "请求 /console 失败"; return 1; }
    grep -q 'halo-form-wrapper' <<<"$console" || { echo "/console 不是登录页：$(head -c 120 <<<"$console")"; return 1; }
}

identity_check() { # 用管理员账号走 Basic 认证调当前用户接口，断言认出的就是 init 建的账号
    local pass out user
    pass="$(admin_key)" || { echo "读不到管理员密码：init 容器不在？"; return 1; }
    out="$(web_get /apis/api.console.halo.run/v1alpha1/users/- -u "$(_halo_admin):$pass")" ||
        { echo "当前用户接口失败：$(head -c 200 <<<"$out")"; return 1; }
    user="$(jq -r '.metadata.name // empty' <<<"$out")"
    [[ "$user" == "$(_halo_admin)" ]] || { echo "当前用户是 $user，不是管理员 $(_halo_admin)：$(head -c 200 <<<"$out")"; return 1; }
}

MCP_TOOL=halo_list_posts
MCP_ARGS='{}'
mcp_assert() { # halo_list_posts 的结果：正文里带 "Listed N posts"，结构化内容里有 items
    grep -q '"Listed ' <<<"$(cat)" || { echo "结果里没有 Listed：$(head -c 200)"; return 1; }
}

data_write() { # 经 API 发一篇带随机标记的文章并发布，标记写进 $SMOKE_STATE
    local pass marker name slug title out
    pass="$(admin_key)" || { echo "读不到管理员密码：init 容器不在？"; return 1; }
    marker="smoke-$(date +%s)-$RANDOM"
    title="冒烟 $marker"
    slug="$marker"
    out="$(web_get /apis/api.console.halo.run/v1alpha1/posts -u "$(_halo_admin):$pass" \
        -H 'Content-Type: application/json' \
        --data-binary "$(printf '{"post":{"spec":{"title":"%s","slug":"%s"},"apiVersion":"post.halo.run/v1alpha1","kind":"Post","metadata":{"generateName":"post-"}},"content":{"raw":"# %s","content":"<p>%s</p>","rawType":"markdown"}}' "$title" "$slug" "$marker" "$marker")")" ||
        { echo "建文章失败：$(head -c 300 <<<"$out")"; return 1; }
    name="$(jq -r '.metadata.name // empty' <<<"$out")"
    [[ -n "$name" ]] || { echo "建文章没返回名字：$(head -c 300 <<<"$out")"; return 1; }
    out="$(web_get "/apis/api.console.halo.run/v1alpha1/posts/$name/publish" -u "$(_halo_admin):$pass" -X PUT)" ||
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
