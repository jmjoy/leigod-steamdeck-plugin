#!/bin/sh
# 构建期: 下载官方三个远程文件 -> sha256 校验 -> 落位 /opt/leigod -> 打补丁
# 与 PKGBUILD 的 source / sha256sums / prepare() 一一对应; 参数由 build args 提供
# (Dockerfile 里的 ARG 在 RUN 中就是环境变量)。
set -eu

DEST=/opt/leigod
MIRROR=${LEIGOD_MIRROR:-http://119.3.40.126}
SKIP_VERIFY=${SKIP_VERIFY:-0}

mkdir -p "$DEST/config"
cd "$DEST"

# $1=文件名  $2=期望的 sha256
fetch() {
    _name=$1
    _want=$2
    printf '==> 下载 %s/%s\n' "$MIRROR" "$_name"
    curl -fsSL --retry 3 --retry-delay 2 -o "$_name.part" "$MIRROR/$_name"
    _got=$(sha256sum "$_name.part" | cut -d' ' -f1)
    if [ "$SKIP_VERIFY" = "1" ]; then
        printf '    SKIP_VERIFY=1: %s sha256=%s\n' "$_name" "$_got"
    elif [ "$_got" != "$_want" ]; then
        printf 'error: %s sha256 不匹配\n  want %s\n  got  %s\n' "$_name" "$_want" "$_got" >&2
        printf '       上游发版或换了镜像? 核对后改 --build-arg SHA_*(临时放行 SKIP_VERIFY=1)\n' >&2
        exit 1
    fi
    mv "$_name.part" "$_name"
}

fetch acc-gw.router.amd64      "${SHA_ACC:-}"
fetch ipdatacloud_country.xdb  "${SHA_XDB:-}"
fetch steamdeck_acc_monitor.sh "${SHA_MONITOR:-}"

# 与 PKGBUILD package() 的落位一致: xdb 进 config/, 升级监视器是同二进制的一份拷贝
mv -f ipdatacloud_country.xdb config/ipdatacloud_country.xdb
cp -f acc-gw.router.amd64 acc_upgrade_monitor
chmod 0755 acc-gw.router.amd64 acc_upgrade_monitor steamdeck_acc_monitor.sh

/usr/local/lib/leigod/patch-monitor.sh "$DEST/steamdeck_acc_monitor.sh"
printf '==> 官方文件就位, sha256 校验通过\n'
