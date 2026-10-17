#!/usr/bin/env bash
# lib/common.sh — 配置加载、日志、锁、健康检查、依赖校验
#
# 本文件只定义函数与常量；source 时不产生副作用。

# 配置项在这里定义、在其它 lib 里使用，属于跨文件共享变量
# shellcheck disable=SC2034

FLCLASH_AUTO_VERSION="1.0.0"

# ---------------------------------------------------------------- 配置

config_file_path() {
  if [ -n "${FLCLASH_AUTO_CONF:-}" ]; then
    printf '%s' "$FLCLASH_AUTO_CONF"
    return 0
  fi
  printf '%s/flclash-auto/config.conf' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

declare -A FLCLASH_CONF=()

# 解析配置文件（而不是 shell source：配置项不应能执行任意代码）
conf_load() {
  local file line key val lineno=0
  file="$(config_file_path)"
  FLCLASH_CONF=()
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      *=*) ;;
      *)
        printf '配置错误 %s:%d 不是 KEY=VALUE: %s\n' "$file" "$lineno" "$line" >&2
        return 2
        ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    key="${key//[[:space:]]/}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    FLCLASH_CONF["$key"]="$val"
  done < "$file"
  return 0
}

# 优先级：环境变量 > 配置文件 > 默认值
config_get() {
  local key="$1" dflt="${2-}"
  if [ -n "${!key-}" ]; then
    printf '%s' "${!key}"
  elif [ -n "${FLCLASH_CONF[$key]-}" ]; then
    printf '%s' "${FLCLASH_CONF[$key]}"
  else
    printf '%s' "$dflt"
  fi
}

config_load() {
  local rc=0
  conf_load || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  CONTAINER="$(config_get CONTAINER flclash-docker)"
  DATA_DIR="$(config_get DATA_DIR "$HOME/flclash-docker/flclash")"
  STATE_DIR="$(config_get STATE_DIR "$HOME/flclash-docker/state")"
  BACKUP_DIR="$(config_get BACKUP_DIR "$HOME/flclash-docker/backup")"
  LOG_FILE="$(config_get LOG_FILE "$STATE_DIR/watchdog.log")"
  LOG_MAX_BYTES="$(config_get LOG_MAX_BYTES 1048576)"
  LOG_KEEP_LINES="$(config_get LOG_KEEP_LINES 2000)"
  PROFILE_ID="$(config_get PROFILE_ID "")"
  PROXY="$(config_get PROXY "http://127.0.0.1:7890")"
  HEALTH_URL="$(config_get HEALTH_URL "https://www.google.com/generate_204")"
  HEALTH_FAIL_THRESHOLD="$(config_get HEALTH_FAIL_THRESHOLD 2)"
  SUB_REFRESH_INTERVAL="$(config_get SUB_REFRESH_INTERVAL 21600)"
  SUB_UA_TEMPLATE="$(config_get SUB_UA_TEMPLATE 'FlClash/{version}')"
  REGION_FILTER="$(config_get REGION_FILTER '新加坡|香港|日本|台湾|Singapore|Hong Kong|Japan|Taiwan|SG|HK|JP|TW')"
  TEST_URL="$(config_get TEST_URL 'http://www.gstatic.com/generate_204')"
  URLTEST_INTERVAL="$(config_get URLTEST_INTERVAL 300)"
  URLTEST_TOLERANCE="$(config_get URLTEST_TOLERANCE 50)"
  SKIP_GROUP_KEYWORDS="$(config_get SKIP_GROUP_KEYWORDS '公告|通知|提醒|说明|使用|剩余|到期|流量|时间|官网|脚本|更新')"
  UPGRADE_ENABLED="$(config_get UPGRADE_ENABLED 1)"
  UPGRADE_WAIT_DAYS="$(config_get UPGRADE_WAIT_DAYS 7)"
  UPGRADE_WINDOW="$(config_get UPGRADE_WINDOW '03:00-05:00')"
  WAIT_HEALTHY_TRIES="$(config_get WAIT_HEALTHY_TRIES 14)"
  WAIT_HEALTHY_SLEEP="$(config_get WAIT_HEALTHY_SLEEP 5)"
  GH_REPO="$(config_get GH_REPO 'chen08209/FlClash')"
  KEEP_IMAGES="$(config_get KEEP_IMAGES 2)"
  GH_API="https://api.github.com/repos/$GH_REPO/releases/latest"

  mkdir -p "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
  return 0
}

# PROFILE_ID 留空时自动探测：shared_preferences.json 的 currentProfileId → 唯一 profile
resolve_profile_id() {
  [ -n "${PROFILE_ID:-}" ] && return 0
  local prefs="$DATA_DIR/shared_preferences.json" id="" ids=""

  if [ -f "$prefs" ]; then
    id="$(python3 - "$prefs" <<'PY' 2>/dev/null || true
import json, sys

def find(o):
    if isinstance(o, dict):
        v = o.get("currentProfileId")
        if isinstance(v, int):
            return v
        for x in o.values():
            r = find(x)
            if r is not None:
                return r
    elif isinstance(o, list):
        for x in o:
            r = find(x)
            if r is not None:
                return r
    elif isinstance(o, str):
        s = o.strip()
        if s.startswith("{") or s.startswith("["):
            try:
                return find(json.loads(s))
            except Exception:
                return None
    return None

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
v = find(data)
if v is not None:
    sys.stdout.write(str(v))
PY
)"
  fi

  if [ -z "$id" ]; then
    ids="$(sqlite3 "$DATA_DIR/database.sqlite" 'select id from profiles;' 2>/dev/null || true)"
    if [ "$(printf '%s\n' "$ids" | grep -c .)" = "1" ]; then
      id="$ids"
    fi
  fi

  if [ -z "$id" ]; then
    printf '无法自动确定 PROFILE_ID（请检查 shared_preferences.json 或在配置里显式指定）\n' >&2
    return 1
  fi
  PROFILE_ID="$id"
  return 0
}

require_commands() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf '缺少依赖命令: %s\n' "${missing[*]}" >&2
    return 1
  fi
  return 0
}

require_yaml() {
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    printf '缺少 python3-yaml，请安装: sudo apt install python3-yaml\n' >&2
    return 1
  fi
  return 0
}

config_validate() {
  local rc=0
  require_commands docker curl sqlite3 python3 ss awk sed grep mktemp stat md5sum || rc=1
  require_yaml || rc=1
  if [ ! -d "$DATA_DIR" ]; then
    printf 'DATA_DIR 不存在: %s\n' "$DATA_DIR" >&2
    rc=1
  fi
  if [ ! -f "$DATA_DIR/database.sqlite" ]; then
    printf '找不到 FlClash 数据库: %s/database.sqlite\n' "$DATA_DIR" >&2
    rc=1
  fi
  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    printf '容器不存在: %s\n' "$CONTAINER" >&2
    rc=1
  fi
  return "$rc"
}

# ---------------------------------------------------------------- 日志

say() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

log() {
  local line dir
  line="[$(date '+%F %T')] $*"
  [ -n "${LOG_FILE:-}" ] || return 0
  dir="$(dirname "$LOG_FILE")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
}

rotate_log() {
  local f="${LOG_FILE:-}" sz
  [ -n "$f" ] && [ -f "$f" ] || return 0
  sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  [ "$sz" -gt "${LOG_MAX_BYTES:-1048576}" ] || return 0
  tail -n "${LOG_KEEP_LINES:-2000}" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
}

# 状态没变就不重复写日志（cron 每小时跑，避免刷屏）
note_update() {
  local f="${STATE_DIR:?}/last_update_note"
  [ "$(cat "$f" 2>/dev/null)" = "$1" ] && return 0
  printf '%s\n' "$1" > "$f" 2>/dev/null || true
  log "UPDATE: $1"
}

# ---------------------------------------------------------------- 锁

lock_active() {
  local dir="${STATE_DIR:?}/upgrade.lock" age
  [ -d "$dir" ] || return 1
  age=$(( $(date +%s) - $(stat -c %Y "$dir" 2>/dev/null || echo 0) ))
  [ "$age" -lt 1800 ]
}

# 成功返回 0 并置 LOCK_HELD；失败返回 1（已有流程在跑）
lock_acquire() {
  local dir="${STATE_DIR:?}/upgrade.lock" age
  if mkdir "$dir" 2>/dev/null; then
    LOCK_HELD=1
    return 0
  fi
  age=$(( $(date +%s) - $(stat -c %Y "$dir" 2>/dev/null || echo 0) ))
  if [ "$age" -gt 1800 ]; then
    log "WARN: 发现残留升级锁（${age}s），判定为异常退出遗留，接管"
    rmdir "$dir" 2>/dev/null || return 1
    mkdir "$dir" 2>/dev/null || return 1
    LOCK_HELD=1
    return 0
  fi
  return 1
}

lock_release() {
  [ -n "${LOCK_HELD:-}" ] || return 0
  rmdir "${STATE_DIR:?}/upgrade.lock" 2>/dev/null || true
  LOCK_HELD=""
}

# ---------------------------------------------------------------- 健康检查

proxy_port() {
  local p="${PROXY##*:}"
  printf '%s' "${p//[!0-9]/}"
}

core_up() {
  [ -n "$(proxy_port)" ] || return 1
  ss -tln 2>/dev/null | grep -q ":$(proxy_port) "
}

health_ok() {
  local code
  code="$(curl -s -m 15 -x "$PROXY" -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || true)"
  [ "$code" = "204" ] || [ "$code" = "200" ]
}

installed_version() {
  local v
  v="$(docker exec "$CONTAINER" dpkg -l 2>/dev/null | awk '/^ii +flclash/{print $3; exit}')" || true
  printf '%s' "${v%%+*}"
}

# 等核心起来并实测出网（冷启实测 35~50s）。
# 次数/间隔由 WAIT_HEALTHY_TRIES / WAIT_HEALTHY_SLEEP 控制（测试里会调小）。
wait_healthy() {
  local n="${WAIT_HEALTHY_TRIES:-14}" i
  for ((i = 1; i <= n; i++)); do
    sleep "${WAIT_HEALTHY_SLEEP:-5}"
    if core_up && health_ok; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- 杂项

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

die() {
  printf '错误: %s\n' "$*" >&2
  exit 2
}

# ---------------------------------------------------------------- 自检

selftest() {
  local rc=0 c
  for c in docker curl sqlite3 python3 ss awk sed grep mktemp stat md5sum dpkg-deb; do
    if command -v "$c" >/dev/null 2>&1; then
      say "  ok   $c"
    else
      say "  MISS $c"
      rc=1
    fi
  done
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    say "  ok   python3-yaml"
  else
    say "  MISS python3-yaml（sudo apt install python3-yaml）"
    rc=1
  fi
  if [ -d "$DATA_DIR" ]; then say "  ok   DATA_DIR $DATA_DIR"; else say "  MISS DATA_DIR $DATA_DIR"; rc=1; fi
  if [ -f "$DATA_DIR/database.sqlite" ]; then
    say "  ok   database.sqlite"
    if sqlite3 "$DATA_DIR/database.sqlite" 'select url from profiles limit 1;' >/dev/null 2>&1; then
      say "  ok   profiles.url 可读"
    else
      say "  MISS profiles.url（上游 schema 可能已变）"
      rc=1
    fi
  else
    say "  MISS database.sqlite"
    rc=1
  fi
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    say "  ok   容器 $CONTAINER 存在"
    if [ -n "$(installed_version)" ]; then
      say "  ok   FlClash $(installed_version)"
    else
      say "  MISS FlClash 版本（容器未运行？）"
      rc=1
    fi
  else
    say "  MISS 容器 $CONTAINER"
    rc=1
  fi
  if mkdir -p "$STATE_DIR" 2>/dev/null && : > "$STATE_DIR/.write-test" 2>/dev/null; then
    rm -f "$STATE_DIR/.write-test"
    say "  ok   STATE_DIR 可写 $STATE_DIR"
  else
    say "  MISS STATE_DIR 不可写 $STATE_DIR"
    rc=1
  fi
  if [ -n "${PROFILE_ID:-}" ]; then
    say "  ok   PROFILE_ID=$PROFILE_ID"
  else
    say "  MISS PROFILE_ID 未解析"
    rc=1
  fi
  return "$rc"
}

# ---------------------------------------------------------------- cron
#
# 用行尾标记识别"本工具托管的条目"：/bin/sh 会把 # 之后当注释，cron 语法上安全。
# 这样只增删自己的条目，不会误删用户其它 cron（例如旧版单文件脚本）。

CRON_MARK="# flclash-auto-managed"

install_cron() {
  local bin="${FLCLASH_AUTO_BIN:-${ROOT_DIR:-.}/bin/flclash-auto}" cur
  cur="$(crontab -l 2>/dev/null | grep -vF "$CRON_MARK" || true)"
  {
    [ -n "$cur" ] && printf '%s\n' "$cur"
    printf '*/5 * * * * %s --check >/dev/null 2>&1 %s\n' "$bin" "$CRON_MARK"
    printf '23 * * * * %s --check-update >/dev/null 2>&1 %s\n' "$bin" "$CRON_MARK"
  } | crontab -
  say "已安装 cron：每 5 分钟巡检、每小时版本检查（$bin）"
  crontab -l 2>/dev/null | grep -F "$CRON_MARK" || true
}

uninstall_cron() {
  local cur
  cur="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$cur" | grep -vF "$CRON_MARK" | crontab -
  say "已移除 flclash-auto 托管的 cron 条目"
}
