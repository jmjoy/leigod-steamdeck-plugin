# 故障排查实录

实际踩到并修复的问题,按"特征日志 → 根因 → 修复"记录,便于对号入座。
这些问题的表象互相掩盖,**必须按顺序逐层排除**。systemd 沙箱迁移过程的
完整定位记录与排障方法论见
[systemd-migration-troubleshooting.md](systemd-migration-troubleshooting.md)。

## #1 web 进程 SIGABRT 崩溃循环,App 无法绑定/提示设备离线

- **特征**:`acc_daemon.log` 每 5 秒 `child process recv signal, sig:6` 刷屏;
  coredump 崩溃地址恒定(`0x7d7149`);curl 5588 返回 Empty reply。
- **根因**:官方 web 进程基于 WebSocket++ 0.8.2,任何未完成 WebSocket 升级
  握手的普通 HTTP 连接(curl、浏览器、系统代理、App 部分探测)都会抛
  `websocketpp::exception(invalid state)` → `std::terminate` → SIGABRT。
  详见 [Husky0c issue #5](https://github.com/Husky0c/leigod-plugin-linux/issues/5)。
- **修复**:sslh 门前过滤(5588 → 5589),裸 HTTP 永远到不了后端。
  注意排查期间**不要**用 curl/浏览器直接探 5588,shell 里的全局
  `http_proxy` 也会让 Clash 替你发出致命的裸 HTTP;建议 `no_proxy` 加上本机。

## #2 绑定成功但 App 不发任何加速命令

- **特征**:`web_api.log` 只有 `getRouterInfo/getDeviceList/getNetworkState`
  轮询,无任何 bind/start 命令。
- **根因**:App 自身状态僵死(具体机制未知,重启 App 即恢复)。
- **修复**:重启手机 App,必要时解绑重绑。

## #3 加速命令到达,工作进程 1 秒内自杀,无 tun

- **特征**:`acc_PC.log` 中 `SteamDeckAccCore::start:55 create tun rules failed.`
  → 工作进程主动上报 `stop_acc`;`tun_PC` 不存在;App 显示"加速中"是假象。
- **根因(二选一或叠加)**:
  1. **`ipset` 未安装**——tun 模式把 2 万余条 IP 白名单灌进 ipset,是硬依赖
     而非可选;
  2. **沙箱内 `open("/dev/net/tun")` 失败**——systemd 的 `PrivateDevices=yes`
     只提供固定节点集的私有 `/dev`(无 `/dev/net`);`DeviceAllow=` 仅放行
     cgroup,不创建节点。缺 `BindPaths=/dev/net/tun` 时节点根本不存在,
     `ENOENT` 即死(bwrap 时代对应 `--dev` 白名单问题)。
- **修复**:`ipset` 移入 depends;单元固定三件套
  `PrivateDevices=yes` + `DeviceAllow=/dev/net/tun rw` +
  `BindPaths=/dev/net/tun`;tun/dummy 模块由
  `/usr/lib/modules-load.d/leigod.conf` 开机预加载(沙箱内没有 `SYS_MODULE`,
  模块必须在宿主侧就绪)。

## #4 云端一直不在线(TURN wss 从不建立)

- **特征**:设备 UDP keepalive(64B/10s,`tcpdump` 可证)往返正常,但
  `Start turn tcp thread` 与 wss 连接(:5443)从不出现。
- **分析**:TurnAcc 的 wss 客户端启动疑似受"网络在线检测"(探测 1.1.1.1:443,
  大陆直连不可达,更多像国内外区域判断)影响;但在社区实测中,同一 LAN 下
  加速命令走 5588 直连,云端 TURN 不在线**不阻塞**本机使用加速(参考
  [issue #2](https://github.com/Husky0c/leigod-plugin-linux/issues/2))。
  若远程(非同 LAN)使用加速,可能受此影响,暂无解,留意官方二进制更新。

## #5 绑定后身份漂移,反复掉线

- **特征**:能绑定,过一会儿 App 提示"路由器加速功能已离线"。
- **根因**:设备身份 = dummy wlan0 的 MAC;若从真实无线网卡克隆 MAC 而该网卡
  开启了随机化,身份随连接漂移(参考
  [issue #1](https://github.com/Husky0c/leigod-plugin-linux/issues/1))。
- **修复**:本包 MAC 默认取 `machine-id` 派生的稳定值(不随网络变化);
  若手工指定,确保固定。

## #6 服务启动即 226/NAMESPACE,journal 报 `Failed to set up mount namespacing: /etc: Invalid argument`

- **特征**:`systemctl status leigod` 显示 ExecStartPre 以 `226/NAMESPACE`
  退出,反复重启;报错路径为 `TemporaryFileSystem=` 列表中的某个挂载点。
- **根因**:systemd 261 实测回归——**单条 `TemporaryFileSystem=` 属性写多个
  冒号分隔路径时,挂载 tmpfs 触发内核 EINVAL**(两路径即可复现,与路径内容
  无关;`/etc` 单独一行正常,`/etc:/var` 即失败;`ProtectHome=tmpfs` 不受影响)。
- **修复**:单元中每个路径单独一条 `TemporaryFileSystem=`(systemd 对重复
  属性是追加语义,效果等价)。新版本 systemd 修复后可合并回一行,但多行写法
  在新旧版本均有效,建议保持。

## #7 升级/重启后服务无限重启循环,journal 零报错

- **特征**:`systemctl status` 显示 ExecStart 反复 `status=1/FAILURE`,
  journal 无任何应用层输出(官方 monitor 把报错写自己的日志文件)。
- **根因**:官方 monitor 的单例锁 `/var/run/acc_daemon.lock` 落在持久存储
  跨重启残留,且沙箱内 monitor 是 pid 命名空间的 pid 1(锁内容恒为 "1"),
  新实例 `kill -0 1` 命中自身,"already running" 退出且锁永不清理。
- **修复**:锁文件随沙箱私有 tmpfs 存亡(单元不 bind 宿主 `/run`)。
  完整定位过程见
  [systemd-migration-troubleshooting.md](systemd-migration-troubleshooting.md) §5。

## #8 能绑定成功,但 App 识别不到 SteamDeck(设备对云端一直离线)

> 本节是 **Docker 版专有**的根因;AUR/systemd 版因 Arch 的 `base` 组自带
> `iputils` 而天然不触发,故历史上一直被记成 TROUBLESHOOTING #4 的"云端不在线,
> 但不影响本机使用"。容器版下它确实会让 App 找不到设备。

- **特征**:
  - 手机 App 能走完绑定(`newBindRouter` 成功拿到 token),之后一直"识别不到
    SteamDeck"/设备离线;但 LAN 侧一切正常 —— UDP 6066 发现应答
    `(model=SteamDeck, sn=…, ip=…, bound=true)`,`getRouterInfo` 的
    `token:"<md5(token)>"` 也正确(bound 判据没问题)。
  - `grep 'current network is offline' data/log/web_api.log` —— **每秒一条**刷屏;
    `getNetworkState` 恒为 `state:4`。
  - `tcpdump -ni any 'udp and port 5588'` 看不到设备发往
    `route-turn.xxghh.biz:5588` 的 64B/10s keepalive。
- **根因**:容器镜像里**没有 `ping`**(Debian slim 不含 iputils,而 Arch 的
  `iputils` 属于 `base` 组)。插件用 `ping -c 1 -W 1 223.5.5.5`(约 1 次/秒,地址
  来自云端 `NetOption` 的 resolver 配置)判定"网络是否在线";判定失败时
  `turn_udp_thread_func` 每秒打一条 `current network is offline` 并**跳过** TURN
  UDP 注册/keepalive,云端因此把设备记为离线。绑定能成功只是因为启动初期 ws/turn
  通道短暂可用过(`on_open_func` → 约 1 分钟后 `on_close_func` 再没重连)。
- **判据**:`docker compose exec leigod-steamdeck-plugin command -v ping`
  返回空即命中;`docker compose exec … ping -c 1 -W 1 223.5.5.5` 应通
  (该地址在大陆可达;不通是另一类网络问题)。
- **修复**:镜像装 `iputils-ping`(本仓库 Dockerfile 已加,顺带 `iputils-arping`);
  `docker compose build --pull && docker compose up -d`。宿主直装版请确认
  `iputils` 已装(本仓库 PKGBUILD `depends` 已显式声明)。
- **验证**:重启后 `current network is offline` 不再出现,且
  `tcpdump -ni any 'udp and port 5588'` 能看到 64B 出/入成对(每 10 秒一组)。
- **顺带**:同一次定位还修掉了官方 monitor 脚本的空行判据缺陷 ——
  `PROCESS_DATA` 末尾必有一行空白,而 `[ -z "$process_name" ]` 漏掉"只有空白"
  的行,于是 `steamdeck_acc_monitor.log` 每 5 秒写一条进程名为空的
  `Process not running: , starting...` / `Failed to start: `。补丁见
  `docker/patch-monitor.sh` 第 4 条。
