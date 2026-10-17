# flclash-auto 实施计划

- 对应规格：`docs/specs/2026-10-17-flclash-auto-design.md`（已批准）
- 原则：每个阶段结束都有**可执行的验收命令**；验收不过不进入下一阶段。
- 不变量：阶段 7（迁移到本机现有部署）之前，**不得改动** `~/flclash-docker/flclash-auto.sh` 与现有 cron。

## 阶段 0：仓库骨架与安全网

**产出**
- `git init`、`.gitignore`（排除 `state/ backup/ flclash/ *.sqlite *.yaml`，放行 `config/*.example`、`tests/fixtures/*.yaml`、`docs/**`）
- `LICENSE`（MIT）、`README.md` 骨架、`bin/flclash-auto`（仅 `--version`/`--help` 可用）
- `.github/workflows/ci.yml`（shellcheck + tests，此时测试为空跑）
- `config/flclash-auto.conf.example`

**验收**
```bash
bin/flclash-auto --version && bin/flclash-auto --help
git status --porcelain   # 不应出现 state/ backup/ flclash/ 下任何文件
```

## 阶段 1：`lib/common.sh`

**内容**
- 路径解析（`readlink` 循环 + `pwd -P`）、`ROOT_DIR`
- 配置加载（env > conf > 默认）与校验；`require_cmd`
- `log/say`、`rotate_log`、`note_update`
- `lock_acquire/lock_release`（目录锁 + 30 分钟残锁接管）
- `core_up`、`health_ok`、`installed_version`、`json_escape`
- `--selftest`（依赖、目录、容器、DB schema、PyYAML）

**验收**
```bash
tests/test.sh            # 配置优先级 / 日志截断 / note_update 去重
flclash-auto --selftest  # 通过，且缺依赖时报出具体包名
```

## 阶段 2：`lib/subscription.sh`

**内容**
- `sub_url()`（读 DB）、`sub_ua()`、`fetch_subscription()`（HTTP 200 + 体积 + 结构校验）
- `transform_profile()`：PyYAML 实现规格 §5；**PyYAML 缺失硬失败**
- `apply_profile()`：备份 → 原子写入 → 更新 DB 时间戳 → `docker restart` → 健康等待
- `--apply-raw` 分支

**验收**
```bash
tests/test.sh                    # 4 个 fixture + 截断/版本不符
flclash-auto --force --dry-run   # 打印将改写的分组、不写盘
```
在**副本**上真实改写一次，diff 确认：只有目标分组变 `url-test`，其余字节级不变（除 YAML 序列化格式）。

## 阶段 3：`lib/watchdog.sh`

**内容**
- 规格 §6 状态机（锁让路 → 漂移 → 到期 → 健康阶梯）
- `--explain`（共用判定逻辑，DRY_RUN 不产生副作用）

**验收**
```bash
flclash-auto --check      # 静默、exit 0
flclash-auto --explain    # 输出"健康且无到期"的理由
```
故障演练（在**临时容器/临时数据目录**上做，不碰生产）：
1. 制造漂移（profile 改回 `select`）→ 一轮内恢复；
2. `health_fail` 预置 1 次 + 不可达 `HEALTH_URL` → 触发重启 → 恢复计数清零。

## 阶段 4：`lib/upgrade.sh`

**内容**
- `latest_release`、`ver_newer_than`、`in_window`、`verify_deb`
- 门限判定与状态机（§7）；`--dry-run`；`--rollback`；坏版本封禁
- 失败矩阵逐条实现（含 commit 失败**不重建**）

**验收**
```bash
tests/test.sh                                  # 版本比较/窗口跨零点/截断 deb
flclash-auto --upgrade --dry-run               # 输出：候选版本、观察期、窗口判定、下载校验结果；容器无改动
```
**行为对齐彩排**：用 0.8.98 deb 重跑"同版本重装 → commit → 重建"脚本，确认与现有脚本结果等价（版本不变、健康、镜像可回滚）。

## 阶段 5：CLI 收口

**内容**
- `--status` / `--status --json` / `--recreate` / `--save-run-args` / `--install-cron` / `--uninstall-cron` / `--version`
- 未知参数 exit 2

**验收**
```bash
for c in --status --selftest --explain --check; do flclash-auto $c; done
flclash-auto --status --json | python3 -m json.tool
flclash-auto --bogus; echo "exit=$?  # 期望 2"
```

## 阶段 6：安装器与文档

**内容**
- `install.sh`（拷贝 bin+lib、建软链、生成 conf、可选装 cron、幂等）
- `uninstall.sh`（`--purge` 才删配置/状态）
- README：三步开始、原理、适用范围、**订阅 URL 等同密码**警告、故障注入验收清单、排障表（DB 被回写/分组改名/入口 IP 轮换/github.com 直连不通/截断 deb）
- CI 全绿

**验收**
```bash
# 完全隔离的假 HOME 里装一遍
HOME=/tmp/fakehome PREFIX=/tmp/fakehome/.local ./install.sh
/tmp/fakehome/.local/bin/flclash-auto --version
shellcheck -x bin/* lib/*.sh install.sh uninstall.sh tests/test.sh
```
（`--selftest` 在假 HOME 下会因无容器而失败，属预期；用 `--version`/`--help` 验证路径解析。）

## 阶段 7：迁移到本机生产（需单独确认）

**步骤**
1. 备份现脚本与 cron：`flclash-auto.sh.bak-20261017`、`crontab -l > crontab.bak`。
2. `./install.sh` + conf 指向现有 `DATA_DIR=~/flclash-docker/flclash`、`STATE_DIR=.../state`（保留 `sub_hash`，避免无谓重启）。
3. `--selftest` → `--status` → `--check`（必须静默，日志零新增）。
4. 替换 cron 两条为 `~/.local/bin/flclash-auto --check` 与 `--check-update`。
5. 故障注入验收：杀容器内 FlClash → 第 1 轮计数 → 第 2 轮重启恢复（约 10s）。
6. 观察 24h（含一次 6h 订阅周期与一次版本检查），确认日志只有预期行。
7. 稳定后才删除旧 `~/flclash-docker/flclash-auto.sh`。

**回滚**：恢复 `crontab.bak` 与旧脚本文件即可，状态目录格式完全兼容。

## 执行方式（待选）

- **A｜逐阶段**：每阶段停下报验收结果，你确认再继续（控制最强，往返最多）。
- **B｜一口气**：阶段 0–6 全部做完，一次性交验收证据与 diff（最快，中途无可干预点）。
- **C｜两段式（推荐）**：先做 0–6 并停下交付，阶段 7 迁移生产单独等你点头。
