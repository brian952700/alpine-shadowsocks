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
jq -e '.server == "::" and .ipv6_only == false and .server_port == 22335 and .password == "12345@" and .method == "aes-256-gcm"' /etc/ss-alpine/config.json
# Reinstall must preserve an older IPv4-only configuration byte for byte.
jq -c '.server="0.0.0.0" | .server_port=22336 | .password="existing-password" | del(.ipv6_only)' /etc/ss-alpine/config.json > /tmp/old.json
cat /tmp/old.json > /etc/ss-alpine/config.json
SS_HOST=example.com SS_START=0 sh /src/install.sh
cmp /tmp/old.json /etc/ss-alpine/config.json

# Explicit IPv6-only configuration also survives a reinstall. An explicit
# request for the dual-stack wildcard may change it, but not its credentials.
jq -c '.server="::" | .ipv6_only=true' /tmp/old.json > /tmp/ipv6-only.json
cat /tmp/ipv6-only.json > /etc/ss-alpine/config.json
SS_HOST=example.com SS_START=0 sh /src/install.sh
cmp /tmp/ipv6-only.json /etc/ss-alpine/config.json
SS_HOST=example.com SS_LISTEN=:: SS_START=0 sh /src/install.sh
jq -e '.server == "::" and .ipv6_only == false and .server_port == 22336 and .password == "existing-password"' /etc/ss-alpine/config.json
for backup in /etc/ss-alpine/config.json.bak.*; do
    if cmp -s /tmp/ipv6-only.json "$backup"; then break; fi
done
cmp /tmp/ipv6-only.json "$backup"
if [ -f /etc/alpine-release ]; then
    test -x /etc/init.d/ss-alpine
else
    systemd-analyze verify /etc/systemd/system/ss-alpine.service
fi
"$binary" -c /etc/ss-alpine/config.json > /tmp/ss.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
python3 - "$pid" <<'PY'
import socket, subprocess, sys, time
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
for attempt in range(30):
    sockets = subprocess.check_output(["ss", "-H", "-lunp", "sport = :22336"], text=True)
    if f"pid={sys.argv[1]}," in sockets:
        break
    time.sleep(0.2)
else:
    raise RuntimeError("UDP listener not owned by ssserver")
print("IPv4 and IPv6 TCP listeners and UDP ownership passed")
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

# The Debian container has no running systemd. Exercise the installer's service
# path with a test supervisor while ssserver binds real sockets.
if [ ! -f /etc/alpine-release ]; then
    kill "$pid"
    wait "$pid" || true
    trap - EXIT
    python3 - "$binary" <<'PY'
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

config = Path("/etc/ss-alpine/config.json")
settings = json.loads(config.read_text())
settings["server"] = "127.0.0.2"
port = settings["server_port"]
config.write_text(json.dumps(settings, indent=2) + "\n")
previous = config.read_bytes()

with tempfile.TemporaryDirectory() as directory:
    state = Path(directory)
    systemctl = state / "systemctl"
    systemctl.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys
import time

state = Path(os.environ["SS_TEST_STATE"])
pidfile = state / "pid"
enabled = state / "enabled"
action = next(arg for arg in sys.argv[1:] if not arg.startswith("-"))

if action in ("restart", "stop") and pidfile.exists():
    pid = int(pidfile.read_text())
    pidfile.unlink()
    try:
        os.kill(pid, signal.SIGTERM)
        # The container's PID 1 may leave an exited child as a zombie.
        for _ in range(100):
            fields = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
            if fields[0] == "Z":
                break
            time.sleep(0.02)
        else:
            raise RuntimeError("test service did not stop")
    except (FileNotFoundError, ProcessLookupError):
        pass

if action in ("restart", "start"):
    account = pwd.getpwnam("ss-alpine")
    with (state / "ssserver.log").open("ab") as log:
        child = subprocess.Popen(
            [os.environ["SS_TEST_BINARY"], "-c", "/etc/ss-alpine/config.json"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
            user=account.pw_uid, group=account.pw_gid, extra_groups=[],
        )
    pidfile.write_text(str(child.pid))
elif action in ("is-active", "status"):
    # Model a manager that reports success before its child binds the port.
    sys.exit(0 if pidfile.exists() else 3)
elif action == "show":
    print(pidfile.read_text() if pidfile.exists() else "0")
elif action == "enable":
    enabled.touch()
elif action == "disable":
    enabled.unlink(missing_ok=True)
elif action == "is-enabled":
    sys.exit(0 if enabled.exists() else 1)
elif action not in ("stop", "daemon-reload", "reset-failed"):
    sys.exit(f"Unsupported test systemctl action: {action}")
''')
    systemctl.chmod(0o755)
    env = dict(os.environ, PATH=f"{state}:{os.environ['PATH']}",
               SS_TEST_STATE=str(state), SS_TEST_BINARY=sys.argv[1],
               SS_HOST="example.com", SS_START="1")
    env.pop("SS_LISTEN", None)
    # Only the installer sees the marker via this disposable Docker filesystem.
    Path("/run/systemd/system").mkdir(parents=True, exist_ok=True)
    (state / "enabled").touch()

    def manager(action):
        subprocess.run([str(systemctl), action], env=env, check=True, timeout=5)

    def wait_for_original_listener():
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.2", port), timeout=0.2):
                    return
            except OSError:
                time.sleep(0.1)
        raise AssertionError((state / "ssserver.log").read_text())

    def install(environment):
        return subprocess.run(["sh", "/src/install.sh", "--non-interactive"],
                              env=environment, text=True, capture_output=True, timeout=60)

    try:
        manager("start")
        wait_for_original_listener()
        pidfile = state / "pid"
        before_pid = pidfile.read_text()
        same = install(env)
        assert same.returncode == 0, same.stdout + same.stderr
        assert pidfile.read_text() == before_pid, same.stdout

        with socket.socket() as tcp, socket.socket(type=socket.SOCK_DGRAM) as udp:
            tcp.bind(("127.0.0.1", port))
            tcp.listen()
            udp.bind(("127.0.0.1", port))
            conflict = install(dict(env, SS_LISTEN="127.0.0.1"))
            assert conflict.returncode != 0, conflict.stdout + conflict.stderr
            assert "安装完成，服务正在运行" not in conflict.stdout, conflict.stdout
            assert config.read_bytes() == previous, conflict.stdout + conflict.stderr
            assert (state / "enabled").exists(), conflict.stdout
            wait_for_original_listener()
    finally:
        manager("stop")

print("Unchanged install kept its process; occupied port caused a failed upgrade and rollback")
PY
fi

