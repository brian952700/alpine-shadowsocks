#!/bin/sh
# Alpine/OpenRC and Debian 12+/systemd.
set -eu
umask 077
SERVICE=ss-alpine
DIR=/etc/ss-alpine
CONFIG=$DIR/config.json
# User-facing output bypasses the detailed installation log.
exec 3>&1
cyan='' green='' yellow='' red='' reset=''
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then
    cyan=$(printf '\033[36m'); green=$(printf '\033[32m')
    yellow=$(printf '\033[33m'); red=$(printf '\033[31m'); reset=$(printf '\033[0m')
fi
log='' work='' temp='' tty_hidden=0
cleanup() {
    result=$?
    trap - EXIT
    if [ "$tty_hidden" = 1 ]; then stty echo < /dev/tty || true; fi
    if [ -n "$temp" ]; then rm -f "$temp"; fi
    if [ -n "$work" ]; then rm -rf "$work"; fi
    if [ "$result" -ne 0 ] && [ -n "$log" ]; then
        printf '\n%s  × 安装未完成%s\n  详细日志：%s\n\n' "$red" "$reset" "$log" >&3
        tail -n 15 "$log" >&3
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
fail() { printf '\n%s  × %s%s\n' "$red" "$*" "$reset" >&3; exit 1; }
line() { printf '\n  ────────────────────────────────────────\n\n' >&3; }
heading() {
    line
    printf '%s  Shadowsocks 安装助手%s\n  Debian / Alpine · IPv4 + IPv6\n' "$cyan" "$reset" >&3
    line
}
step() { printf '%s  [%s/5] %s%s\n' "$cyan" "$1" "$2" "$reset" >&3; }
ok() { printf '%s        ✓ %s%s\n\n' "$green" "$*" "$reset" >&3; }
warn() { printf '%s  ! %s%s\n' "$yellow" "$*" "$reset" >&3; }
prompt() {
    printf '  %s [%s]：' "$1" "$2" >&3
    IFS= read -r answer < /dev/tty || fail "未读取到输入"
}
interactive_config() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then fail "交互模式需要终端；自动安装请去掉 --interactive"; fi
    heading
    printf '  系统       %s\n' "${PRETTY_NAME:-$ID}" >&3
    if [ -f "$CONFIG" ]; then
        warn "检测到已有配置，将保留端口、密码和加密方式。"
        prompt '保留配置并升级？y/N' N
        case "$answer" in y|Y) ;; *) printf '  已取消，未修改安装。\n' >&3; exit 0;; esac
    else
        prompt '监听端口' "${SS_PORT:-22335}"; SS_PORT=${answer:-${SS_PORT:-22335}}
        prompt '加密方式' "${SS_METHOD:-aes-256-gcm}"; SS_METHOD=${answer:-${SS_METHOD:-aes-256-gcm}}
        prompt '监听地址（:: 双栈 / 0.0.0.0 IPv4）' "${SS_LISTEN:-::}"; SS_LISTEN=${answer:-${SS_LISTEN:-::}}
        printf '  密码 [回车使用现有默认值，输入隐藏]：' >&3
        stty -echo < /dev/tty
        tty_hidden=1
        IFS= read -r answer < /dev/tty || fail "未读取到密码"
        stty echo < /dev/tty
        tty_hidden=0
        printf '\n' >&3
        SS_PASSWORD=${answer:-${SS_PASSWORD-12345}}
        prompt '公网域名或 IP（留空自动查询）' "${SS_HOST:-自动}"
        SS_HOST=${answer:-${SS_HOST:-}}
        printf '\n  端口 %s · %s · 监听 %s\n' "$SS_PORT" "$SS_METHOD" "$SS_LISTEN" >&3
        prompt '开始安装？Y/n' Y
        case "$answer" in n|N) printf '  已取消，未修改安装。\n' >&3; exit 0;; esac
    fi
}
usage() {
    cat <<'EOF'
用法：sh install.sh [install|show|start|stop|restart|status|uninstall]
默认 install；重复安装保留配置。可用 --interactive 进入交互模式。
SS_PORT / SS_PASSWORD / SS_METHOD 仅用于首次安装；其他选项见说明：
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
    line
    printf '  连接信息\n\n  监听地址   %s\n  端口       %s · TCP / UDP\n  加密方式   %s\n  配置文件   %s\n' \
        "$(jq -r .server "$CONFIG")" "$(jq -r .server_port "$CONFIG")" "$(jq -r .method "$CONFIG")" "$CONFIG" >&3
    if [ -n "$host" ]; then
        case "$host" in *[!a-zA-Z0-9.:_-]*) fail "SS_HOST 格式不正确";; esac
        case "$host" in *:*) host="[$host]";; esac
        credentials=$(jq -jr '.method,":",.password' "$CONFIG" | base64 | tr -d '\n=' | tr '+/' '-_')
        port=$(jq -r '.server_port' "$CONFIG")
        printf '\n%s  客户端导入链接（含密码）：%s\n\nss://%s@%s:%s#Shadowsocks\n' "$green" "$reset" "$credentials" "$host" "$port"
    else
        printf '%s\n' "公网 IP 查询失败。生成链接：SS_HOST=你的公网IP或域名 sh install.sh show" "查看密码：jq -r .password $CONFIG"
    fi
}
interactive=0
case "${1:-install}" in -h|--help|help) usage; exit 0;; esac
[ "$#" -le 1 ] || { usage; exit 1; }
action=${1:-install}
if [ "$action" = --interactive ]; then interactive=1; action=install; fi
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
if [ "$interactive" = 1 ]; then interactive_config; else heading; fi
mkdir -p /var/log/ss-alpine
chmod 700 /var/log/ss-alpine
log=$(mktemp /var/log/ss-alpine/install.log.XXXXXX)
printf '  系统       %s\n  安装日志   %s\n\n' "${PRETTY_NAME:-$ID}" "$log" >&3
install_main() {
step 1 '检查系统与运行环境'
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
ok '系统与配置参数检查完成'
step 2 '安装程序和依赖（详细输出写入日志）'
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
fi
[ -x "$binary" ] || fail "未找到 ssserver"
ok "程序已就绪"
step 3 '写入配置与服务账户'
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
    jq -n --arg password "$password" --arg method "$method" --argjson port "$port" --arg listen "${SS_LISTEN:-::}" \
        '{server:$listen,server_port:$port,password:$password,method:$method,mode:"tcp_and_udp",timeout:300,ipv6_only:false}' > "$temp"
    chown root:ss-alpine "$temp"
    chmod 640 "$temp"
    mv "$temp" "$CONFIG"
fi
# Upgrade old wildcard listeners while preserving credentials and custom addresses.
temp=$(mktemp "$DIR/.config.XXXXXX")
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
jq -e '.server_port >= 1024 and .server_port <= 65535 and (.password | type == "string" and length > 0)' "$CONFIG" >/dev/null || fail "现有配置无效"
ok '配置已就绪，已有凭据保留'
step 4 '设置服务与开机启动'
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
ok '开机启动已启用'
step 5 '检查服务状态'
if [ "${SS_START:-1}" != 0 ]; then
service_action restart
sleep 2
service_action status || fail "服务启动失败，请检查配置、IPv6 支持和端口占用"
ok '服务正在运行'
else
    ok '仅准备模式：已跳过服务启动'
fi
}
install_main >> "$log" 2>&1
line
if [ "${SS_START:-1}" = 0 ]; then
    warn '安装文件已准备完成，服务尚未启动。'
else
    ok '安装完成，服务正在运行'
fi
show
line
printf '  查看链接   sh /tmp/ss-install.sh show\n  重启服务   sh /tmp/ss-install.sh restart\n  查看日志   cat %s\n\n' "$log" >&3
warn '请在云安全组和主机防火墙放行所配置端口的 TCP 与 UDP。'


