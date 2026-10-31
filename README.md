# Shadowsocks 一键安装（Alpine / Debian 12+）

支持 Alpine Linux 稳定版（OpenRC），以及 Debian 12 及以上正式版本（systemd）。Debian 支持 amd64、arm64，使用官方 shadowsocks-rust v1.25.0 的 musl 二进制，并核对 GitHub 发布资产的 SHA256；Alpine 使用匹配系统版本的官方 community 软件包。

## 一键安装

以 root 执行：

```sh
wget -O /tmp/ss-install.sh https://raw.githubusercontent.com/brian952700/alpine-shadowsocks/main/install.sh && sh /tmp/ss-install.sh
```

默认配置：

```json
{
  "server": "::",
  "server_port": 22335,
  "method": "aes-256-gcm",
  "password": "12345",
  "mode": "tcp_and_udp",
  "timeout": 300,
  "ipv6_only": false
}
```

`::` 配合 `ipv6_only:false` 同时接收 IPv6 和 IPv4，支持 TCP/UDP。主机必须启用 IPv6；脚本不会修改内核网络设置。默认密码按用户要求保留为公开的 `12345`。

## 自定义与连接链接

```sh
SS_PORT=22335 SS_METHOD=aes-256-gcm SS_PASSWORD=你的密码 SS_HOST=你的公网域名 sh /tmp/ss-install.sh
SS_HOST=2001:db8::1234 sh /tmp/ss-install.sh show
```

SS_HOST 填公网域名、IPv4 或不带方括号的 IPv6；仅用于生成连接链接，不影响监听地址。链接包含密码。

首次安装可设置 SS_PORT、SS_METHOD、SS_PASSWORD。安装时可通过 SS_LISTEN 设置监听地址，应用于新配置和已有配置：

```sh
SS_LISTEN=0.0.0.0 sh /tmp/ss-install.sh
```

以上适合未启用 IPv6 的主机，仅监听 IPv4。

## 升级已有安装

重新下载并运行脚本。保留原端口、密码、加密方式；旧配置的 `0.0.0.0` 自动改为 `::`，并设置 `ipv6_only:false`。自定义监听地址保留。修改前会在同目录生成 `config.json.bak.时间戳` 备份。

为兼容原安装，两种系统沿用服务名 `ss-alpine`、用户 `ss-alpine` 和配置路径 `/etc/ss-alpine/config.json`。

## 管理

```sh
sh /tmp/ss-install.sh status
sh /tmp/ss-install.sh restart
sh /tmp/ss-install.sh stop
sh /tmp/ss-install.sh start
jq -r .password /etc/ss-alpine/config.json
sh /tmp/ss-install.sh uninstall
```

卸载移除服务，保留配置及程序。Debian 使用 systemd，日志可用 `journalctl -u ss-alpine -e` 查看；Alpine 使用 OpenRC。手工改配置后运行 restart。

`SS_START=0 sh /tmp/ss-install.sh` 只安装并设置开机启动，暂不启动服务，适用于准备系统镜像；正常安装不要设置。

## 网络与验证

放行 IPv4 和 IPv6 防火墙及云安全组中所选端口的 TCP/UDP。NAT 主机还需配置对应的端口映射；脚本不会修改这些规则。IPv6 公网访问需要主机本身拥有可路由 IPv6 地址。

自动检查覆盖 ShellCheck、Alpine、Debian 12 和 Debian 13 中的安装、配置迁移、服务文件生成，以及实际进程的 IPv4/IPv6 TCP 监听。容器检查不验证真实主机的开机启动、外部防火墙或公网端到端代理连接。

参考：[shadowsocks-rust 官方文档](https://github.com/shadowsocks/shadowsocks-rust)。

