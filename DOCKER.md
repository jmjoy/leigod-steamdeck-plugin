# 容器部署(Dockerfile + Compose)

AUR/systemd 之外的另一条部署路径: 把**本仓库同一套脚本**封进镜像, 用 Docker
Compose 跑。宿主零安装(不装 systemd 单元、不用包管理器), 手机绑定与使用流程与
[AUR 版](README.md)完全一致。

- [镜像内容](#镜像内容)
- [快速开始](#快速开始)
- [持久化与升级](#持久化与升级)
- [配置](#配置)
- [常用命令](#常用命令)
- [已知差异与限制](#已知差异与限制)
- [构建参数](#构建参数)
- [排障](#排障)

## 镜像内容

容器里**不重新实现任何东西**, 直接复用本仓库的文件:

| 仓库文件 | 镜像内落点 | 作用 |
|---|---|---|
| `run.sh` | `/usr/lib/leigod/run.sh` | sslh 门前过滤 + 日志大小守护 + exec 官方 monitor |
| `ensure-wlan0.sh` | `/usr/lib/leigod/ensure-wlan0.sh` | ExecStartPre: dummy wlan0 与设备 IP |
| `sslh-guard.cfg` `device.conf` | `/etc/leigod/` | 与 AUR 同路径; compose 从仓库只读挂回, 改文件即生效 |
| `accelerator.ini` `acc_version.ini` | `/opt/leigod/config` | 绑定 token 的落盘位置 |
| `fake_os_release` `fake_product_name` `fake_version` | `/etc/os-release` `/usr/lib/os-release` `/etc/version` | SteamDeck 身份伪装 |

上游闭源文件(`acc-gw.router.amd64` / `ipdatacloud_country.xdb` /
`steamdeck_acc_monitor.sh`)在构建期从 `LEIGOD_MIRROR` 下载, 用 PKGBUILD 里
pin 死的 sha256 逐个校验后落位 `/opt/leigod`, 并打上与 PKGBUILD `prepare()`
相同的补丁(web 端口 5588→5589、启用 TERM trap), 另加 Debian 特有补丁
(dash 不认 `test` 的 `==`)与一条空白行判据修正, 见 `docker/patch-monitor.sh`。

**运行期依赖**(镜像内 `apt-get install`): `bash` `coreutils` `procps`
`iproute2` `iptables` `ipset` `sslh` `ca-certificates`, 以及 **`iputils-ping`
/ `iputils-arping`** —— Arch 的 `base` 组自带 `iputils`, AUR 版因此天然具备;
Debian slim 没有, 缺 `ping` 会让插件永远判定"网络离线", 云端认为设备离线,
App 能绑定却识别不到 SteamDeck(TROUBLESHOOTING #8)。`curl` 只在构建期下载用,
装完即卸。

**加固对照**: `leigod.service` 里每条 systemd 加固在 compose 里都有对应项,
完整对照表在 [Dockerfile](Dockerfile) 头部。要点:

| systemd | Docker |
|---|---|
| `PrivatePIDs=yes` | 容器自带私有 pid 命名空间 |
| `TemporaryFileSystem=/ + bind 白名单` | 容器 rootfs 只有镜像内容, 看不到宿主 /home /efi /windows |
| `PrivateDevices + DeviceAllow=/dev/net/tun` | 默认最小 /dev + `devices: /dev/net/tun` |
| `CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW` | `cap_drop:[ALL]` + `cap_add:[NET_ADMIN,NET_RAW]` |
| `NoNewPrivileges=true` | `security_opt: no-new-privileges:true` |
| 网络共享(改宿主路由/iptables/ipset) | `network_mode: host` |
| `KillMode=control-group` | entrypoint 在停止时广播 SIGTERM |
| `UMask=0077` / `ExecStartPre` | entrypoint |
| `BindPaths=/opt/leigod` | compose 的 `./data/{config,log}` |

## 快速开始

宿主前置:

- Linux **x86_64** + Docker(含 compose v2+), 容器本身以 root 运行(插件需要)
- **5588 端口空闲**: 同机若已有 leigod 在跑 —— 宿主 systemd 服务(`leigod.service`
  或 `leigod_plugin.service`)、另一个容器 —— 会撞 5588, 容器将因为 sslh 起不来而
  退出重启。先查再停: `sudo ss -lntp | grep ':5588 '`
- 内核模块 `tun`、`dummy`、`ip_set`/`xt_set`: 容器内没有 `SYS_MODULE`, 模块必须
  宿主侧就绪。AUR 包靠 `modules-load.d` 开机加载, 这里手动:
  `sudo modprobe tun dummy ip_set`
- `/dev/net/tun` 存在(加载 tun 后出现)

```bash
cd leigod-steamdeck-plugin
docker compose up -d --build        # 首次构建会下载约 11MB 上游文件
docker compose logs -f              # 入口日志(伪装视图/身份检查)
```

然后按 README 的流程绑定(**手机须与电脑同一局域网**):
雷神加速器 App → 硬件加速 → 选择 **SteamDeck** → 一路点到底部完成绑定。

## 持久化与升级

| 宿主路径 | 容器内 | 内容 |
|---|---|---|
| `./data/config` | `/opt/leigod/config` | **绑定 token**(`accelerator.ini`)、版本、IP 地理库 |
| `./data/log` | `/opt/leigod/log`(=`/tmp/acc/log`) | 官方进程日志, run.sh 的守护在 50MiB 处清零 |

- **绑定是持久的**: token 落在 `./data/config/accelerator.ini`, 容器重建、
  镜像升级、`docker compose down/up` 都不会掉绑定(等价 AUR 升级钩子的
  保存/恢复, 但容器版根本不用恢复 —— 文件一直在宿主上)。
- **升级镜像** = `docker compose build --pull && docker compose up -d`。
- 官方 `acc_upgrade_monitor` 仍按原样运行(与 AUR 版一致), 但它写的是容器可写层:
  `docker compose down`(删容器)后会回到镜像内那版。要长期固定版本就把镜像版本
  当唯一真源, 用重新 build 来升级。
- 首次启动会把镜像里的默认 config 播种到 `./data/config`(只补缺失文件, 不覆盖)。

## 配置

同一批文件, 同一处改:

| 文件 | 作用 | 生效方式 |
|---|---|---|
| `./device.conf` | `DEVICE_IP=auto/指定IP/none` | `docker compose restart` |
| `./sslh-guard.cfg` | 5588 门前过滤规则(仅放行 WebSocket 升级) | `docker compose restart` |
| `./fake_os_release` `./fake_product_name` | 伪装内容 | `docker compose restart` |
| compose `environment:` | 见下 | `docker compose up -d` |

容器特有环境变量(compose 里默认注释掉):

| 变量 | 默认 | 说明 |
|---|---|---|
| `LEIGOD_RESET_WLAN0` | `1` | 每次启动重建 dummy wlan0。dummy 建在宿主 netns, 停止容器不会消失, 上面的 `/32` 设备 IP 会随宿主换网络累积, 插件可能把失效 IP 报给 App; 重建即清零。设 `0` 则沿用 AUR 的"幂等不动"行为 |
| `LEIGOD_STOP_GRACE` | `8` | 停止时广播 SIGTERM 后等多少秒再 SIGKILL 残余进程 |
| `TZ` | 镜像默认 UTC | 日志时间戳时区(镜像内含 tzdata) |

## 常用命令

```bash
docker compose logs -f                                   # 容器 stdout/stderr
docker compose exec leigod-steamdeck-plugin \
    /usr/local/lib/leigod/entrypoint.sh doctor           # 体检: 伪装/文件/能力/端口
tail -f data/log/steamdeck_acc_monitor.log               # 官方 monitor 日志(需 sudo)
tail -f data/log/web_api.log data/log/acc_daemon.log     # web/daemon 日志(需 sudo)
docker compose restart                                   # 改配置后
docker compose down                                      # 停止(绑定状态保留)
sudo docker/cleanup.sh                                   # 自查宿主残留(dummy wlan0 等)
sudo docker/cleanup.sh -y                                # 顺带删除 dummy wlan0
```

⚠️ **不要**用 `curl`/`nc` 直连 5589: 官方 web 进程收到裸 HTTP 会 SIGABRT
(TROUBLESHOOTING #1)。探 5588 是安全的 —— 会被 sslh 就地丢弃。

## 已知差异与限制

1. **网络层没有额外隔离**: 出于功能必需(与 AUR 版相同), 插件以 root 在宿主 netns
   里改路由表、iptables、ipset, 并创建 tun_PC。Docker 在这里的收益是"宿主零安装 +
   跨发行版", 不是隔离。
2. **镜像内二进制的可写层**: 见「持久化与升级」。日志与绑定状态都在宿主卷上, 不在可写层。
3. **dummy wlan0 会留在宿主**: 容器停止不会删它(与 systemd 版相同);
   `docker/cleanup.sh` 自查/清理。
4. **5589 在 LAN 上可直连**(web 进程监听 `0.0.0.0`, 绕过 sslh): 属既有暴露面,
   与本封装无关(MIGRATION.md 非问题存档)。
5. **`/proc/sys` 只读**(等价 `ProtectKernelTunables=yes`): 与 AUR 版同一取舍, 若日志
   指向 sysctl 写入失败, 见 README「安全与已知限制」§3 的处理。
6. **需要宿主内核模块**: 容器不能 `modprobe`(无 `SYS_MODULE`), `tun`/`dummy`/`ip_set`
   必须宿主就绪 —— 与 AUR 的 `modules-load.d` 同样的前提。
7. **僵尸进程**: compose 打开了 `init: true`, 由 tini 回收(这一点比 systemd 版更好,
   systemd 版因为 monitor 是 pid 1, 孤儿会滞留)。

## 构建参数

```bash
docker compose build \
  --build-arg LEIGOD_MIRROR=http://119.3.40.126 \
  --build-arg SHA_ACC=<sha256> --build-arg SHA_XDB=<sha256> --build-arg SHA_MONITOR=<sha256>
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `LEIGOD_MIRROR` | `http://119.3.40.126` | 上游下载基址(明文 HTTP, 无签名) |
| `SHA_ACC` / `SHA_XDB` / `SHA_MONITOR` | PKGBUILD 前 3 项 | 三个远程文件的 sha256, 换镜像必须同步改 |
| `SKIP_VERIFY` | `0` | 置 `1` 跳过校验(构建日志打印实际哈希), 仅用于核对新版本 |

上游发新版会让构建在校验处失败并打印 want/got —— 这是设计如此(哈希是唯一信任锚点)。

## 排障

先看 `entrypoint.sh doctor` 的输出, 再对号入座 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。
容器特有的几类:

| 现象 | 原因/处理 |
|---|---|
| 容器反复重启, 日志 `error: /dev/net/tun 不存在` | 宿主没加载 tun 模块, 或 compose 的 `devices` 被删 |
| `error: ensure-wlan0.sh 失败` | 宿主未 `modprobe dummy`, 或丢了 `cap_add: NET_ADMIN` |
| 日志 `DMI 不是 Jupiter` 警告 | `./fake_product_name` 挂载丢失/被改 |
| 容器反复重启, 日志 `sslh guard failed to start` | 5588 被占用(entrypoint 会先打一条 `5588 已被占用` 的警告)。`sudo ss -lntp \| grep ':5588 '` 查属主后停掉冲突实例: 宿主 systemd 版(`systemctl status leigod_plugin` / `leigod`)、另一个容器, 或别的进程 |
| 反复重启且 `/var/run/acc_daemon.lock` 有内容 | 有人把 `/run` 的 tmpfs 去掉了或自制 compose 漏了它(MIGRATION.md §5) |
| 加速命令到达但 `create tun rules failed` | `ipset` 缺失或 `/dev/net/tun` 未放行(TROUBLESHOOTING #3) |
| App 提示"Steam Deck 识别失败" | 先查 `data/log/acc_daemon.log` 是否 `sig:6` 刷屏(裸 HTTP 打到 5589); 再查 dummy wlan0 上是否有多个历史 IP(`LEIGOD_RESET_WLAN0=1` 会清) |
| 能绑定成功, 但 App 一直识别不到 SteamDeck / 设备离线 | 容器里 `ping` 缺失(旧镜像)。插件用 `ping 223.5.5.5` 判定网络在线, 缺了会每秒刷 `current network is offline` 并且**不发云端 keepalive**(route-turn:5588 的 64B/10s), 云端记为离线。查 `docker compose exec leigod-steamdeck-plugin command -v ping`(应为 `/usr/bin/ping`), 没有就 `docker compose build --pull && docker compose up -d`(TROUBLESHOOTING #8) |
