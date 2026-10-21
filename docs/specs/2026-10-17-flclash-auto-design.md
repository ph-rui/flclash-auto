# flclash-auto 设计规格

- 状态：待评审
- 日期：2026-10-17
- 路径选择：方案 2（`bin/` + `lib/*.sh` 多文件）

## 1. 目的与受众

面向**在 Linux 上用 Docker 跑 FlClash、并依赖它作为出口代理**的用户，把"订阅更新 → 挑一个能用的节点 → 版本升级"从手工操作变成无人值守。

受众明确限定为 FlClash（不做 Clash Verge / mihomo / 裸客户端）。

### 成功标准

1. 陌生人在 Ubuntu 上按 README 完成：`git clone` → `./install.sh` → `--selftest` 通过 → 装 cron。
2. 机场改节点名、增删节点、改分组名后，**无需任何人工操作**，代理持续可用。
3. 机场改入口 IP/端口后自愈（入口 IP 确实会轮换，1 天内已观测到两次不同 IP）。
4. FlClash 出新版后，在"发布满 7 天 + 凌晨窗口 + 当前健康"三个条件满足时自动升级并固化进镜像；失败自动回滚。
5. 仓库内**不含**任何订阅内容、节点凭据、主机私有数据。

### 非目标

Windows/macOS；非 Docker 的 FlClash；Clash Verge / mihomo / sing-box；多实例多用户；GUI；节点按延迟手动排序。

## 2. 仓库结构

```
flclash-auto/
├── bin/flclash-auto            # 入口：解析真实路径 → source libs → 解析参数 → 分发
├── lib/common.sh               # 配置加载与校验、日志、文件锁、健康检查、docker 封装
├── lib/subscription.sh         # 订阅下载、YAML 分组改写、原子写入、应用并重启
├── lib/watchdog.sh             # 巡检状态机（漂移 / 到期 / 健康阶梯）
├── lib/upgrade.sh              # 版本发现、灰度门限、安装、固化、回滚
├── install.sh                  # 幂等安装：拷贝到 ~/.local/lib/flclash-auto + 软链 + 生成 conf
├── uninstall.sh                # 卸载（保留配置与状态，除非 --purge）
├── config/flclash-auto.conf.example
├── tests/test.sh               # 纯函数单测（不需要 docker）
├── tests/fixtures/*.yaml       # flow / block / 混合 / 含垃圾分组 四类样本
├── .github/workflows/ci.yml    # shellcheck + tests
├── README.md
├── LICENSE                     # MIT
└── .gitignore
```

### 路径解析（多文件的唯一真实风险）

入口必须逐层解析符号链接：

```bash
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
BIN_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
ROOT_DIR="$(cd "$BIN_DIR/.." && pwd -P)"
```

`install.sh` 把 `bin/`、`lib/` 拷到 `${PREFIX:-$HOME/.local}/lib/flclash-auto/`，在 `${PREFIX}/bin/` 建软链。这样 cron 路径稳定，且安装动作本身就验证了软链解析。

## 3. 配置

读取顺序：`FLCLASH_AUTO_CONF` → `$XDG_CONFIG_HOME/flclash-auto/config.conf` → `$HOME/.config/flclash-auto/config.conf`。优先级：**环境变量 > 配置文件 > 内置默认**。

启动时校验并在失败时给出可操作报错（缺哪个命令、哪个目录不存在、哪一行 conf 语法错）。

| 变量 | 默认值 | 含义 |
|---|---|---|
| `CONTAINER` | `flclash-docker` | 容器名 |
| `DATA_DIR` | `$HOME/flclash-docker/flclash` | FlClash 数据卷宿主路径（DB/配置/profile 所在） |
| `STATE_DIR` | `$HOME/flclash-docker/state` | 状态、锁、日志 |
| `BACKUP_DIR` | `$HOME/flclash-docker/backup` | 升级前备份 |
| `LOG_FILE` | `$STATE_DIR/watchdog.log` | 主日志 |
| `LOG_MAX_BYTES` / `LOG_KEEP_LINES` | `1048576` / `2000` | 日志截断 |
| `PROFILE_ID` | 空=自动 | 空时依次尝试：`shared_preferences.json` 的 `currentProfileId` → DB 只有一条 profile → 报错 |
| `PROXY` | `http://127.0.0.1:7890` | 本机代理入口 |
| `HEALTH_URL` | `https://www.google.com/generate_204` | 健康检查（经代理请求） |
| `HEALTH_FAIL_THRESHOLD` | `2` | 连续失败多少次才重启 |
| `SUB_REFRESH_INTERVAL` | `21600` | 订阅刷新间隔（秒） |
| `REGION_FILTER` | `新加坡\|香港\|日本\|台湾\|Singapore\|Hong Kong\|Japan\|Taiwan\|SG\|HK\|JP\|TW` | 改写时过滤分组成员的正则；`.*` = 不过滤（全部节点） |
| `TEST_URL` | `http://www.gstatic.com/generate_204` | url-test 测速地址 |
| `URLTEST_INTERVAL` | `300` | 测速间隔（秒） |
| `URLTEST_TOLERANCE` | `50` | 切换迟滞（毫秒） |
| `SKIP_GROUP_KEYWORDS` | `公告\|通知\|提醒\|说明\|使用\|剩余\|到期\|流量\|时间\|官网\|脚本\|更新` | 不改写的分组名关键词 |
| `SUB_UA_TEMPLATE` | `FlClash/{version}` | 下载订阅的 UA（部分机场按 UA 发不同内容） |
| `UPGRADE_ENABLED` | `1` | 版本自动升级开关 |
| `UPGRADE_WAIT_DAYS` | `7` | 观察期 |
| `UPGRADE_WINDOW` | `03:00-05:00` | 维护窗口，支持跨零点 |
| `GH_REPO` | `chen08209/FlClash` | 上游仓库 |
| `KEEP_IMAGES` | `2` | 仅用于提示可清理，**不自动删除** |

## 4. CLI 接口

| 子命令 | 行为 | 典型调用方 |
|---|---|---|
| `--check`（默认） | 巡检，无变化时静默 | cron 每 5 分钟 |
| `--explain` | 打印本轮判定的**理由**（锁/漂移/未到期/无变化/健康），不改变行为 | 人工排障 |
| `--force` | 立即重下订阅并应用（**改写失败则保留旧 profile 并报错**，不会降级成 select） | 人工 |
| `--apply-raw` | 原样应用订阅、跳过 url-test 改写（机场格式突变但你要先保住连通时的逃生口） | 人工 |
| `--status` | 状态总览 | 人工 |
| `--status --json` | 机器可读状态 | 监控 |
| `--selftest` | 依赖、配置、容器、DB schema 校验 | 安装后 |
| `--check-update` | 灰度版本检查，条件齐备则升级 | cron 每小时 |
| `--upgrade [--dry-run] [--force]` | 手动升级；`--dry-run` 只查/下载/校验/打印步骤 | 人工 |
| `--rollback` | 回滚到 `state/prev_image` | 人工 |
| `--recreate <image>` | 用指定镜像重建容器（使用捕获的 run 参数） | 人工 |
| `--save-run-args` | 重新捕获 run 参数 | 人工 |
| `--install-cron` / `--uninstall-cron` | 增删两条 cron（幂等，保留其他条目） | 安装/卸载 |
| `--version` / `--help` | 版本与用法 | 人工 |

退出码：`0` 正常/无需动作，`1` 执行了动作但结果不健康或需要人工，`2` 用法/配置错误。

`--json` 输出字段：`installed_version`、`latest_version`、`upgrade_state`（`latest|waiting|window|blocked|disabled`）、`days_waited`、`profile_id`、`transform_ok`、`healthy`、`exit_ip`、`container_image`、`images`、`error`（无错时为 null）。

日志格式：`[YYYY-MM-DD HH:MM:SS] LEVEL: message`，LEVEL ∈ `INFO|OK|WARN|ERROR|UPDATE`；`--explain` 的判定理由写 stdout，不写日志。

## 5. 订阅改写（核心算法）

**依赖**：`python3` + `python3-yaml`。缺失时**硬失败**（提示 `sudo apt install python3-yaml`），绝不"没改写成功却继续"。

算法：

1. 解析 profile YAML（`yaml.safe_load`，容忍未知标签）。
2. 顶层必须有 `proxies` 列表；建立节点名集合 `NODES`。
3. 逐项处理 `proxy-groups`：
   - `type != select` → 跳过
   - 存在 `use`（代理提供者）→ 跳过
   - 名称命中 `SKIP_GROUP_KEYWORDS` → 跳过
   - 成员 = `proxies` 列表（若 `include-all: true` 则成员 = 全部节点，按 profile 顺序）
   - **任一成员不在 `NODES` 中**（说明该组引用的是别的分组）→ 跳过并 WARN
   - 成员数 < 2 → 跳过
   - 按 `REGION_FILTER` 过滤成员；过滤后 < 2 个 → 跳过（不改写成跨区域的 url-test）
   - 满足全部条件 → 设 `type=url-test`、`url=TEST_URL`、`interval=URLTEST_INTERVAL`、`tolerance=URLTEST_TOLERANCE`、`lazy=false`、`filter=REGION_FILTER`；`proxies` 替换为过滤后的区域节点，移除 `include-all`
   - 说明：mihomo 的 `filter` 只对 proxy-provider / include-all-proxies 生效，对显式 `proxies` 无效，因此必须改写列表本身
4. 用 `yaml.safe_dump(allow_unicode=True, sort_keys=False)` 序列化，**原子写入**（临时文件 + `os.replace`）。
5. **一个组都没改写 → 视为失败**：保留旧 profile、不重启容器、记 ERROR 并给出原因。人工可 `--apply-raw` 原样应用（用于机场格式突变时先保连通）。

配套：`--check` 检测 profile 中已无 `url-test`（被 UI 手动更新冲掉）→ 重新下载并改写。

## 6. 巡检状态机

判定顺序（`--explain` 输出的就是这个顺序）：

1. `upgrade.lock` 存在且 < 30 分钟 → 让路退出（升级中会主动停应用，健康检查必然失败）。
2. profile 改写缺失（无 `url-test`）→ 下载 + 改写 + 应用（含重启与健康验证）。
3. `now - last_sub_sync >= SUB_REFRESH_INTERVAL` → 下载订阅；与 `state/sub_hash`（**原始订阅**的哈希）比较：
   - 变化 → 改写 + 应用；
     - 应用成功 → 同时更新 `sub_hash` 与时间戳；
     - 应用失败 → **只更新时间戳**（避免每 5 分钟重下、把机场打烦），hash 保持旧值以便下个 6h 周期重试，同时记 ERROR；
   - 未变化 → 只更新时间戳，不动容器。
4. 健康检查（经代理请求 `HEALTH_URL`，期望 204/200）：
   - 正常 → 失败计数清零；
   - 失败 → 计数 +1；达到阈值 → 重启容器并验证；仍失败 → 强制重下订阅并改写；仍失败 → 记 ERROR 等人工（不无限循环）。

## 7. 版本升级状态机

门限（全部满足才自动动手）：`UPGRADE_ENABLED=1`、发现语义化版本更高、**发布已满 `UPGRADE_WAIT_DAYS` 天**、当前处于 `UPGRADE_WINDOW`、**当前代理健康**、当日未升级过、该版本未被标记为坏版本。

状态取值（供 `--json`）：`disabled` | `latest` | `waiting`（观察期） | `window`（等窗口） | `blocked`（坏版本） | `running` | `failed`。

`--upgrade --force` 的语义：跳过"版本更高 / 当日一次 / 坏版本封禁 / 当前健康"四项门限（人工显式承担风险），但**不跳过**备份、deb 完整性校验与失败回滚。

升级流程与失败矩阵：

| 失败点 | 处理 |
|---|---|
| 查 GitHub / release 无 deb | 中止，**不改动任何东西** |
| deb 下载不完整或校验失败 | 3 轮重试（直连快失败→代理），中止不改动 |
| `dpkg -i` 失败（含补依赖后） | 标记坏版本 → 用旧镜像重建容器回滚 |
| 安装后版本号不符 | 标记坏版本 → 回滚 |
| 重启后健康检查失败 | 标记坏版本 → 回滚 |
| `docker commit` 失败 | **不动容器**（它已是健康新版），告警要求人工固化 |
| 用新镜像重建后不健康 | 标记坏版本 → 回滚 |
| 回滚本身失败 | ERROR + 人工，禁止自动重试同一版本 |

安全细节（均为已实测结论，不得退化）：

- deb 完整性必须用 `dpkg-deb -c`（强制解压 data.tar）；`dpkg-deb -f` 只读文件头，**截断文件会误判通过**。
- 升级前备份 `database.sqlite`、`shared_preferences.json`、profile 到 `BACKUP_DIR`（带时间戳）。
- 安装前先停应用（避免旧版进程在解包期间回写配置）；`docker restart` 负责拉起新版。
- 目录锁（`upgrade.lock/`）+ 30 分钟残锁接管；巡检认锁让路。
- run 参数从运行中容器 `docker inspect` 捕获（name/network/user/privileged/cap-add/device/binds/env 差异/restart），重建前核对；未捕获的 flag 在 README 中列明。
- `docker commit` 出来的镜像体积大，**不自动 prune**。

## 8. 磁盘状态文件

`state/` 下：`last_sub_sync`、`sub_hash`、`health_fail`、`last_update_note`、`upgrade_candidate`、`upgrade_blocked`、`last_upgrade`、`prev_image`、`run-args`、`upgrade.lock/`、`profile.<id>.yaml.prev`、`install-<version>.log`。全部可安全删除（会退回初始行为）。

## 9. 测试

`tests/test.sh`（不需要 docker，CI 可跑）：

1. `ver_newer_than`：`0.9.0 > 0.8.98`、`0.8.99 > 0.8.98`、相同/空值。
2. `in_window`：普通窗口、跨零点窗口、边界分钟。
3. `verify_deb`：完整 deb 通过；**截断 deb 被拒**；版本不符被拒（需要 `dpkg-deb`，缺失则 skip）。
4. `transform_profile`：4 个 fixture —— 行内 flow、块格式、单双引号混合、含"公告/流量"垃圾分组；断言只改该改的、成员引用其他组的不改、无效输入返回失败。
5. 配置优先级：env 覆盖 conf，conf 覆盖默认。
6. 日志截断与 `note_update` 去重。

CI：`shellcheck -x` 全部脚本 + `bash -n` + `tests/test.sh`（ubuntu-latest，安装 `python3-yaml shellcheck`）。

不自动测试需要 docker 的路径；README 提供手工验收清单（注入故障→2 轮巡检→自愈）。

## 10. 安装与迁移

`install.sh`：判断依赖 → 拷贝 `bin/ lib/` 到 `${PREFIX:-$HOME/.local}/lib/flclash-auto/` → 建 `${PREFIX}/bin/flclash-auto` 软链 → 若配置不存在则从 example 复制并提示编辑 → 可选 `--install-cron` → 打印 `--selftest` 命令。

从现有单文件脚本迁移（部署到开发机时执行）：

1. 保留现有 `state/`（含 `sub_hash`），conf 指向同一 `STATE_DIR`/`DATA_DIR`，避免重复重启。
2. 新脚本 `--selftest` → `--status` → `--check`（应为静默无动作）。
3. 替换 cron 两条（旧的 5 分钟巡检与每小时版本检查）。
4. 故障注入验收：杀掉容器内 FlClash 进程 → 第 1 轮只计数 → 第 2 轮重启恢复。
5. 确认 `config.yaml` 仍为 `url-test` + region filter，出口 IP 正常。

## 11. 安全与合规

- **订阅 URL 等同账号密码**：不得提交 `state/`、`backup/`、数据目录；`.gitignore` 覆盖 `state/ backup/ flclash/ *.sqlite *.yaml`（`config/*.example` 与 `tests/fixtures/*.yaml` 例外）。
- README 醒目提示：脚本对 FlClash 数据目录有写权限、会执行 `docker commit`、容器本身通常以 `--privileged --network host` 运行，这些是 FlClash 侧的要求。
- License：MIT（脚本是独立运维工具，不链接/不打包 FlClash 本体，故不受其 GPL-3.0 传染）。
- 仓库不含任何 FlClash 二进制或 deb。

## 12. 兼容性与已知限制

- 需要 bash ≥ 4.4、coreutils、curl、sqlite3、python3 + python3-yaml、docker CLI、iproute2（`ss`）、`dpkg-deb`、cron（或 systemd timer）。
- 依赖 FlClash 数据库 `profiles.url` / `profiles.id` / `currentProfileId` 的语义；上游若改 schema，`--selftest` 会指出。
- 改写后的 profile 为块格式（PyYAML 序列化结果），FlClash 会自行再序列化成 `config.yaml`，已验证可用。
- 只对"节点名含区域关键词"的机场有效；`REGION_FILTER` 可改。
- `github.com` 本身在部分网络不可直连（release 资产在 github.com 域名下），故 deb 下载以代理为主路径；版本查询用 `api.github.com`（可直连）。
