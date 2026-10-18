# flclash-auto

[![CI](https://github.com/ph-rui/flclash-auto/actions/workflows/ci.yml/badge.svg)](https://github.com/ph-rui/flclash-auto/actions/workflows/ci.yml)

Keep a Docker-hosted [FlClash](https://github.com/chen08209/FlClash) self-healing: **subscription refresh**, **region-only auto node selection**, and **staged version upgrades** — all unattended, all reversible.

> 用 Docker 跑 FlClash 的人，最烦的三件事：订阅过期、节点变慢、升级手忙脚乱。
> 这个工具把这三件事做成定时自愈：只在新加坡/香港/日本/台湾里自动择优、订阅变了自动改写并重启、
> 新版本观察满 7 天才在凌晨窗口升级、失败自动回滚、坏版本自动拉黑。

---

## 它解决什么

| 痛点 | 做法 |
|---|---|
| 机场节点增删改名，手写分组就废 | 把订阅里的节点选择组改写成 mihomo 原生 `url-test`，用 `filter` 限定区域，**不记录任何节点名** |
| FlClash 自己更新订阅，把改写冲掉 | 接管订阅（`auto_update=0`），每 6 小时比对内容哈希；检测到改写被冲掉会自动恢复 |
| 代理挂了没人管 | 每 5 分钟实测出网；连续失败自动重启容器，仍不行就强制重下订阅 |
| 升级新版本可能踩坑、重建容器又回退旧版 | 观察期 + 维护窗口 + 健康前置；升级后 `docker commit` 固化版本，失败自动回滚并拉黑坏版本 |

## 环境要求

- Linux（x86_64），已用 Docker 运行 FlClash，容器内能执行 `dpkg`
- 宿主：`bash ≥ 4.4`、`docker`、`curl`、`sqlite3`、`python3`、`iproute2`（`ss`）
- **硬依赖** `python3-yaml`：`sudo apt install python3-yaml`
- FlClash 数据目录挂在工作区（本工具直接读写 `database.sqlite` 与 `profiles/<id>.yaml`）

## 快速开始

```bash
git clone https://github.com/ph-rui/flclash-auto.git && cd flclash-auto

./install.sh                       # 装到 ~/.local，生成 ~/.config/flclash-auto/config.conf
$EDITOR ~/.config/flclash-auto/config.conf   # 至少确认 DATA_DIR / STATE_DIR / CONTAINER
flclash-auto --selftest            # 依赖、路径、DB schema、容器、PyYAML 全检
flclash-auto --status              # 看一眼当前版本 / 出口 / 改写状态
flclash-auto --install-cron        # 写入两条 cron（幂等）
```

首次接管时，现有 profile 通常还是 `select` 分组，执行一次即可完成改写：

```bash
flclash-auto --force
```

之后 cron 会每 5 分钟巡检、每小时检查版本。稳态下 5 分钟巡检**不写任何日志**，
每 6 小时的订阅检查最多记一行（有变化才动容器）。

## 工作原理

```
cron */5  ──► --check
               ├─ 升级锁存在？            → 让路（升级期间应用被停掉，健康检查必然失败）
               ├─ url-test 改写丢了？     → 重下订阅 + 改写 + 重启 + 验证
               ├─ 订阅满 6 小时？         → 下载 → 内容哈希比对 → 变了才应用
               └─ 出网实测失败？          → 计数 → 达阈值重启 → 仍不行则强制刷新订阅

cron 23 * ──► --check-update
               └─ 有新版本 && 发布满 7 天 && 03:00–05:00 && 当前健康 && 当日未升级
                    └─► --upgrade：备份 → 下载校验 → dpkg -i → 重启验证
                          → docker commit flclash:<新版本> → 用新镜像重建 → 再验证
                          └─ 任一步失败：回滚旧镜像，并把该版本标记为坏版本
```

关键设计：

- **不写死节点名**：`url-test` 按延迟自动挑，节点改名增删都不影响。
- **改写用 PyYAML 解析**，不靠正则：block / flow 两种 YAML 写法都支持；节点列表以外的内容保持语义不变。
- **改写不到任何分组 = 失败**：保留旧 profile、不重启、写日志。逃生口是 `--apply-raw`。
- **失败只推进时间戳、不推进哈希**：下个 6 小时周期重试，不会每 5 分钟把机场打一遍。
- **升级门槛四项独立**：版本更高、当日未升级、非坏版本、当前健康；`--force` 才跳过这四项，但**不跳过**备份、deb 完整性校验与失败回滚。
- **坏版本可以整段拉黑**：`state/upgrade_blocked` 每行是一条 glob（如 `0.9.*`），命中即跳过；失败时自动追加精确版本。整段拉黑是为了避免同一系列的后续版本每晚 03:00 再白试一次（失败会回滚，但仍有一次短暂中断）。`--force` 只绕过门限，**不会**清空该文件。
- **版本固化**：升级成功后 `docker commit`，日后容器被删重建也不会回退。
- **回滚连数据库一起还原**：新版可能把 `database.sqlite` 迁移成新 schema（实测 FlClash 0.9.0 就会），旧版镜像读到新库会直接起不来。所以失败回滚会先还原升级前的 `database.sqlite` / `shared_preferences.json`，再换回旧镜像——否则"镜像回滚"只是假的回滚。

## 常用命令

```
--check            常规巡检（cron 用；无变化时静默）
--explain          只打印本轮会做什么/为什么不做，不产生任何改动
--force            立刻重下订阅并应用（改写失败保留旧配置）
--apply-raw        原样应用订阅，跳过 url-test 改写（机场格式变了时的逃生口）
--status [--json]  状态总览 / 机器可读状态
--selftest         环境自检
--check-update     版本灰度检查（cron 用）
--upgrade [--dry-run] [--force]
                   手动升级；--dry-run 会真实下载并校验 deb，但不动容器
--rollback         回滚到 state/prev_image 记录的镜像
--recreate <img>   用指定镜像重建容器（复用捕获的 run 参数）
--install-cron / --uninstall-cron
```

退出码：`0` 正常或无需动作，`1` 需人工或动作后仍不健康，`2` 用法/配置错误，
`3` 订阅里没有可改写的分组（已保留旧 profile，可用 `--apply-raw` 先保连通）。

## 配置

`~/.config/flclash-auto/config.conf`（`FLCLASH_AUTO_CONF` 可覆盖），优先级：**环境变量 > 配置文件 > 默认值**。
配置文件是被**解析**的，不是被 `source` 的，所以不支持 `$HOME` 之类变量展开，路径请写绝对路径。

| 键 | 默认 | 说明 |
|---|---|---|
| `CONTAINER` | `flclash-docker` | 容器名 |
| `DATA_DIR` | `~/flclash-docker/flclash` | FlClash 数据目录（挂载点） |
| `STATE_DIR` | `~/flclash-docker/state` | 锁、哈希、日志、run 参数 |
| `BACKUP_DIR` | `~/flclash-docker/backup` | 升级前 DB/配置备份 |
| `PROFILE_ID` | 空=自动 | 留空时先读 `shared_preferences.json`，再退回"唯一 profile" |
| `PROXY` | `http://127.0.0.1:7890` | 健康检查与 deb 下载用的代理 |
| `HEALTH_URL` | Google `generate_204` | 改成你确认可达的 204 地址 |
| `REGION_FILTER` | 新/港/日/台 | `url-test` 的节点过滤正则 |
| `SUB_REFRESH_INTERVAL` | `21600` | 订阅检查间隔（秒） |
| `UPGRADE_WAIT_DAYS` | `7` | 新版观察期 |
| `UPGRADE_WINDOW` | `03:00-05:00` | 维护窗口，支持跨零点 |
| `UPGRADE_ENABLED` | `1` | 关掉自动升级 |

完整项见 `config/flclash-auto.conf.example`。

## 安全

- 订阅 URL 等同账号凭据。本工具**运行时从 FlClash 数据库读取**，不落任何配置文件；
  请确认你提交/分享的内容里没有 `state/`、`backup/`、`flclash/`（仓库的 `.gitignore` 已默认排除）。
- 安装与升级都要写 Docker；建议只在你自己的机器上以普通用户运行，不要放进不受信任的容器。
- 每次升级前都备份 `database.sqlite`、`shared_preferences.json` 与当前 profile；升级失败回滚时前两者会自动还原（`BACKUP_DIR` 里也保留了完整副本供人工取证）。

## 排障

| 现象 | 原因 / 处理 |
|---|---|
| `MISS python3-yaml` | `sudo apt install python3-yaml`（这是硬依赖，不是降级项） |
| `改写丢失` 反复出现 | UI 里点了"更新订阅"。FlClash 的 `auto_update` 需为 0；本工具每轮会重新置 0 |
| 报"没有可改写的 select 分组" | 机场改了分组格式。先用 `--apply-raw` 保住连通，再按日志调整 `SKIP_GROUP_KEYWORDS` |
| `--check-update` 一直不升级 | `--status` 看 `upgrade_state`：`waiting` 观察期未满、`window` 等维护窗口、`blocked` 该版本被拉黑（人工确认后 `--upgrade --force`） |
| deb 反复下载失败 | 多数网络下 `github.com` 直连不通。本工具会直连快速失败后自动走 `PROXY` |
| 容器重建后版本回退 | 说明 `docker commit` 那一轮失败了，日志里有明确的 `docker commit <容器> flclash:<版本>` 补救命令 |
| 升级后不健康 | 工具会自动回滚（含还原升级前的 `database.sqlite`）；若回滚也失败，用 `--rollback` 或 `docker logs <容器>` 人工定位 |
| 升级后 7890 不监听、无核心进程 | 已知：FlClash **0.9.x**（0.9.0、0.9.1 均实测，以 root 运行也一样）在 headless Docker 镜像里不会正常拉起 `FlClashCore`，见 [docs/notes/2026-10-17-flclash-0.9.0-docker-incompatible.md](docs/notes/2026-10-17-flclash-0.9.0-docker-incompatible.md)（上游 issue [#2728](https://github.com/chen08209/FlClash/issues/2728)）。工具会把整个 `0.9.*` 拉黑并留在旧版 |

调试三件事：`--explain` 看判定理由、`--status` 看整体状态、`state/watchdog.log` 看历史。

## 适用范围与限制

- **只支持 Docker 版 FlClash**（Debian 系镜像）。Clash Verge / mihomo 裸内核 / 其它客户端不在范围内。
- 依赖 FlClash 的数据布局：`database.sqlite` 的 `profiles` 表、`profiles/<id>.yaml`、`shared_preferences.json`。
  上游改 schema 会直接报错而不是静默乱写（`--selftest` 会先查）。
- 重建容器时复用捕获的 `docker run` 参数，覆盖 name/network/user/privileged/cap-add/device/binds/env/restart；
  `add-host`、`dns`、`sysctl`、`ulimit`、`shm-size`、`publish` 不在其内——如果你手工加过这些，请先 `--save-run-args` 并核对。
- 没有内置通知。需要提醒就把日志接进你自己的告警。

## 开发

```bash
shellcheck -x bin/flclash-auto lib/*.sh install.sh uninstall.sh tests/test.sh
tests/test.sh          # 纯函数与改写夹具测试，不需要 docker
```

设计文档在 `docs/specs/`，实施计划在 `docs/plans/`。

## License

MIT
