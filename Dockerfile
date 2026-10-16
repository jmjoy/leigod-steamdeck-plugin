# 雷神加速器(Leigod) SteamDeck 插件 —— 容器版镜像
# (不使用 BuildKit 专有语法, 因此不写 # syntax= 指令 —— 免去拉取前端镜像)
# ============================================================================
# 与 AUR 包 leigod-steamdeck-plugin 同源: 直接复用本仓库的脚本与伪装文件
# (run.sh / ensure-wlan0.sh / sslh-guard.cfg / device.conf / accelerator.ini /
#  acc_version.ini / fake_*), 只把 leigod.service 里由 systemd 完成的加固翻译成
# Docker 原语。leigod.service 仍是单一真源, 对照关系如下:
#
#   PrivatePIDs=yes                           -> 容器自带私有 pid 命名空间(默认)
#   TemporaryFileSystem=/ + bind 白名单       -> 容器 rootfs 只有镜像内容, 看不到
#                                                宿主 /home /efi /windows (MIGRATION 8)
#   PrivateDevices=yes + DevicePolicy=closed  -> Docker 默认最小 /dev + /dev/net/tun
#   CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW -> cap_drop:[ALL] + cap_add 两项
#   NoNewPrivileges=true                      -> security_opt: no-new-privileges:true
#   网络与宿主共享(插件以 root 改宿主路由/iptables) -> network_mode: host
#   Restart=always / RestartSec=3             -> restart: unless-stopped
#   KillMode=control-group                    -> docker/entrypoint.sh 停止时广播 SIGTERM
#   ExecStartPre=ensure-wlan0.sh + mkdir /var/run -> docker/entrypoint.sh
#   UMask=0077 / WorkingDirectory / HOME      -> docker/entrypoint.sh + compose
#   BindReadOnlyPaths(fake_*, machine-id)     -> compose 的只读绑定
#   BindPaths(/opt/leigod 可写区 + log)       -> compose 的 ./data 目录
#
# 构建期从官方镜像下载三个远程文件, **默认不做哈希校验**, 只把实际 sha256 打进构建
# 日志(策略与理由见 DOCKER.md「构建参数与哈希策略」): 上游是明文 HTTP, 且文件在同一
# 版本号下就地更新(实测同一 1.2.2.15 下 acc-gw.router.amd64 与 steamdeck_acc_monitor.sh
# 都被替换过), 钉死的哈希只会在每次上游更新后让构建失败。传非空的 --build-arg SHA_*
# 可临时钉版本(不匹配即构建失败)。

FROM debian:trixie-slim

# 官方下载源(PKGBUILD 的 source 数组基址)
ARG LEIGOD_MIRROR=http://119.3.40.126
# 可选哈希钉: 留空(默认) = 不校验, 只打印实际 sha256; 非空 = 必须一致, 否则构建失败
ARG SHA_ACC=
ARG SHA_XDB=
ARG SHA_MONITOR=

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/deck \
    SBIN_DIR=/opt/leigod

# 运行时依赖(与 PKGBUILD 的 depends 对应):
#   bash/procps/coreutils —— run.sh 是 #!/bin/bash; monitor 用 pidof/xargs/wc; 二进制用 ps
#   iproute2/iptables/ipset —— tun 设备、策略路由、mangle 分流(ipset 是硬依赖, TROUBLESHOOTING 3)
#   sslh —— 5588 门前过滤。trixie 的 sslh 2.1.4 支持 regex 协议; bookworm 的 1.20 不支持
#   ca-certificates —— 静态链接的二进制读 /etc/ssl/certs 校验云端 HTTPS
#   iputils-ping —— 二进制用 ping 做"网络是否在线"判定(约 1 次/秒 ping 223.5.5.5),
#     判定失败会每秒刷 current network is offline 并且**不发云端 keepalive**
#     (route-turn:5588 的 64B/10s), 云端判定设备离线 -> App 绑定得到但识别不到 SteamDeck。
#     Arch 的 iputils 属于 base 组, AUR 版天然有; Debian slim 没有, 必须显式装
#     (TROUBLESHOOTING #8)。
#   iputils-arping —— 与 Arch iputils 包对齐(ARP 设备发现路径用)。
# curl 仅构建期下载用, 装完即卸, 不进运行镜像。
#
# 构建期 apt 的可调项(只影响构建, 不进运行镜像):
#   APT_FORCE_IPV4=1 —— 到 deb.debian.org 的 IPv6 若是黑洞, apt 会长时间卡在连接
#                       超时; 强制 IPv4 对正常环境无副作用, IPv6-only 环境设 0。
#   DEBIAN_MIRROR / DEBIAN_SECURITY_MIRROR —— 换国内镜像提速, 例:
#       DEBIAN_MIRROR=http://mirrors.aliyun.com/debian
#       DEBIAN_SECURITY_MIRROR=http://mirrors.aliyun.com/debian-security
ARG APT_FORCE_IPV4=1
ARG DEBIAN_MIRROR=
ARG DEBIAN_SECURITY_MIRROR=
RUN set -eux; \
    if [ "$APT_FORCE_IPV4" = "1" ]; then \
        printf 'Acquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99force-ipv4; \
    fi; \
    if [ -n "$DEBIAN_MIRROR" ]; then \
        sed -i "s|^URIs: http://deb.debian.org/debian[[:space:]]*$|URIs: $DEBIAN_MIRROR|" \
            /etc/apt/sources.list.d/debian.sources; \
    fi; \
    if [ -n "$DEBIAN_SECURITY_MIRROR" ]; then \
        sed -i "s|^URIs: http://deb.debian.org/debian-security[[:space:]]*$|URIs: $DEBIAN_SECURITY_MIRROR|" \
            /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash ca-certificates coreutils curl procps \
        iproute2 iptables ipset sslh \
        iputils-ping iputils-arping; \
    rm -rf /var/lib/apt/lists/*

# ---- 官方文件: 下载 -> sha256 校验 -> 落位 /opt/leigod -> 打 PKGBUILD prepare() 补丁 ----
COPY docker/fetch-upstream.sh docker/patch-monitor.sh /usr/local/lib/leigod/
RUN set -eux; \
    /usr/local/lib/leigod/fetch-upstream.sh; \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*

# ---- 目录骨架: 布局与 AUR 包一致(/opt/leigod 即沙箱内的 /home/deck/leigod) ----
# /tmp/acc/log 用符号链接指向 /opt/leigod/log: 官方 monitor 与 run.sh 的日志守护都写
# /tmp/acc/log, 与 unit 里 BindPaths=/opt/leigod/log:/tmp/acc/log 等价。
# Debian 的 sslh 装在 /usr/sbin, 而仓库版 run.sh 按 Arch 的 /usr/bin 调用 -> 补链接。
RUN set -eux; \
    mkdir -p /opt/leigod/log /home/deck /etc/leigod /usr/lib/leigod /opt/leigod-defaults/config; \
    ln -sfn /opt/leigod /home/deck/leigod; \
    mkdir -p /tmp/acc; \
    ln -sfn /opt/leigod/log /tmp/acc/log; \
    ln -sfn /usr/sbin/sslh /usr/bin/sslh; \
    cp -a /opt/leigod/config/ipdatacloud_country.xdb /opt/leigod-defaults/config/

# ---- 本仓库的脚本与配置: AUR 版与容器版共用同一份文件 ----
COPY run.sh ensure-wlan0.sh /usr/lib/leigod/
COPY docker/entrypoint.sh /usr/local/lib/leigod/entrypoint.sh
COPY sslh-guard.cfg device.conf /etc/leigod/
RUN set -eux; \
    chmod 0755 /usr/lib/leigod/run.sh /usr/lib/leigod/ensure-wlan0.sh \
               /usr/local/lib/leigod/entrypoint.sh /usr/local/lib/leigod/fetch-upstream.sh \
               /usr/local/lib/leigod/patch-monitor.sh

# ---- SteamDeck 伪装(等价于 unit 的 BindReadOnlyPaths) ----
# /etc/os-release 与 /usr/lib/os-release 都烤成 SteamOS; compose 另把仓库里的
# fake_os_release 只读挂回 /etc/os-release, 改文件即生效, 不必重建镜像。
# /etc/version 必须可写(官方升级程序会回写), 因此不做挂载。
COPY fake_os_release /etc/os-release
COPY fake_os_release /usr/lib/os-release
COPY fake_version /etc/version

# ---- config/ 默认副本: 该目录通常挂在宿主 ./data/config, 首次为空时由 entrypoint 播种 ----
# accelerator.ini 是绑定 token 的落盘位置(README「绑定是持久的」), 必须跨容器重建保留。
COPY accelerator.ini acc_version.ini /opt/leigod-defaults/config/
RUN chmod 0644 /opt/leigod-defaults/config/*

WORKDIR /home/deck/leigod

# 5588 sslh 门前过滤(仅 WebSocket 升级) / 5589 插件 web 进程
# 10001 实时调试台 / 6066/udp LAN 发现(host 网络下 EXPOSE 仅作文档)
EXPOSE 5588 5589 10001 6066/udp

ENTRYPOINT ["/usr/local/lib/leigod/entrypoint.sh"]
CMD ["run"]
