#!/bin/bash
# 容器入口 —— leigod.service 里由 systemd 完成、Docker 不会自动做的部分
# ---------------------------------------------------------------------------
#   1) ExecStartPre: ensure-wlan0.sh(建 dummy wlan0 承载设备身份/SN) + 清单例锁
#   2) UMask=0077: 绑定 token 只有 root 能读
#   3) KillMode=control-group: docker stop 只把 SIGTERM 发给 pid 1, 这里广播给容器
#      内所有进程 —— 否则加速程序收不到信号, 它建在宿主 netns 里的 tun_PC 与
#      iptables/ipset 规则就清理不掉。
# 其余(sslh 门前过滤、日志大小守护、官方 monitor)全部交给仓库原版 run.sh。
#
# 用法: entrypoint.sh [run|doctor|shell]
set -euo pipefail
umask 0077

PLUGIN_DIR=/home/deck/leigod
DEFAULTS_DIR=/opt/leigod-defaults/config
STOP_GRACE=${LEIGOD_STOP_GRACE:-8}

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] error: %s\n' "$*" >&2; exit 1; }

# config/ 通常挂在宿主目录(./data/config), 首次为空: 从镜像内默认副本播种。
# accelerator.ini 是绑定 token 的落盘位置, 必须跨容器重建保留, 所以不裸用匿名卷。
seed_config() {
    mkdir -p "$PLUGIN_DIR/config"
    local f n
    for f in "$DEFAULTS_DIR"/*; do
        [ -e "$f" ] || continue
        n=${f##*/}
        if [ ! -e "$PLUGIN_DIR/config/$n" ]; then
            cp -a "$f" "$PLUGIN_DIR/config/$n"
            log "初始化 config/$n"
        fi
    done
}

# 三处伪装缺一不可(与 unit 的 BindReadOnlyPaths 对应)
check_identity() {
    local dmi osname ver
    dmi=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    osname=$(head -n1 /etc/os-release 2>/dev/null || true)
    ver=$(cat /etc/version 2>/dev/null || true)
    log "伪装视图: os-release=${osname:-?} | /etc/version=${ver:-?} | DMI=${dmi:-读取失败}"
    if [ "$dmi" != "Jupiter" ]; then
        log "警告: DMI 不是 Jupiter(实际 ${dmi:-空} ) —— compose 里 fake_product_name 的只读挂载没生效?"
    fi
    if [ ! -s /etc/machine-id ]; then
        log "警告: /etc/machine-id 为空 —— 设备身份(SN)会退化, 请保留 compose 里 /etc/machine-id 的挂载"
    fi
}

# 前提检查, 对应 TROUBLESHOOTING #3: ipset 与 /dev/net/tun 缺一不可
preflight() {
    [ -c /dev/net/tun ] || die "/dev/net/tun 不存在: compose 需要 devices: /dev/net/tun:/dev/net/tun"
    command -v sslh >/dev/null 2>&1 || die "sslh 缺失"
    command -v ipset >/dev/null 2>&1 || die "ipset 缺失(tun 模式硬依赖)"
    command -v ip >/dev/null 2>&1 || die "iproute2 缺失"
    # 插件用 ping 判定"网络在线"(约 1 次/秒 ping 223.5.5.5)。缺了会每秒刷
    # current network is offline, 并且不发云端 keepalive(route-turn:5588 的
    # 64B/10s) -> 云端判定设备离线, App 能绑定却识别不到 SteamDeck(见
    # TROUBLESHOOTING #8)。
    command -v ping >/dev/null 2>&1 || die "ping 缺失(需要 iputils-ping): 插件靠它判定网络在线"
    if ip link add name leigod-probe0 type dummy >/dev/null 2>&1; then
        ip link del leigod-probe0 2>/dev/null || true
    else
        log "警告: 建不了 dummy 接口 —— 宿主 dummy 模块没就绪或缺少 NET_ADMIN"
    fi
    # 5588 是 App 会连的那个端口: 同机若已有 leigod(systemd 版 / 另一个容器)在跑,
    # run.sh 会因为 sslh 起不来而退出并进入重启循环。这里先给出可执行的排查线索。
    if ss -lnt 2>/dev/null | grep -q ':5588 '; then
        log "警告: 5588 已被占用(ss -lntp 查属主; 常见是宿主 systemd 版 leigod 服务或另一个容器);"
        log "      run.sh 会因 sslh 起不来而退出, 请先停掉冲突实例再启动本容器"
    fi
}

# dummy wlan0 建在宿主 netns 里, 容器停止不会消失。它上面的 /32 设备 IP 会随宿主
# 换网络累积, 插件可能把最旧的失效 IP 报给 App -> 「Steam Deck 识别失败」。
# 容器生命周期里每次启动重建一次最省事; 想沿用 AUR 的"幂等不动"就设
# LEIGOD_RESET_WLAN0=0。物理 wlan0 永不触碰(见 device.conf 的边界说明)。
reset_dummy_wlan0() {
    ip link show wlan0 >/dev/null 2>&1 || return 0
    if ip -d link show wlan0 2>/dev/null | grep -qw dummy; then
        log "重建上次遗留的 dummy wlan0(清掉历史设备 IP, 避免插件上报失效地址)"
        ip link del wlan0 || log "警告: 删除 dummy wlan0 失败, 继续"
    else
        log "wlan0 是物理网卡: 按 device.conf 的边界说明, 不做任何改动"
    fi
}

stopping=0
# KillMode=control-group 的等价物: 广播 SIGTERM, 宽限后 SIGKILL。
# 只 kill 0(进程组)不够 —— 守护进程会 fork 出 -r web / -r acc 子进程, 可能换会话,
# 所以再按 /proc 扫一遍(容器里只看得见本 pid 命名空间的进程)。
shutdown() {
    [ "$stopping" = 1 ] && return 0
    stopping=1
    trap '' TERM INT                      # 防重入: 下面的广播会打到自己
    log "收到停止信号 -> 向容器内所有进程广播 SIGTERM(让加速程序清理 tun_PC/iptables)"
    kill -TERM 0 2>/dev/null || true
    local p pid
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        [ "$pid" = "$$" ] && continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep "$STOP_GRACE"
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        [ "$pid" = "$$" ] && continue
        kill -KILL "$pid" 2>/dev/null || true
    done
    exit 0
}

# cap_drop=ALL 时 root 没有 DAC_OVERRIDE: 宿主 ./data 若属于普通用户就写不进去。
# Docker 在目录不存在时会以 root 创建, 正常流程踩不到; 但手工 mkdir 过 data/ 就会,
# 这里给出可执行的修复命令, 而不是让官方脚本回一句模糊的 Permission denied。
check_writable() {
    local d
    for d in "$PLUGIN_DIR/config" "$PLUGIN_DIR/log"; do
        if ! touch "$d/.leigod-write-test" 2>/dev/null; then
            die "$d 不可写。
        compose 的 ./data 必须是 root 所有(容器以 root + 无 DAC_OVERRIDE 运行, 与
        leigod.service 的能力收敛一致)。修复:
            sudo chown -R root:root data/
        或删掉 data/ 后由 docker compose up -d 以 root 自动创建。"
        fi
        rm -f "$d/.leigod-write-test"
    done
}

run() {
    check_writable
    seed_config
    check_identity
    preflight
    if [ "${LEIGOD_RESET_WLAN0:-1}" = "1" ]; then
        reset_dummy_wlan0
    fi

    # ExecStartPre=/usr/bin/mkdir -p /var/run (+ 单例锁):
    # monitor 的锁写的是 pid 命名空间里的 pid, 一旦落进持久层, 新实例 kill -0 会
    # 命中自身并无限重启(MIGRATION.md §5)。compose 已把 /run 设成 tmpfs, 这里再兜一层。
    mkdir -p /var/run
    rm -f /var/run/acc_daemon.lock

    /usr/lib/leigod/ensure-wlan0.sh \
        || die "ensure-wlan0.sh 失败(需要 NET_ADMIN; 宿主需先 modprobe dummy)"

    log "启动官方 monitor(release): sslh 门前过滤 + 日志守护由 run.sh 拉起"
    /usr/lib/leigod/run.sh "$PLUGIN_DIR/steamdeck_acc_monitor.sh" release &
    local mon=$!

    trap shutdown TERM INT
    local rc=0
    wait "$mon" || rc=$?
    if [ "$stopping" = 1 ]; then
        exit 0
    fi
    log "run.sh 退出(status=$rc), 容器结束, 按 restart 策略处理"
    exit "$rc"
}

doctor() {
    log "===== 一、身份伪装(闭源二进制的 SteamDeck 检测路径) ====="
    log "DMI product_name : $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 读取失败)"
    log "os-release 首行  : $(head -n1 /etc/os-release 2>/dev/null || echo 读取失败)"
    log "/etc/version     : $(cat /etc/version 2>/dev/null || echo 读取失败)"
    log "machine-id 前 12 : $(head -c 12 /etc/machine-id 2>/dev/null || echo 缺失)"
    log "===== 二、插件文件 ====="
    ls -l "$PLUGIN_DIR" 2>/dev/null | sed 's/^/    /' || true
    ls -l "$PLUGIN_DIR/config" 2>/dev/null | sed 's/^/    /' || true
    log "===== 三、内核与能力 ====="
    if [ -c /dev/net/tun ]; then log "/dev/net/tun : 存在"; else log "/dev/net/tun : 缺失"; fi
    if ip link add name leigod-probe0 type dummy 2>/dev/null; then
        ip link del leigod-probe0 2>/dev/null || true
        log "dummy 模块   : 可用"
    else
        log "dummy 模块   : 不可用(宿主需 modprobe dummy)"
    fi
    log "iptables     : $(iptables -V 2>&1 | head -n1)"
    log "ipset        : $(ipset -v 2>&1 | head -n1)"
    log "ping         : $(command -v ping || echo '缺失 -> 插件会一直网络离线, TROUBLESHOOTING #8')"
    log "CapEff       : $(awk '/^CapEff/ {print $2}' /proc/self/status 2>/dev/null || echo ?)"
    log "默认路由     : $(ip route show default 2>/dev/null | head -n1 || true)"
    log "wlan0        : $(ip -4 addr show dev wlan0 2>/dev/null | grep inet | tr -s ' ' || echo '尚未创建')"
    log "===== 四、端口布局 ====="
    ss -lntup 2>/dev/null | grep -E ':(5588|5589|10001|6066) ' | sed 's/^/    /' || log "    (无监听)"
    log "===== 五、注意 ====="
    log "裸 HTTP 探测 5588 会被 sslh 丢弃(安全); 直连 5589 会让 web 进程 SIGABRT, 不要做"
}

case "${1:-run}" in
    run)    run ;;
    doctor) doctor ;;
    shell)  exec /bin/bash ;;
    *)      exec "$@" ;;
esac
