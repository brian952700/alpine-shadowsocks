#!/bin/sh
# Alpine Linux + OpenRC; packages are verified by apk.
set -eu
umask 077
SERVICE=ss-alpine
DIR=/etc/ss-alpine
CONFIG=$DIR/config.json
fail() { printf '%s\n' "错误：$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
用法：sh install.sh [install|show|start|stop|restart|status|uninstall]
默认 install；重复安装保留配置。
可选环境变量（仅首次安装）：
  SS_PORT=22335
  SS_PASSWORD=12345
  SS_METHOD=aes-256-gcm（或 chacha20-ietf-poly1305 / aes-128-gcm）
  SS_HOST=公网IP或域名（生成连接链接时使用）
EOF
}
show() {
    [ -f "$CONFIG" ] || fail "尚未安装"
    host=${SS_HOST:-}
    printf '配置：%s\n' "$CONFIG"
    jq '{server,server_port,method,mode}' "$CONFIG"
    if [ -n "$host" ]; then
        case "$host" in *[!a-zA-Z0-9.:_-]*) fail "SS_HOST 格式不正确";; esac
        case "$host" in *:*) host="[$host]";; esac
        credentials=$(jq -jr '.method,":",.password' "$CONFIG" | base64 | tr -d '\n=' | tr '+/' '-_')
        port=$(jq -r '.server_port' "$CONFIG")
        printf '连接链接（含密码，请妥善保存）：\nss://%s@%s:%s#Alpine-Shadowsocks\n' "$credentials" "$host" "$port"
    else
        printf '%s\n' "查看密码：jq -r .password $CONFIG" "生成链接：SS_HOST=你的公网IP sh install.sh show"
    fi
}
case "${1:-install}" in -h|--help|help) usage; exit 0;; esac
[ "$#" -le 1 ] || { usage; exit 1; }
action=${1:-install}
case "$action" in install|show|start|stop|restart|status|uninstall) ;; *) usage; exit 1;; esac
[ "$(id -u)" -eq 0 ] || fail "请以 root 运行"
[ -f /etc/alpine-release ] || fail "仅支持 Alpine Linux"
case "$action" in
    show) show; exit;;
    start|stop|restart|status) exec rc-service "$SERVICE" "$action";;
    uninstall)
        rc-service "$SERVICE" stop || true
        rc-update del "$SERVICE" default || true
        rm -f "/etc/init.d/$SERVICE"
        printf '%s\n' "服务已移除，配置及软件包保留。配置目录：$DIR"
        exit;;
esac
command -v rc-service >/dev/null 2>&1 || fail "需要使用 OpenRC 的 Alpine 主机（不支持普通 Docker 容器）"
[ -d /run/openrc ] || fail "OpenRC 尚未运行"
port=${SS_PORT:-22335}
method=${SS_METHOD:-aes-256-gcm}
if [ ! -f "$CONFIG" ]; then
    case "$port" in ''|*[!0-9]*|??????*) fail "端口必须为 1024–65535";; esac
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        fail "端口必须为 1024–65535"
    fi
    case "$method" in chacha20-ietf-poly1305|aes-256-gcm|aes-128-gcm) ;; *) fail "不支持的加密方式";; esac
fi
# Use the matching stable release's community repository; never mix in edge.
release=$(cut -d. -f1,2 /etc/alpine-release)
case "$release" in 3.[0-9]*) ;; *) fail "需要 Alpine 稳定版";; esac
repo="https://dl-cdn.alpinelinux.org/alpine/v$release/community"
apk add --no-cache --repository "$repo" shadowsocks-rust-ssserver jq
command -v ssserver >/dev/null 2>&1 || fail "软件包未提供 ssserver"
if ! id ss-alpine >/dev/null 2>&1; then
    adduser -S -D -H -s /sbin/nologin ss-alpine
fi
mkdir -p "$DIR"
chown root:ss-alpine "$DIR"
chmod 750 "$DIR"
if [ ! -f "$CONFIG" ]; then
    password=${SS_PASSWORD-12345}
    [ -n "$password" ] || fail "密码不能为空"
    temp=$(mktemp "$DIR/.config.XXXXXX")
    trap 'rm -f "$temp"' EXIT HUP INT TERM
    jq -n --arg password "$password" --arg method "$method" --argjson port "$port" \
        '{server:"0.0.0.0",server_port:$port,password:$password,method:$method,mode:"tcp_and_udp",timeout:300}' > "$temp"
    chown root:ss-alpine "$temp"
    chmod 640 "$temp"
    mv "$temp" "$CONFIG"
    trap - EXIT HUP INT TERM
fi
jq -e '.server_port >= 1024 and .server_port <= 65535 and (.password | type == "string" and length > 0)' "$CONFIG" >/dev/null || fail "现有配置无效"
cat > "/etc/init.d/$SERVICE" <<'EOF'
#!/sbin/openrc-run
description="Shadowsocks Rust server"
command="/usr/bin/ssserver"
command_args="-c /etc/ss-alpine/config.json"
command_user="ss-alpine:ss-alpine"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=5
respawn_period=60
depend() {
    need net
    after firewall
}
EOF
chmod 755 "/etc/init.d/$SERVICE"
rc-update add "$SERVICE" default
rc-service "$SERVICE" restart
sleep 2
rc-service "$SERVICE" status || fail "服务启动失败，请检查配置和端口占用"
show
printf '%s\n' "请在云安全组和主机防火墙放行所配置端口的 TCP 与 UDP。"

