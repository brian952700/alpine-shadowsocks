#!/bin/sh
# Alpine/OpenRC and Debian 12+/systemd.
set -eu
umask 077
SERVICE=ss-alpine
DIR=/etc/ss-alpine
CONFIG=$DIR/config.json
RESTART_PENDING=$DIR/.restart-pending
# User-facing output bypasses the detailed installation log.
exec 3>&1
cyan='' green='' yellow='' red='' reset=''
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then
    cyan=$(printf '\033[36m'); green=$(printf '\033[32m')
    yellow=$(printf '\033[33m'); red=$(printf '\033[31m'); reset=$(printf '\033[0m')
fi
log='' work='' temp='' unit_temp='' binary_temp='' restore_temp='' tty_hidden=0
lock_dir='' rollback_dir='' transaction=0
config_changed=0 unit_changed=0 binary_pending=0 binary_changed=0 enable_changed=0 service_touched=0
was_running=0 was_enabled=0
cleanup() {
    result=$?
    trap - EXIT
    if [ "$tty_hidden" = 1 ]; then stty echo < /dev/tty || true; fi
    if [ "$transaction" = 1 ]; then
        if rollback >> "$log" 2>&1; then
            warn '已恢复升级前的文件和服务状态。'
        else
            warn "自动恢复未完成。备份目录：$rollback_dir"
            rollback_dir=''
        fi
    fi
    for staged_file in "$temp" "$unit_temp" "$binary_temp" "$restore_temp"; do
        if [ -n "$staged_file" ]; then rm -f "$staged_file" || true; fi
    done
    if [ -n "$rollback_dir" ]; then rm -rf "$rollback_dir" || true; fi
    if [ -n "$lock_dir" ]; then rmdir "$lock_dir" || true; fi
    if [ -n "$work" ]; then rm -rf "$work" || true; fi
    if [ "$result" -ne 0 ] && [ -n "$log" ]; then
        printf '\n%s  × 安装未完成%s\n  详细日志：%s\n\n' "$red" "$reset" "$log" >&3
        tail -n 15 "$log" >&3 || true
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
fail() { printf '\n%s  × %s%s\n' "$red" "$*" "$reset" >&3; exit 1; }
line() { printf '\n  ────────────────────────────────────────\n\n' >&3; }
heading() {
    printf '\n  ────────────────────────────────────────\n\n%s  Shadowsocks 安装助手%s\n  Debian / Alpine · IPv4 + IPv6\n  系统       %s\n\n  ────────────────────────────────────────\n\n' \
        "$cyan" "$reset" "${PRETTY_NAME:-$ID}" >&3
}
step() { printf '%s  [%s/5] %s%s\n' "$cyan" "$1" "$2" "$reset" >&3; }
ok() { printf '%s        ✓ %s%s\n\n' "$green" "$*" "$reset" >&3; }
warn() { printf '%s  ! %s%s\n' "$yellow" "$*" "$reset" >&3; }
prompt() {
    printf '  %s [%s]：' "$1" "$2" >&3
    read_answer
}
read_answer() {
    IFS= read -r answer < /dev/tty || fail "未读取到输入"
}
interactive_config() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then fail "交互模式需要终端；自动安装请去掉 --interactive"; fi
    heading
    if [ -f "$CONFIG" ]; then
        printf '%s  ! 检测到已有配置，将保留端口、密码和加密方式。%s\n  保留配置并升级？y/N [N]：' "$yellow" "$reset" >&3
        read_answer
        case "$answer" in y|Y) ;; *) printf '  已取消，未修改安装。\n' >&3; exit 0;; esac
    else
        prompt '监听端口' "${SS_PORT:-22335}"; SS_PORT=${answer:-${SS_PORT:-22335}}
        prompt '加密方式' "${SS_METHOD:-aes-256-gcm}"; SS_METHOD=${answer:-${SS_METHOD:-aes-256-gcm}}
        prompt '监听地址（:: 双栈 / 0.0.0.0 IPv4）' "${SS_LISTEN:-::}"; SS_LISTEN=${answer:-${SS_LISTEN:-::}}
        if [ "${SS_PASSWORD-12345@}" = '12345@' ]; then
            warn '回车将使用公开默认密码 12345@，公网部署请自设密码。'
        fi
        printf '  密码 [回车使用默认值，输入隐藏]：' >&3
        stty -echo < /dev/tty
        tty_hidden=1
        IFS= read -r answer < /dev/tty || fail "未读取到密码"
        stty echo < /dev/tty
        tty_hidden=0
        printf '\n' >&3
        SS_PASSWORD=${answer:-${SS_PASSWORD-12345@}}
        prompt '公网域名或 IP（留空自动查询）' "${SS_HOST:-自动}"
        SS_HOST=${answer:-${SS_HOST:-}}
        printf '\n  端口 %s · %s · 监听 %s\n  开始安装？Y/n [Y]：' "$SS_PORT" "$SS_METHOD" "$SS_LISTEN" >&3
        read_answer
        case "$answer" in n|N) printf '  已取消，未修改安装。\n' >&3; exit 0;; esac
    fi
}
usage() {
    cat <<'EOF'
用法：sh install.sh [install|show|start|stop|restart|status|uninstall]
首次安装在终端中默认询问配置。--non-interactive 跳过询问，--interactive 强制交互。
SS_PORT / SS_PASSWORD / SS_METHOD 仅用于首次安装；其他选项见说明：
  SS_PORT=22335
  SS_PASSWORD=12345@
  SS_METHOD=aes-256-gcm（或 chacha20-ietf-poly1305 / aes-128-gcm）
  SS_HOST=公网IP或域名（生成连接链接时使用）
  SS_LISTEN=::（首次默认双栈；已有安装仅在显式设置时修改监听）
  SS_REFRESH=1（重新安装依赖和程序；平时复用已安装版本）
  SS_START=0（仅安装和启用服务，暂不启动；默认 1）
EOF
}
valid_host() {
    case "$1" in *[!a-zA-Z0-9.:_-]*) return 1;; esac
}

show() {
    [ -f "$CONFIG" ] || fail "尚未安装"
    line
    printf '  连接信息\n\n  监听地址   %s\n  端口       %s · TCP / UDP\n  加密方式   %s\n  配置文件   %s\n' \
        "$(jq -r .server "$CONFIG")" "$(jq -r .server_port "$CONFIG")" "$(jq -r .method "$CONFIG")" "$CONFIG" >&3
    host=${SS_HOST:-}
    if [ -z "$host" ]; then
        printf '%s\n' "正在查询公网 IP，以生成 SS 链接……" >&2
        host=$(curl -4 --fail --silent --show-error --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null) || host=
        if [ -z "$host" ]; then
            host=$(curl -6 --fail --silent --show-error --connect-timeout 3 --max-time 5 https://api6.ipify.org 2>/dev/null) || host=
        fi
    fi
    if [ -n "$host" ] && valid_host "$host"; then
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
case "$action" in
    --interactive) interactive=1; action=install;;
    --non-interactive) action=install;;
    install)
        if [ ! -f "$CONFIG" ] && [ -t 0 ] && [ -t 1 ]; then interactive=1; fi;;
esac
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

# Keep one installer or service mutation active at a time.
acquire_lock() {
    mkdir -p /run/lock
    if mkdir /run/lock/ss-alpine.install 2>/dev/null; then
        lock_dir=/run/lock/ss-alpine.install
    else
        fail "已有安装或服务操作持有 /run/lock/ss-alpine.install；确认没有脚本运行后才能移除该目录"
    fi
}

service_enabled() {
    if [ "$platform" = alpine ]; then
        rc-update show default | awk -v service="$SERVICE" '$1 == service { found = 1 } END { exit !found }'
    else
        systemctl is-enabled --quiet "$SERVICE.service"
    fi
}

set_service_enabled() {
    if [ "$platform" = alpine ]; then
        rc-update "$2" "$SERVICE" default
    else
        systemctl "$1" "$SERVICE.service"
    fi
}

restore_file() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        restore_temp=$(mktemp "${2}.restore.XXXXXX") || return 1
        cp -pP "$1" "$restore_temp" || return 1
        mv -f "$restore_temp" "$2" || return 1
        restore_temp=''
    else
        rm -f "$2"
    fi
}

rollback() {
    rollback_failed=0
    if [ "$service_touched" = 1 ]; then
        if ! service_action stop; then
            if service_action status >/dev/null 2>&1; then rollback_failed=1; fi
        fi
    fi
    if [ "$enable_changed" = 1 ] && [ "$was_enabled" = 0 ]; then
        if service_enabled; then set_service_enabled disable del || rollback_failed=1; fi
    fi
    if [ "$config_changed" = 1 ]; then
        restore_file "$rollback_dir/config" "$CONFIG" || rollback_failed=1
    fi
    if [ "$unit_changed" = 1 ]; then
        restore_file "$rollback_dir/unit" "$unit" || rollback_failed=1
        if [ "$platform" = debian ] && [ -d /run/systemd/system ]; then
            systemctl daemon-reload || rollback_failed=1
        fi
    fi
    if [ "$binary_changed" = 1 ]; then
        restore_file "$rollback_dir/binary" "$binary" || rollback_failed=1
    fi
    if [ "$service_touched" = 1 ] && [ "$was_running" = 1 ]; then
        if ! service_action start || ! wait_for_service; then rollback_failed=1; fi
    fi
    [ "$rollback_failed" = 0 ]
}

validate_config() {
    jq -e '
        (.server | type == "string" and length > 0)
        and (.server_port | type == "number" and . == floor and . >= 1024 and . <= 65535)
        and (.method | type == "string" and length > 0)
        and (.password | type == "string" and length > 0)
        and ((.mode // "tcp_only") | IN("tcp_only", "udp_only", "tcp_and_udp"))
        and ((.ipv6_only // false) | type == "boolean")
    ' "$1" >/dev/null || fail "配置文件无效，请检查监听地址、端口、加密方式、密码与模式"
}

# OpenRC's supervisor pidfile and child_pid refer to different processes.
service_pid() {
    if [ "$platform" = alpine ]; then
        cat "/run/openrc/options/$SERVICE/child_pid"
    else
        systemctl show --property=MainPID --value "$SERVICE.service"
    fi
}

as_service_user() {
    setpriv --reuid "$SERVICE" --regid "$SERVICE" --clear-groups -- "$@"
}

service_owns_listeners() (
    checked_pid=$1
    checked_port=$2
    checked_mode=$3
    socket_rows=$(as_service_user ss -H -O -lntup "sport = :$checked_port") || return 1
    printf '%s\n' "$socket_rows" | awk -v pid="$checked_pid" -v mode="$checked_mode" '
        index($0, "pid=" pid ",") {
            if ($1 == "tcp" && $2 == "LISTEN") tcp = 1
            if ($1 == "udp" && $2 == "UNCONN") udp = 1
        }
        END {
            exit !((mode == "udp_only" || tcp) && (mode == "tcp_only" || udp))
        }'
)

wait_for_service() (
    ready_port=$(jq -er '.server_port | select(type == "number" and . == floor and . >= 1 and . <= 65535)' "$CONFIG") || {
        printf '%s\n' '服务就绪检查失败：配置中的监听端口无效。' >&2
        return 1
    }
    ready_mode=$(jq -er '.mode // "tcp_only" | select(. == "tcp_only" or . == "udp_only" or . == "tcp_and_udp")' "$CONFIG") || {
        printf '%s\n' '服务就绪检查失败：配置中的传输模式无效。' >&2
        return 1
    }
    ready_binary=$(readlink -f "$binary") || return 1
    ready_uid=$(id -u "$SERVICE") || return 1
    attempt=0
    while [ "$attempt" -le 20 ]; do
        ready_pid=$(service_pid 2>/dev/null) || ready_pid=
        case "$ready_pid" in
            ''|0|*[!0-9]*) ;;
            *)
                if service_action status >/dev/null 2>&1 &&
                    [ "$(as_service_user readlink "/proc/$ready_pid/exe" 2>/dev/null)" = "$ready_binary" ] &&
                    awk -v uid="$ready_uid" '$1 == "Uid:" && $3 == uid { found = 1 } END { exit !found }' "/proc/$ready_pid/status" 2>/dev/null &&
                    tr '\000' '\n' 2>/dev/null < "/proc/$ready_pid/cmdline" | awk -v config="$CONFIG" '
                        (previous == "-c" || previous == "--config") && $0 == config { found = 1 }
                        $0 == "--config=" config { found = 1 }
                        { previous = $0 }
                        END { exit !found }
                    ' &&
                    service_owns_listeners "$ready_pid" "$ready_port" "$ready_mode" &&
                    [ "$(service_pid 2>/dev/null)" = "$ready_pid" ]; then
                    return 0
                fi
                ;;
        esac
        [ "$attempt" -lt 20 ] || break
        sleep 0.25
        attempt=$((attempt + 1))
    done
    printf '服务就绪检查超时：%s 未在端口 %s 完成 %s 监听。\n' "$SERVICE" "$ready_port" "$ready_mode" >&2
    service_action status >&2 || true
    ss -H -O -lntup "sport = :$ready_port" >&2 || true
    if [ "$platform" = debian ]; then
        journalctl --no-pager --unit "$SERVICE.service" --lines 15 >&2 || true
    fi
    return 1
)
case "$action" in
    show) show; exit;;
    status) service_action status; exit;;
    start|stop|restart) acquire_lock; service_action "$action"; exit;;
    uninstall)
        acquire_lock
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
acquire_lock
valid_host "${SS_HOST:-}" || fail "SS_HOST 格式不正确"
if [ ! -f "$CONFIG" ] && [ "${SS_PASSWORD-12345@}" = '12345@' ]; then
    warn '本次使用公开默认密码 12345@。'
fi
mkdir -p /var/log/ss-alpine
chmod 700 /var/log/ss-alpine
log=$(mktemp /var/log/ss-alpine/install.log.XXXXXX)
printf '  安装日志   %s\n\n' "$log" >&3
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
    password=${SS_PASSWORD-12345@}
    [ -n "$password" ] || fail "密码不能为空"
fi
ok '系统与配置参数检查完成'
step 2 '安装程序和依赖（详细输出写入日志）'
package_changed=0
if [ "$platform" = alpine ]; then
    # Use the matching stable release's community repository.
    release=$(cut -d. -f1,2 /etc/alpine-release)
    case "$release" in 3.[0-9]*) ;; *) fail "需要 Alpine 稳定版";; esac
    repo="https://dl-cdn.alpinelinux.org/alpine/v$release/community"
    if [ "${SS_REFRESH:-0}" = 1 ]; then
        package_changed=1
        apk add --no-cache --repository "$repo" --upgrade shadowsocks-rust-ssserver jq curl ca-certificates iproute2-ss setpriv
    elif ! apk info -e shadowsocks-rust-ssserver jq curl ca-certificates iproute2-ss setpriv >/dev/null; then
        apk add --no-cache --repository "$repo" shadowsocks-rust-ssserver jq curl ca-certificates iproute2-ss setpriv
    fi
    [ -x "$binary" ] || fail "未找到 ssserver"
else
    version=v1.25.0
    # Archive digests from the upstream GitHub release assets page.
    # https://github.com/shadowsocks/shadowsocks-rust/releases/expanded_assets/v1.25.0
    case "$(dpkg --print-architecture)" in
        amd64)
            target=x86_64-unknown-linux-musl
            checksum=8439bf43c324b0fc273e663d0b1f8926fd8f666cbd1e0fd59b35096f0e778e92;;
        arm64)
            target=aarch64-unknown-linux-musl
            checksum=2c24915b56a05effdab5898848bacfbcb625bc277b18febafc7a3aa45f87f3b0;;
        *) fail "Debian 当前支持 amd64 和 arm64";;
    esac

    missing_dependencies=0
    for package in ca-certificates curl jq xz-utils systemd adduser iproute2 util-linux; do
        if [ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" != installed ]; then
            missing_dependencies=1
            break
        fi
    done
    if [ "$missing_dependencies" = 1 ] || [ "${SS_REFRESH:-0}" = 1 ]; then
        apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
            install -y --no-install-recommends ca-certificates curl jq xz-utils systemd adduser iproute2 util-linux
    fi

    installed_version=''
    if [ -x "$binary" ]; then
        installed_version=$("$binary" --version 2>/dev/null) || installed_version=''
    fi
    if [ "$installed_version" != "shadowsocks ${version#v}" ] || [ "${SS_REFRESH:-0}" = 1 ]; then
        asset="shadowsocks-$version.$target.tar.xz"
        if [ -z "$work" ]; then work=$(mktemp -d); fi
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 90 --retry 3 --retry-max-time 120 \
            "https://github.com/shadowsocks/shadowsocks-rust/releases/download/$version/$asset" \
            -o "$work/archive.tar.xz"
        printf '%s  %s\n' "$checksum" "$work/archive.tar.xz" | sha256sum -c -
        tar --no-same-owner --no-same-permissions -xJf "$work/archive.tar.xz" -C "$work" ssserver
        [ "$("$work/ssserver" --version)" = "shadowsocks ${version#v}" ] || fail "下载的 ssserver 版本不符"
        binary_pending=1
    fi
fi
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
candidate=$CONFIG
if [ ! -f "$CONFIG" ] || [ -n "${SS_LISTEN:-}" ]; then
    temp=$(mktemp "$DIR/.config.XXXXXX")
    candidate=$temp
    if [ ! -f "$CONFIG" ]; then
        jq -n --arg password "$password" --arg method "$method" --argjson port "$port" --arg listen "${SS_LISTEN:-::}" \
            '{server:$listen,server_port:$port,password:$password,method:$method,mode:"tcp_and_udp",timeout:300,ipv6_only:false}' > "$temp"
    else
        jq --arg listen "$SS_LISTEN" '
            .server = $listen | if $listen == "::" then .ipv6_only = false else . end
        ' "$CONFIG" > "$temp"
    fi
    chown root:ss-alpine "$temp"
    chmod 640 "$temp"
fi
validate_config "$candidate"
ok '配置检查完成'
step 4 '设置服务与开机启动'
if [ "$platform" = alpine ]; then
unit="/etc/init.d/$SERVICE"
unit_temp=$(mktemp "${unit}.XXXXXX")
cat > "$unit_temp" <<'EOF'
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
    use net
    after firewall
}
EOF
chmod 755 "$unit_temp"
else
mkdir -p /etc/systemd/system
unit="/etc/systemd/system/$SERVICE.service"
unit_temp=$(mktemp "${unit}.XXXXXX")
cat > "$unit_temp" <<'EOF'
[Unit]
Description=Shadowsocks Rust server
Wants=network-online.target
After=network-online.target

[Service]
Type=exec
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
chmod 644 "$unit_temp"
fi

if [ "${SS_START:-1}" != 0 ] && service_action status >/dev/null 2>&1; then was_running=1; fi
if service_enabled; then was_enabled=1; fi

rollback_dir=$(mktemp -d "$DIR/.rollback.XXXXXX")
if [ "$binary_pending" = 1 ]; then
    if [ -e "$binary" ] || [ -L "$binary" ]; then cp -pP "$binary" "$rollback_dir/binary"; fi
    binary_temp=$(mktemp "${binary}.XXXXXX")
    install -m 755 "$work/ssserver" "$binary_temp"
fi
if [ -f "$CONFIG" ]; then cp -pP "$CONFIG" "$rollback_dir/config"; fi
if [ -e "$unit" ] || [ -L "$unit" ]; then cp -pP "$unit" "$rollback_dir/unit"; fi

transaction=1
if [ "$binary_pending" = 1 ] && ! cmp -s "$binary_temp" "$binary"; then
    binary_changed=1
    mv -f "$binary_temp" "$binary"
fi
if [ "$candidate" != "$CONFIG" ] && ! cmp -s "$candidate" "$CONFIG"; then
    config_changed=1
    mv -f "$temp" "$CONFIG"
fi
if ! cmp -s "$unit_temp" "$unit"; then
    unit_changed=1
    mv -f "$unit_temp" "$unit"
fi
if [ "$platform" = debian ] && [ "$unit_changed" = 1 ] && [ -d /run/systemd/system ]; then
    systemctl daemon-reload
fi
if [ "$was_enabled" = 0 ]; then
    enable_changed=1
    set_service_enabled enable add
fi
ok '开机启动已启用'
step 5 '检查服务状态'
restart_needed=0
if [ "$config_changed$unit_changed$binary_changed$package_changed" != 0000 ] || [ -f "$RESTART_PENDING" ]; then
    restart_needed=1
fi
if [ "${SS_START:-1}" != 0 ]; then
    if [ "$was_running" = 0 ]; then
        service_touched=1
        service_action start
    elif [ "$restart_needed" = 1 ]; then
        service_touched=1
        service_action restart
    fi
    wait_for_service || fail "服务未就绪，请检查监听地址、端口占用和服务日志"
    ok '服务正在运行'
else
    ok '仅准备模式：已跳过服务启动'
fi
if [ "$config_changed" = 1 ] && [ -f "$rollback_dir/config" ]; then
    config_backup=$(mktemp "$CONFIG.bak.XXXXXX")
    cp -pL "$rollback_dir/config" "$config_backup" || warn "未能保存额外配置备份：$config_backup"
fi
if [ "${SS_START:-1}" != 0 ]; then
    rm -f "$RESTART_PENDING"
elif [ "$restart_needed" = 1 ]; then
    : > "$RESTART_PENDING"
fi
transaction=0
}
install_main >> "$log" 2>&1
rmdir "$lock_dir"
lock_dir=''
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
