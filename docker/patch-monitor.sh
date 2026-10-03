#!/bin/sh
# 给官方 monitor 脚本打补丁。前两条与 PKGBUILD::prepare() 完全一致, 后两条是
# 官方脚本本身的缺陷(与发行版无关)。
#   1) web 进程端口 5588 -> 5589, 把 5588 让给 sslh 门前过滤 (TROUBLESHOOTING #1)
#   2) 启用官方脚本里被注释掉的 TERM trap (MIGRATION.md §6): 停服时清锁并留日志
#   3) [ ${run_env} == "test" ] -> [ "$run_env" = "test" ]: 官方按 Arch(/bin/sh 是
#      bash)写, 用了 test 的 bash 扩展 ==; Debian 的 /bin/sh 是 dash, 会往 stderr
#      喷 "unexpected operator" 并永远走 else 分支。改后两种 sh 行为一致。
#   4) 空行判据 [ -z "$process_name" ] 漏掉"只有空白"的行: PROCESS_DATA 是多行
#      字符串, 末尾必有一行空白, 于是每 5 秒往日志写一条
#      "Process not running: , starting..." / "Failed to start: "(进程名为空),
#      把真正的故障信息淹没。改成按"是否含非空白字符"判断。
set -eu

MON=${1:?usage: patch-monitor.sh <path/to/steamdeck_acc_monitor.sh>}

sed -i 's/-p 5588/-p 5589/g' "$MON"
grep -q -- '-p 5589' "$MON" || { echo 'error: 补丁失败 (-p 5589)' >&2; exit 1; }

sed -i "s|^#trap \"rm -f.*INT TERM EXIT|trap 'rm -f \"\$LOCK_FILE\"; log_message \"[Monitor] Daemon stopped\"; exit 0' INT TERM|" "$MON"
grep -q "^trap .*Daemon stopped" "$MON" || { echo 'error: 补丁失败 (TERM trap)' >&2; exit 1; }

sed -i 's/\[ ${run_env} == "test" \]/[ "$run_env" = "test" ]/' "$MON"
grep -q 'run_env" = "test"' "$MON" || { echo 'error: 补丁失败 (POSIX test)' >&2; exit 1; }

sed -i 's|\[ -z "\$process_name" \] && continue|case "$process_name" in *[![:space:]]*) ;; *) continue ;; esac|' "$MON"
grep -q 'case "\$process_name" in \*\[!\[:space:\]\]\*)' "$MON" || { echo 'error: 补丁失败 (空白行跳过)' >&2; exit 1; }

echo "==> steamdeck_acc_monitor.sh 补丁完成(端口 5589 / TERM trap / POSIX test / 空白行跳过)"
