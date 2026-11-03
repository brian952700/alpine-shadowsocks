#!/bin/sh
set -eu
if [ -f /etc/alpine-release ]; then
    apk add --no-cache openrc python3
    binary=/usr/bin/ssserver
else
    apt-get update
    apt-get install -y --no-install-recommends python3
    binary=/usr/local/bin/ssserver
fi
sh -n /src/install.sh
sh /src/install.sh --help
if sh /src/install.sh invalid; then exit 1; fi
if SS_PORT=invalid SS_START=0 sh /src/install.sh > /tmp/ui-error.out 2>&1; then exit 1; fi
grep -F '安装未完成' /tmp/ui-error.out
grep -F '详细日志' /tmp/ui-error.out
SS_HOST=example.com SS_START=0 sh /src/install.sh > /tmp/ui-success.out
cat /tmp/ui-success.out
grep -F '[1/5]' /tmp/ui-success.out
grep -F '[5/5]' /tmp/ui-success.out
grep -F '@example.com:22335#Shadowsocks' /tmp/ui-success.out
if grep -q "$(printf '\033')" /tmp/ui-success.out; then exit 1; fi
jq -e '.server == "::" and .ipv6_only == false and .server_port == 22335 and .password == "12345" and .method == "aes-256-gcm"' /etc/ss-alpine/config.json
# Reproduce an old install; migration must preserve its credentials and port.
jq '.server="0.0.0.0" | .server_port=22336 | .password="existing-password" | del(.ipv6_only)' /etc/ss-alpine/config.json > /tmp/old.json
cat /tmp/old.json > /etc/ss-alpine/config.json
SS_HOST=example.com SS_START=0 sh /src/install.sh
jq -e '.server == "::" and .ipv6_only == false and .server_port == 22336 and .password == "existing-password"' /etc/ss-alpine/config.json
if [ -f /etc/alpine-release ]; then
    test -x /etc/init.d/ss-alpine
else
    systemd-analyze verify /etc/systemd/system/ss-alpine.service
fi
"$binary" -c /etc/ss-alpine/config.json > /tmp/ss.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
python3 - <<'PY'
import socket, time
for host in ("127.0.0.1", "::1"):
    for attempt in range(30):
        try:
            with socket.create_connection((host, 22336), timeout=1):
                pass
            break
        except OSError:
            time.sleep(0.2)
    else:
        raise RuntimeError("Listener unavailable: " + host)
print("IPv4 and IPv6 TCP listeners passed")
PY
kill -0 "$pid"

link=$(SS_HOST=2001:db8::1 sh /src/install.sh show)
printf '%s\n' "$link" | grep -F '@[2001:db8::1]:22336#Shadowsocks'

# Real terminal: optional interaction must cancel cleanly and honor NO_COLOR.
NO_COLOR=1 python3 - <<'PY'
import os, pty, select, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("sh", ["sh", "/src/install.sh", "--interactive"])
data = b""
deadline = time.monotonic() + 10
sent = False
while time.monotonic() < deadline:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            part = os.read(fd, 4096)
        except OSError:
            break
        if not part:
            break
        data += part
        if not sent and "保留配置并升级".encode() in data:
            os.write(fd, b"n\n")
            sent = True
else:
    os.kill(pid, 9)
    raise RuntimeError("Interactive cancellation timed out")
_, status = os.waitpid(pid, 0)
assert os.waitstatus_to_exitcode(status) == 0, data
assert "已取消".encode() in data, data
assert b"\x1b[" not in data, data
print("Interactive cancellation and NO_COLOR passed")
PY
