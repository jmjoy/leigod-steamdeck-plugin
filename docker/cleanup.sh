#!/bin/bash
# 容器停止后留在宿主 netns 上的痕迹清理/自查(需要 root)。
# 默认只打印, 加 -y 才真删 dummy wlan0; 插件正常退出会自行清掉 tun_PC 与规则。
set -euo pipefail
YES=0
if [ "${1:-}" = "-y" ]; then YES=1; fi

echo "== 1. dummy wlan0(设备身份载体, 建在宿主 netns, docker stop 不会删) =="
if ip link show wlan0 >/dev/null 2>&1; then
    if ip -d link show wlan0 2>/dev/null | grep -qw dummy; then
        ip -4 addr show dev wlan0 | awk '/inet / {print "     " $2}'
        if [ "$YES" = 1 ]; then
            ip link del wlan0 && echo "   -> 已删除"
        else
            echo "   (删除请执行: sudo $0 -y)"
        fi
    else
        echo "   wlan0 是物理网卡, 跳过"
    fi
else
    echo "   (不存在)"
fi
echo
echo "== 2. mangle 表里的加速规则 =="
iptables -t mangle -S OUTPUT 2>/dev/null | grep -E 'MARK|--uid-owner root' || echo "   (未发现)"
echo
echo "== 3. 策略路由 =="
ip rule show 2>/dev/null | grep -E 'fwmark|lookup 99' || echo "   (未发现)"
echo "   table 99: $(ip route show table 99 2>/dev/null | tr '\n' ' ' || true)"
echo
echo "== 4. ipset 列表 =="
ipset list -n 2>/dev/null || echo "   (读取失败)"
echo
echo "以上 2-4 项建议人工确认后再删, 以免误伤宿主自己的规则/路由。"
