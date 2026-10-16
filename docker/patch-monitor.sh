#!/bin/sh
# 给官方 monitor 脚本打补丁。上游会就地更新这个文件(同一版本号下内容也会变), 因此
# 每条补丁都按"结果"判定: 上游若已自行修好(如新版已原生启用 TERM trap、已先 xargs
# 去空格再做空行判据), 就跳过本步; 只有锚点彻底消失才报错 —— 避免上游的小改动
# 让镜像/包构建失败。
#   1) web 进程端口 5588 -> 5589, 把 5588 让给 sslh 门前过滤 (TROUBLESHOOTING #1)
#   2) TERM trap: 官方旧版把它注释掉了, 而 PrivatePIDs 下 monitor 是 ns pid 1, 收不到
#      SIGTERM 就只能超时强杀(MIGRATION.md §6); 新版已原生启用 -> 跳过本步。
#   3) [ ${run_env} == "test" ] -> [ "$run_env" = "test" ]: 官方按 Arch(/bin/sh 是
#      bash)写, 用了 test 的 bash 扩展 ==; Debian 的 /bin/sh 是 dash, 会往 stderr
#      喷 "unexpected operator" 并永远走 else 分支。改后两种 sh 行为一致。
#   4) 空行判据 [ -z "$process_name" ]: 旧版会漏掉"只有空白"的行, 于是每 5 秒写一条
#      进程名为空的日志; 新版先 xargs 去空格后已正确 -> 只在旧版写法上做等价改写。
set -eu

MON=${1:?usage: patch-monitor.sh <path/to/steamdeck_acc_monitor.sh>}

# 没有哈希兜底(见 Dockerfile 头部), 先确认拿到的是官方 monitor 而不是错误页
[ -s "$MON" ] || { echo "error: $MON 不存在或为空" >&2; exit 1; }
grep -q 'PROCESS_DATA' "$MON" || {
    echo "error: $MON 不像官方 monitor 脚本(上游格式变了?)" >&2
    exit 1
}

# 1) 端口: 必须落到 5589(5588 留给 sslh), 上游若改了这里就直接失败
sed -i 's/-p 5588/-p 5589/g' "$MON"
grep -q -- '-p 5589' "$MON" || { echo 'error: 补丁失败 (-p 5589)' >&2; exit 1; }

# 2) TERM trap: 已启用(形如 trap ... rm -f ...)则跳过; 仍是注释行才补
if grep -qE '^trap .*rm -f' "$MON"; then
    :
else
    sed -i "s|^#trap \"rm -f.*INT TERM EXIT|trap 'rm -f \"\$LOCK_FILE\"; log_message \"[Monitor] Daemon stopped\"; exit 0' INT TERM|" "$MON"
    grep -qE '^trap .*rm -f' "$MON" || { echo 'error: 补丁失败 (TERM trap)' >&2; exit 1; }
fi

# 3) POSIX test: 不变量是脚本里不再有 [ ... == ... ] 的 bash 扩展写法
if grep -qF '[ ${run_env} == "test" ]' "$MON"; then
    sed -i 's/\[ ${run_env} == "test" \]/[ "$run_env" = "test" ]/' "$MON"
fi
if grep -qE '\[[^]]*==[^]]*\]' "$MON"; then
    echo 'error: 补丁失败 (POSIX test: 仍有 [ ... == ... ])' >&2
    exit 1
fi

# 4) 空行判据
if grep -qF '[ -z "$process_name" ] && continue' "$MON"; then
    sed -i 's|\[ -z "\$process_name" \] && continue|case "$process_name" in *[![:space:]]*) ;; *) continue ;; esac|' "$MON"
    grep -qF 'case "$process_name" in *[![:space:]]*) ;; *) continue ;; esac' "$MON" || {
        echo 'error: 补丁失败 (空白行跳过)' >&2
        exit 1
    }
fi

echo "==> steamdeck_acc_monitor.sh 补丁完成(端口 5589 / TERM trap / POSIX test / 空白行跳过)"
