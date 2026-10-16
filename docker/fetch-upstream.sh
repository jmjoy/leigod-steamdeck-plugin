#!/bin/sh
# 构建期: 下载官方三个远程文件 -> 落位 /opt/leigod -> 打补丁
# 与 PKGBUILD 的 source 数组一一对应; 参数由 Dockerfile 的 build args 传入
# (Dockerfile 里的 ARG 在 RUN 中就是环境变量)。
#
# 哈希策略(见 DOCKER.md「构建参数与哈希策略」; AUR 侧 PKGBUILD 仍是 pinned sha256):
#   默认不校验 —— 上游是明文 HTTP, 且文件在同一版本号下就地更新(实测同一 1.2.2.15
#   下 acc-gw.router.amd64 与 steamdeck_acc_monitor.sh 都被替换过), 钉死的哈希只会
#   让构建在每次上游更新后失败; 而运行期的 acc_upgrade_monitor 本来就会自行改写
#   这些文件。构建日志打印实际 sha256, 便于事后比对/钉版本。
#   传非空的 SHA_* 即对该文件硬校验(不匹配即构建失败)。
set -eu

DEST=/opt/leigod
MIRROR=${LEIGOD_MIRROR:-http://119.3.40.126}

mkdir -p "$DEST/config"
cd "$DEST"

# $1=文件名  $2=期望的 sha256(空 = 不校验)
fetch() {
    _name=$1
    _want=${2:-}
    printf '==> 下载 %s/%s\n' "$MIRROR" "$_name"
    curl -fsSL --retry 3 --retry-delay 2 -o "$_name.part" "$MIRROR/$_name"
    [ -s "$_name.part" ] || { printf 'error: %s 下载为空\n' "$_name" >&2; exit 1; }
    _got=$(sha256sum "$_name.part" | cut -d' ' -f1)
    if [ -z "$_want" ]; then
        printf '    %s sha256=%s (未校验)\n' "$_name" "$_got"
    elif [ "$_got" = "$_want" ]; then
        printf '    %s sha256=%s (已校验)\n' "$_name" "$_got"
    else
        printf 'error: %s sha256 与 SHA_* 不一致\n  want %s\n  got  %s\n' \
            "$_name" "$_want" "$_got" >&2
        exit 1
    fi
    mv "$_name.part" "$_name"
}

fetch acc-gw.router.amd64      "${SHA_ACC:-}"
fetch ipdatacloud_country.xdb  "${SHA_XDB:-}"
fetch steamdeck_acc_monitor.sh "${SHA_MONITOR:-}"

# 没有哈希兜底, 至少确认拿到的不是错误页/空壳: 主程序必须是 x86-64 ELF
_elf=$(head -c 4 acc-gw.router.amd64 | od -An -tx1 | tr -d ' \n')
[ "$_elf" = "7f454c46" ] || {
    printf 'error: acc-gw.router.amd64 不是 ELF(头 4 字节 hex=%s), 上游/镜像返回了别的内容\n' "$_elf" >&2
    exit 1
}

# 与 PKGBUILD package() 的落位一致: xdb 进 config/, 升级监视器是同二进制的一份拷贝
mv -f ipdatacloud_country.xdb config/ipdatacloud_country.xdb
cp -f acc-gw.router.amd64 acc_upgrade_monitor
chmod 0755 acc-gw.router.amd64 acc_upgrade_monitor steamdeck_acc_monitor.sh

/usr/local/lib/leigod/patch-monitor.sh "$DEST/steamdeck_acc_monitor.sh"
printf '==> 官方文件就位\n'
