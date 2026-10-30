# Alpine Shadowsocks 一键安装

适用于使用 OpenRC 的 Alpine Linux 稳定版 VPS。采用官方 community 仓库的 **shadowsocks-rust**，由 apk 校验软件包签名；不混用 edge。具体版本和架构取决于当前 Alpine 仓库是否提供 `shadowsocks-rust-ssserver`。

## 一键安装

以 root 运行：

```sh
wget -O /tmp/ss-install.sh https://raw.githubusercontent.com/brian952700/alpine-shadowsocks/main/install.sh && sh /tmp/ss-install.sh
```

默认监听 **0.0.0.0:22335**、加密 **aes-256-gcm**、密码 **12345**，同时启用 TCP 和 UDP、OpenRC 开机启动与进程监管。

如需安装后直接输出客户端导入链接：

```sh
SS_HOST=你的公网IP sh /tmp/ss-install.sh
```

自定义首次配置：

```sh
SS_PORT=18443 SS_HOST=你的域名 SS_METHOD=aes-256-gcm sh /tmp/ss-install.sh
```

可通过环境变量 `SS_PASSWORD` 设置非空密码。默认密码 `12345` 按用户要求设置，已公开。链接内包含密码，请妥善保存。

## 管理

```sh
sh /tmp/ss-install.sh status
sh /tmp/ss-install.sh restart
sh /tmp/ss-install.sh stop
sh /tmp/ss-install.sh start
SS_HOST=你的公网IP sh /tmp/ss-install.sh show
jq -r .password /etc/ss-alpine/config.json
```

重复安装保留原有配置，环境变量不覆盖它。配置文件为 `/etc/ss-alpine/config.json`，修改后执行 `rc-service ss-alpine restart`。服务以专用非 root 用户运行，端口必须为1024–65535。

卸载服务（保留配置和软件包，方便恢复）：

```sh
sh /tmp/ss-install.sh uninstall
```

## 网络与排错

- 在云安全组及主机防火墙放行所选端口的 **TCP 和 UDP**。脚本不会修改防火墙。
- 默认监听 `0.0.0.0`（IPv4）；公网地址由 `SS_HOST` 指定，不调用外部 IP 查询服务。IPv6 使用时需自行将配置的 server 改为 `::` 并确认网络连通。
- 若提示找不到软件包，请检查该版本、架构的 community 仓库是否提供软件包及网络是否可达；脚本不会绕过签名校验。
- 端口占用、配置错误时，用 `rc-service ss-alpine stop` 后执行 `ssserver -c /etc/ss-alpine/config.json` 查看前台错误，完成后 Ctrl+C 并重新启动服务。
- 需要已经运行的 OpenRC；普通 Docker 容器不适用。Alpine diskless 模式还需自行处理持久化（lbu）。
- 自动检查覆盖 shell 语法、ShellCheck、帮助入口和官方包安装；尚未在真实 VPS 上完成端到端代理连接验证。

参考：[Alpine 官方软件包](https://pkgs.alpinelinux.org/package/v3.22/community/x86_64/shadowsocks-rust-ssserver)、[shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)。

