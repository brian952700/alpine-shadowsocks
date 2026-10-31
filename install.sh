#!/bin/sh
# Alpine/OpenRC and Debian 12+/systemd.
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
  SS_LISTEN=::（双栈；可设为 0.0.0.0 仅监听 IPv4，安装时也可修改现有监听地址）
  SS_START=0（仅安装和启用服务，暂不启动；默认 1）
EOF
}
show() {
    [ -f "$CONFIG" ] || fail "尚未安装"
    host=${SS_HOST:-}
    if [ -z "$host" ]; then
        printf '%s\n' "正在查询公网 IP，以生成 SS 链接……" >&2
        host=$(curl -4 --fail --silent --show-error --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null) || host=
        if [ -z "$host" ]; then
            host=$(curl -6 --fail --silent --show-error --connect-timeout 3 --max-time 5 https://api6.ipify.org 2>/dev/null) || host=
        fi
    fi
    printf '配置：%s\n' "$CONFIG"
    jq '{server,server_port,method,mode}' "$CONFIG"
    if [ -n "$host" ]; then
        case "$host" in *[!a-zA-Z0-9.:_-]*) fail "SS_HOST 格式不正确";; esac
        case "$host" in *:*) host="[$host]";; esac
        credentials=$(jq -jr '.method,":",.password' "$CONFIG" | base64 | tr -d '\n=' | tr '+/' '-_')
        port=$(jq -r '.server_port' "$CONFIG")
        printf '连接链接（含密码，请妥善保存）：\nss://%s@%s:%s#Shadowsocks\n' "$credentials" "$host" "$port"
    else
        printf '%s\n' "公网 IP 查询失败。生成链接：SS_HOST=你的公网IP或域名 sh install.sh show" "查看密码：jq -r .password $CONFIG"
    fi
}
case "${1:-install}" in -h|--help|help) usage; exit 0;; esac
[ "$#" -le 1 ] || { usage; exit 1; }
action=${1:-install}
case "$action" in install|show|start|stop|restart|status|uninstall) ;; *) usage; exit 1;; esac
[ "$(id -u)" -eq 0 ] || fail "请以 root 运行"
[ -f /etc/os-release ] || fail "无法识别系统"
# shellcheck disable=SC1091
. /etc/os-release
case "$ID" in
    alpine) platform=alpine; binary=/usr/bin/ssserver;;
    debian)
        major=${VERSION_ID%%.*}
        case "$major" in ''|*[!0-9]*) fail "需要 Debian 12 或以上正式版本";; esac
        [ "$major" -ge 12 ] || fail "需要 Debian 12 或以上"
        platform=debian; binary=/usr/local/bin/ssserver;;
    *) fail "仅支持 Alpine Linux 和 Debian 12 及以上";;
esac
service_action() {
    if [ "$platform" = alpine ]; then
        rc-service "$SERVICE" "$1"
    else
        systemctl --no-pager --full "$1" "$SERVICE.service"
    fi
}
case "$action" in
    show) show; exit;;
    start|stop|restart|status) service_action "$action"; exit;;
    uninstall)
        service_action stop || true
        if [ "$platform" = alpine ]; then
            rc-update del "$SERVICE" default || true
            rm -f "/etc/init.d/$SERVICE"
        else
            systemctl disable "$SERVICE.service" || true
            rm -f "/etc/systemd/system/$SERVICE.service"
            systemctl daemon-reload
        fi
        printf '%s\n' "服务已移除，配置及软件包保留。配置目录：$DIR"
        exit;;
esac
if [ "${SS_START:-1}" != 0 ]; then
    if [ "$platform" = alpine ]; then
        command -v rc-service >/dev/null 2>&1 || fail "需要 OpenRC"
        [ -d /run/openrc ] || fail "OpenRC 尚未运行"
    else
        [ -d /run/systemd/system ] || fail "需要运行中的 systemd；仅准备文件可设置 SS_START=0"
    fi
fi
port=${SS_PORT:-22335}
method=${SS_METHOD:-aes-256-gcm}
if [ ! -f "$CONFIG" ]; then
    case "$port" in ''|*[!0-9]*|??????*) fail "端口必须为 1024–65535";; esac
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        fail "端口必须为 1024–65535"
    fi
    case "$method" in chacha20-ietf-poly1305|aes-256-gcm|aes-128-gcm) ;; *) fail "不支持的加密方式";; esac
fi
if [ "$platform" = alpine ]; then
# Use the matching stable release's community repository; never mix in edge.
release=$(cut -d. -f1,2 /etc/alpine-release)
case "$release" in 3.[0-9]*) ;; *) fail "需要 Alpine 稳定版";; esac
repo="https://dl-cdn.alpinelinux.org/alpine/v$release/community"
apk add --no-cache --repository "$repo" shadowsocks-rust-ssserver jq curl ca-certificates
else
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq xz-utils systemd adduser
    case "$(dpkg --print-architecture)" in
        amd64) target=x86_64-unknown-linux-musl;;
        arm64) target=aarch64-unknown-linux-musl;;
        *) fail "Debian 当前支持 amd64 和 arm64";;
    esac
    version=v1.25.0
    asset="shadowsocks-$version.$target.tar.xz"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT HUP INT TERM
    curl --fail --silent --show-error --location --retry 3 --proto '=https' \
        "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/tags/$version" -o "$work/release.json"
    digest=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .digest | select(startswith("sha256:"))' "$work/release.json") || fail "官方发布缺少 SHA256 摘要"
    checksum=${digest#sha256:}
    [ "${#checksum}" -eq 64 ] || fail "无效 SHA256"
    case "$checksum" in *[!a-fA-F0-9]*) fail "无效 SHA256";; esac
    curl --fail --silent --show-error --location --retry 3 --proto '=https' \
        "https://github.com/shadowsocks/shadowsocks-rust/releases/download/$version/$asset" -o "$work/archive.tar.xz"
    printf '%s  %s\n' "$checksum" "$work/archive.tar.xz" | sha256sum -c -
    tar -xJf "$work/archive.tar.xz" -C "$work" ssserver
    "$work/ssserver" --version
    install -m 755 "$work/ssserver" "$binary"
    rm -rf "$work"
    trap - EXIT HUP INT TERM
fi
[ -x "$binary" ] || fail "未找到 ssserver"
if [ "$platform" = alpine ]; then
    if ! grep -q '^ss-alpine:' /etc/group; then addgroup -S ss-alpine; fi
fi
if ! id ss-alpine >/dev/null 2>&1; then
    if [ "$platform" = alpine ]; then
        adduser -S -D -H -G ss-alpine -s /sbin/nologin ss-alpine
    else
        adduser --system --group --no-create-home --home /nonexistent --shell /usr/sbin/nologin ss-alpine
    fi
fi
mkdir -p "$DIR"
chown root:ss-alpine "$DIR"
chmod 750 "$DIR"
if [ ! -f "$CONFIG" ]; then
    password=${SS_PASSWORD-12345}
    [ -n "$password" ] || fail "密码不能为空"
    temp=$(mktemp "$DIR/.config.XXXXXX")
    trap 'rm -f "$temp"' EXIT HUP INT TERM
    jq -n --arg password "$password" --arg method "$method" --argjson port "$port" --arg listen "${SS_LISTEN:-::}" \
        '{server:$listen,server_port:$port,password:$password,method:$method,mode:"tcp_and_udp",timeout:300,ipv6_only:false}' > "$temp"
    chown root:ss-alpine "$temp"
    chmod 640 "$temp"
    mv "$temp" "$CONFIG"
    trap - EXIT HUP INT TERM
fi
# Upgrade old wildcard listeners while preserving credentials and custom addresses.
temp=$(mktemp "$DIR/.config.XXXXXX")
trap 'rm -f "$temp"' EXIT HUP INT TERM
jq --arg listen "${SS_LISTEN:-}" '
    .server = (if $listen != "" then $listen elif .server == "0.0.0.0" then "::" else .server end)
    | if .server == "::" then .ipv6_only = false else . end
' "$CONFIG" > "$temp"
if ! cmp -s "$CONFIG" "$temp"; then
    cp -p "$CONFIG" "$CONFIG.bak.$(date +%s)"
    chown root:ss-alpine "$temp"
    chmod 640 "$temp"
    mv "$temp" "$CONFIG"
else
    rm -f "$temp"
fi
trap - EXIT HUP INT TERM
jq -e '.server_port >= 1024 and .server_port <= 65535 and (.password | type == "string" and length > 0)' "$CONFIG" >/dev/null || fail "现有配置无效"
if [ "$platform" = alpine ]; then
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
else
cat > "/etc/systemd/system/$SERVICE.service" <<'EOF'
[Unit]
Description=Shadowsocks Rust server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=ss-alpine
Group=ss-alpine
ExecStart=/usr/local/bin/ssserver -c /etc/ss-alpine/config.json
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF
if [ "${SS_START:-1}" != 0 ]; then systemctl daemon-reload; fi
systemctl enable "$SERVICE.service"
fi
if [ "${SS_START:-1}" != 0 ]; then
service_action restart
sleep 2
service_action status || fail "服务启动失败，请检查配置、IPv6 支持和端口占用"
fi
show
printf '%s\n' "请在云安全组和主机防火墙放行所配置端口的 TCP 与 UDP。"

