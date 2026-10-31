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
SS_START=0 sh /src/install.sh
jq -e '.server == "::" and .ipv6_only == false and .server_port == 22335 and .password == "12345" and .method == "aes-256-gcm"' /etc/ss-alpine/config.json
# Reproduce an old install; migration must preserve its credentials and port.
jq '.server="0.0.0.0" | .server_port=22336 | .password="existing-password" | del(.ipv6_only)' /etc/ss-alpine/config.json > /tmp/old.json
cat /tmp/old.json > /etc/ss-alpine/config.json
SS_START=0 sh /src/install.sh
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

