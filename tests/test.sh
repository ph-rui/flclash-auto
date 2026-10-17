#!/usr/bin/env bash
# 纯函数单元测试（不需要 docker）
# A && ok || bad 是断言写法：ok/bad 内部不再失败，不存在 SC2015 的隐患
# shellcheck disable=SC2015,SC2034
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 完全隔离：不读真实用户配置
export HOME="$TMP/home"
unset XDG_CONFIG_HOME
mkdir -p "$HOME" "$TMP/state" "$TMP/data/profiles" "$TMP/backup"
export FLCLASH_AUTO_CONF="$TMP/no-such.conf"
export STATE_DIR="$TMP/state"
export BACKUP_DIR="$TMP/backup"
export DATA_DIR="$TMP/data"
export LOG_FILE="$TMP/state/test.log"
export LOG_MAX_BYTES=1048576
export LOG_KEEP_LINES=2000
export PROFILE_ID=1

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/subscription.sh
source "$ROOT/lib/subscription.sh"
# shellcheck source=lib/upgrade.sh
source "$ROOT/lib/upgrade.sh"
# shellcheck source=lib/watchdog.sh
source "$ROOT/lib/watchdog.sh"

config_load || { echo "config_load 失败"; exit 1; }
PROFILE_ID=1

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3（期望 '$2'，实际 '$1'）"; fi; }
assert_ne() { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3（不应等于 '$2'）"; fi; }

section() { printf '\n== %s ==\n' "$1"; }

gval() { # file group key
  python3 - "$1" "$2" "$3" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f)
name, key = sys.argv[2], sys.argv[3]
for g in data.get("proxy-groups") or []:
    if isinstance(g, dict) and g.get("name") == name:
        v = g.get(key, "")
        print("false" if v is False else "true" if v is True else v)
        break
PY
}

transform_copy() { # fixture -> prints transformed names
  cp "$ROOT/tests/fixtures/$1" "$TMP/$1"
  transform_profile "$TMP/$1"
}

# ---------------------------------------------------------------- 版本比较

section "版本比较"
ver_newer_than "0.9.0" "0.8.98" && ok "0.9.0 > 0.8.98" || bad "0.9.0 应大于 0.8.98"
ver_newer_than "0.8.99" "0.8.98" && ok "0.8.99 > 0.8.98" || bad "0.8.99 应大于 0.8.98"
ver_newer_than "0.8.98" "0.8.98" && bad "同版本不应判为新" || ok "同版本不判新"
ver_newer_than "0.8.98" "0.9.0" && bad "旧版本不应判为新" || ok "旧版本不判新"
ver_newer_than "" "0.8.98" && bad "空版本不应判为新" || ok "空版本不判新"

# ---------------------------------------------------------------- 维护窗口

section "维护窗口"
UPGRADE_WINDOW="03:00-05:00"
in_window "03:30" && ok "普通窗口内 03:30" || bad "03:30 应在窗口内"
in_window "02:59" && bad "02:59 不应在窗口内" || ok "普通窗口外 02:59"
in_window "05:00" && ok "窗口右端点 05:00" || bad "05:00 应含在窗口内"
UPGRADE_WINDOW="23:00-01:00"
in_window "23:30" && ok "跨零点 23:30" || bad "23:30 应在窗口内"
in_window "00:30" && ok "跨零点 00:30" || bad "00:30 应在窗口内"
in_window "12:00" && bad "跨零点 12:00 不应在窗口内" || ok "跨零点 12:00 在窗口外"
UPGRADE_WINDOW="03:00-05:00"

# ---------------------------------------------------------------- 配置优先级

section "配置优先级"
cat > "$TMP/conf" <<'EOF'
CONTAINER=from-conf
HEALTH_FAIL_THRESHOLD=9
EOF
FLCLASH_AUTO_CONF="$TMP/conf"
unset CONTAINER HEALTH_FAIL_THRESHOLD
conf_load
assert_eq "$(config_get CONTAINER default)" "from-conf" "配置文件生效"
assert_eq "$(config_get HEALTH_FAIL_THRESHOLD 2)" "9" "配置覆盖默认值"
assert_eq "$(config_get NOT_SET dflt)" "dflt" "未配置项用默认值"
CONTAINER=from-env
assert_eq "$(config_get CONTAINER default)" "from-env" "环境变量优先于配置文件"
unset CONTAINER HEALTH_FAIL_THRESHOLD

printf '这一行没有任何等号\n' > "$TMP/bad.conf"
if ( FLCLASH_AUTO_CONF="$TMP/bad.conf"; conf_load ) >/dev/null 2>&1; then
  bad "非法配置应返回错误"
else
  ok "非法配置返回错误"
fi
FLCLASH_AUTO_CONF="$TMP/no-such.conf"

# ---------------------------------------------------------------- 日志

section "日志"
LOG_FILE="$TMP/rotate.log"
LOG_MAX_BYTES=200
LOG_KEEP_LINES=5
: > "$LOG_FILE"
for i in $(seq 1 40); do printf 'line %02d aaaaaaaaaaaaaaaaaaaaaaaa\n' "$i" >> "$LOG_FILE"; done
rotate_log
assert_eq "$(wc -l < "$LOG_FILE" | tr -d ' ')" "5" "日志超限后截断为 5 行"

LOG_FILE="$TMP/note.log"
: > "$LOG_FILE"
note_update "hello"
note_update "hello"
note_update "world"
assert_eq "$(grep -c 'UPDATE: hello' "$LOG_FILE")" "1" "note_update 相同内容只记一次"
assert_eq "$(grep -c 'UPDATE: world' "$LOG_FILE")" "1" "note_update 变化后记录"
LOG_FILE="$TMP/state/test.log"

# ---------------------------------------------------------------- 分组改写

section "分组改写"
out="$(transform_copy flow.yaml)"
assert_eq "$out" "Flybit" "flow: 返回被改写的分组名"
assert_eq "$(gval "$TMP/flow.yaml" "Flybit" type)" "url-test" "flow: type=url-test"
assert_eq "$(gval "$TMP/flow.yaml" "Flybit" interval)" "$URLTEST_INTERVAL" "flow: interval"
assert_eq "$(gval "$TMP/flow.yaml" "Flybit" tolerance)" "$URLTEST_TOLERANCE" "flow: tolerance"
assert_eq "$(gval "$TMP/flow.yaml" "Flybit" lazy)" "false" "flow: lazy=false"
assert_eq "$(gval "$TMP/flow.yaml" "Flybit" filter)" "$REGION_FILTER" "flow: filter"
assert_eq "$(gval "$TMP/flow.yaml" "Flybit" url)" "$TEST_URL" "flow: url"

out="$(transform_copy block.yaml)"
assert_eq "$out" "订阅节点" "block: 返回被改写的分组名"
assert_eq "$(gval "$TMP/block.yaml" "订阅节点" type)" "url-test" "block: type=url-test"
assert_eq "$(gval "$TMP/block.yaml" "订阅节点" filter)" "$REGION_FILTER" "block: filter"

out="$(transform_copy mixed.yaml)"
assert_eq "$out" "手动选择,全部节点" "mixed: 只改写合规分组"
assert_eq "$(gval "$TMP/mixed.yaml" "手动选择" type)" "url-test" "mixed: 手动选择被改写"
assert_eq "$(gval "$TMP/mixed.yaml" "全部节点" type)" "url-test" "mixed: include-all 被改写"
assert_eq "$(gval "$TMP/mixed.yaml" "自动选择" type)" "select" "mixed: 引用分组的不改写"
assert_eq "$(gval "$TMP/mixed.yaml" "只有一个节点" type)" "select" "mixed: 单成员不改写"

out="$(transform_copy junk.yaml)"
assert_eq "$out" "Flybit" "junk: 只改写目标分组"
assert_eq "$(gval "$TMP/junk.yaml" "剩余流量：100G" type)" "select" "junk: 流量分组不改写"
assert_eq "$(gval "$TMP/junk.yaml" "官网/公告" type)" "select" "junk: 公告分组不改写"

out="$(transform_copy junkonly.yaml)"
assert_eq "$out" "" "无可改分组时输出为空"
assert_eq "$(gval "$TMP/junkonly.yaml" "公告" type)" "select" "无可改分组时保持原样"

printf 'proxies: [\n' > "$TMP/bad.yaml"
if transform_profile "$TMP/bad.yaml" >/dev/null 2>&1; then
  bad "非法 YAML 应返回错误"
else
  ok "非法 YAML 返回错误"
fi

printf 'proxy-groups: []\n' > "$TMP/nonodes.yaml"
if transform_profile "$TMP/nonodes.yaml" >/dev/null 2>&1; then
  bad "没有 proxies 应返回错误"
else
  ok "没有 proxies 返回错误"
fi

# ---------------------------------------------------------------- 改写在位检测

section "改写检测"
printf 'proxy-groups:\n  - {name: x, type: url-test}\n' > "$DATA_DIR/profiles/1.yaml"
transform_present && ok "识别块式 url-test" || bad "应识别块式 url-test"
printf 'proxy-groups:\n  - {name: x, type: "url-test"}\n' > "$DATA_DIR/profiles/1.yaml"
transform_present && ok "识别带引号的 url-test" || bad "应识别带引号 url-test"
# 真实订阅形态：行内 flow 且 url-test 不在行尾（旧正则漏判的正是这种）
printf "proxy-groups:\n  - {name: 'Flybit', type: url-test, url: 'http://x/204', filter: '港', proxies: ['a']}\n" > "$DATA_DIR/profiles/1.yaml"
transform_present && ok "识别行内 flow（url-test 在行中）" || bad "应识别行内 flow"
printf 'proxy-groups:\n  - {name: x, type: select}\n' > "$DATA_DIR/profiles/1.yaml"
transform_present && bad "不应识别 select" || ok "不误判 select"
printf 'proxies:\n  - {name: url-test, type: ss}\nproxy-groups:\n  - {name: x, type: select}\n' > "$DATA_DIR/profiles/1.yaml"
transform_present && bad "不应被节点名 url-test 误导" || ok "不被节点名误导"
printf 'proxies: [\n' > "$DATA_DIR/profiles/1.yaml"
transform_present; [ $? -eq 2 ] && ok "YAML 损坏时返回 2（区别于未改写）" || bad "损坏时应返回 2"

# ---------------------------------------------------------------- deb 校验

section "deb 完整性校验"
if command -v dpkg-deb >/dev/null 2>&1; then
  mkdir -p "$TMP/pkg/DEBIAN" "$TMP/pkg/usr/share/doc/test"
  cat > "$TMP/pkg/DEBIAN/control" <<'EOF'
Package: flclash-auto-test
Version: 1.2.3+build1
Architecture: all
Maintainer: test <test@example.com>
Description: test package for verify_deb
EOF
  printf 'hello\n' > "$TMP/pkg/usr/share/doc/test/README"
  if dpkg-deb --build "$TMP/pkg" "$TMP/test.deb" >/dev/null 2>&1; then
    verify_deb "$TMP/test.deb" "1.2.3" && ok "完整 deb 通过校验" || bad "完整 deb 应通过"
    verify_deb "$TMP/test.deb" "9.9.9" && bad "版本不符应被拒" || ok "版本不符被拒"
    head -c $(( $(stat -c %s "$TMP/test.deb") / 2 )) "$TMP/test.deb" > "$TMP/trunc.deb"
    verify_deb "$TMP/trunc.deb" "1.2.3" && bad "截断 deb 应被拒" || ok "截断 deb 被拒"
  else
    printf '  skip 无法构建测试 deb\n'
  fi
else
  printf '  skip 无 dpkg-deb\n'
fi

# ---------------------------------------------------------------- 回滚还原

section "回滚还原数据库（防 schema 迁移锁死旧版）"
mkdir -p "$TMP/bk2" "$TMP/data2"
printf 'old-db\n'   > "$TMP/bk2/database.sqlite.pre-upgrade-20260101-000000"
printf 'old-prefs\n' > "$TMP/bk2/shared_preferences.json.pre-upgrade-20260101-000000"
printf 'new-db\n'   > "$TMP/data2/database.sqlite"
printf 'new-prefs\n' > "$TMP/data2/shared_preferences.json"
printf '20260101-000000\n' > "$TMP/state/prev_ts"
( BACKUP_DIR="$TMP/bk2"; DATA_DIR="$TMP/data2"; restore_pre_upgrade_state ) >/dev/null 2>&1
assert_eq "$(cat "$TMP/data2/database.sqlite")" "old-db" "回滚时还原 database.sqlite"
assert_eq "$(cat "$TMP/data2/shared_preferences.json")" "old-prefs" "回滚时还原 shared_preferences.json"

printf 'newer-db\n' > "$TMP/data2/database.sqlite"
rm -f "$TMP/state/prev_ts"
( BACKUP_DIR="$TMP/bk2"; DATA_DIR="$TMP/data2"; restore_pre_upgrade_state ) >/dev/null 2>&1
assert_eq "$(cat "$TMP/data2/database.sqlite")" "newer-db" "无 prev_ts 时不动数据库"

printf '20260101-000000\n' > "$TMP/state/prev_ts"
rm -f "$TMP/bk2/database.sqlite.pre-upgrade-20260101-000000" "$TMP/bk2/shared_preferences.json.pre-upgrade-20260101-000000"
printf 'keep-db\n' > "$TMP/data2/database.sqlite"
( BACKUP_DIR="$TMP/bk2"; DATA_DIR="$TMP/data2"; restore_pre_upgrade_state ) >/dev/null 2>&1
assert_eq "$(cat "$TMP/data2/database.sqlite")" "keep-db" "快照缺失时不破坏现有数据库"

# ---------------------------------------------------------------- 其他

section "其他"
assert_eq "$(json_escape 'a"b\c')" 'a\"b\\c' "json_escape 转义引号与反斜杠"
assert_eq "$(proxy_port)" "7890" "proxy_port 解析默认端口"

printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
