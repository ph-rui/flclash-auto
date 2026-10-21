#!/usr/bin/env bash
# lib/subscription.sh — 订阅下载、分组改写（select -> url-test）、应用并重启

profile_path() {
  printf '%s/profiles/%s.yaml' "$DATA_DIR" "$PROFILE_ID"
}

sub_url() {
  sqlite3 "$DATA_DIR/database.sqlite" \
    "select url from profiles where id=$PROFILE_ID;" 2>/dev/null | head -1
}

# 订阅地址等同凭据：状态输出里只保留域名与末 4 位，避免截图/贴日志泄露
mask_url() {
  printf '%s' "$1" | sed -E 's#^(https?://[^/]+/).*([A-Za-z0-9]{4})$#\1…\2#'
}

# 部分机场按 UA 下发不同内容，默认沿用 FlClash 的 UA
sub_ua() {
  local v
  v="$(installed_version)"
  [ -n "$v" ] || v="unknown"
  printf '%s' "${SUB_UA_TEMPLATE//\{version\}/$v}"
}

# 下载订阅到指定文件；只做结构级校验（大小 / 含 proxies 关键字）
fetch_subscription() {
  local url="$1" ua="$2" out="$3" sz
  curl -fsSL --connect-timeout 10 -m 60 -A "$ua" -o "$out" "$url" 2>/dev/null || return 1
  [ -s "$out" ] || return 1
  sz="$(wc -c < "$out")"
  [ "$sz" -gt 2000 ] || return 1
  grep -qE '^[[:space:]]*proxies[[:space:]]*:' "$out" || return 1
  return 0
}

# 把 profile 里的 select 分组改写成 url-test（原地）。
# 成功且至少改写了一个分组：stdout = 逗号分隔的分组名，返回 0
# 解析成功但没有可改写分组：stdout 为空，返回 0
# 硬错误（缺 PyYAML / YAML 非法 / 结构不符）：stderr 说明原因，返回 1
transform_profile() {
  local file="$1"
  python3 - "$file" "$REGION_FILTER" "$URLTEST_INTERVAL" "$URLTEST_TOLERANCE" \
    "$TEST_URL" "$SKIP_GROUP_KEYWORDS" <<'PY'
import os
import re
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.stderr.write("缺少 python3-yaml，请安装: sudo apt install python3-yaml\n")
    sys.exit(1)

path, region, interval, tol, testurl, skip = sys.argv[1:7]
try:
    interval = int(interval)
except ValueError:
    interval = 300
try:
    tol = int(tol)
except ValueError:
    tol = 50
skip_kw = [k for k in skip.split("|") if k]

try:
    region_re = re.compile(region)
except re.error as exc:
    sys.stderr.write("REGION_FILTER 不是合法正则: %s\n" % exc)
    sys.exit(1)

try:
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
except Exception as exc:
    sys.stderr.write("YAML 解析失败: %s\n" % exc)
    sys.exit(1)

if not isinstance(data, dict):
    sys.stderr.write("profile 顶层不是映射\n")
    sys.exit(1)

proxies = data.get("proxies") or []
if not isinstance(proxies, list):
    sys.stderr.write("proxies 不是列表\n")
    sys.exit(1)

nodes = set()
node_order = []
for item in proxies:
    if isinstance(item, dict) and isinstance(item.get("name"), str):
        if item["name"] not in nodes:
            node_order.append(item["name"])
        nodes.add(item["name"])
if not nodes:
    sys.stderr.write("proxies 为空，无法判断分组成员（拒绝改写）\n")
    sys.exit(1)

groups = data.get("proxy-groups") or []
if not isinstance(groups, list):
    sys.stderr.write("proxy-groups 不是列表\n")
    sys.exit(1)

changed = []
for group in groups:
    if not isinstance(group, dict):
        continue
    if group.get("type") != "select":
        continue
    name = group.get("name") or ""
    if any(kw in name for kw in skip_kw):
        continue
    # 使用 proxy-provider 的分组不在本次改写范围
    if group.get("use"):
        continue
    members = group.get("proxies")
    if group.get("include-all") is True:
        members = list(node_order)
    if not isinstance(members, list) or len(members) < 2:
        continue
    # 只要有一个成员不是本 profile 的节点（即引用了别的分组），就不改这条
    if any(m not in nodes for m in members):
        continue

    # mihomo 的 filter 只对 proxy-provider / include-all-proxies 生效，
    # 对显式 proxies 列表无效。这里直接把成员过滤到目标区域，
    # 保证 url-test 不会因为区域外节点延迟更低而选到它。
    regional = [m for m in members if region_re.search(m)]
    if len(regional) < 2:
        continue
    group["proxies"] = regional
    group.pop("include-all", None)

    group["type"] = "url-test"
    group["url"] = testurl
    group["interval"] = interval
    group["tolerance"] = tol
    group["lazy"] = False
    group["filter"] = region
    changed.append(name)

if not changed:
    sys.exit(0)

out = yaml.safe_dump(
    data, allow_unicode=True, sort_keys=False,
    default_flow_style=False, width=4096,
)
directory = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(prefix=".flclash-auto.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(out)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise

sys.stdout.write(",".join(changed))
PY
}

# 改写是否还在（被 UI 手动"更新"过就会退回 select）。
# 用 PyYAML 做语义判断：真实订阅多为行内 flow 风格（url-test 不在行尾），
# 正则判断在 block/flow 两种写法下都容易误判。
transform_present() {
  python3 - "$(profile_path)" <<'PY' 2>/dev/null
import sys

try:
    import yaml
except ImportError:
    sys.exit(2)

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = yaml.safe_load(f)
except Exception:
    sys.exit(2)

if not isinstance(data, dict):
    sys.exit(2)

for group in data.get("proxy-groups") or []:
    if isinstance(group, dict) and group.get("type") == "url-test":
        sys.exit(0)
sys.exit(1)
PY
}

# 应用新 profile：备份 -> 改写 -> 更新 DB -> 重启 -> 验证。
# 返回 0 成功；2 应用后不健康但已恢复到旧 profile；3 无可改写分组（未应用）；1 失败
apply_profile() {
  local newfile="$1" reason="$2" raw="${3:-}"
  local prof prev changed rc=0 now

  prof="$(profile_path)"
  prev="$STATE_DIR/profile.$PROFILE_ID.yaml.prev"
  cp -a "$prof" "$prev" 2>/dev/null || true

  cp "$newfile" "$prof" || return 1

  if [ "$raw" = "--raw" ]; then
    log "WARN: $reason 按原样应用（未改写为 url-test，自动择优将不可用）"
  else
    changed="$(transform_profile "$prof")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      [ -f "$prev" ] && cp -a "$prev" "$prof" 2>/dev/null
      log "ERROR: $reason 失败：profile 改写错误，已保留旧 profile"
      return 1
    fi
    if [ -z "$changed" ]; then
      [ -f "$prev" ] && cp -a "$prev" "$prof" 2>/dev/null
      log "ERROR: $reason 失败：订阅里没有可改写的 select 分组（机场格式可能变了），已保留旧 profile"
      log "     可先用 --apply-raw 保住连通，再调整 SKIP_GROUP_KEYWORDS/检查机场格式"
      return 3
    fi
    log "OK: $reason 分组改为 url-test: $changed"
  fi

  now="$(date +%s%3N)"
  sqlite3 "$DATA_DIR/database.sqlite" \
    "update profiles set last_update_date=$now, auto_update=0 where id=$PROFILE_ID;" 2>/dev/null || true

  docker restart "$CONTAINER" >/dev/null 2>&1
  if wait_healthy; then
    log "OK: $reason 应用后健康验证通过"
    return 0
  fi

  log "ERROR: $reason 应用后未能出网，恢复应用前的 profile"
  if [ -f "$prev" ]; then
    cp -a "$prev" "$prof" 2>/dev/null
    docker restart "$CONTAINER" >/dev/null 2>&1
    if wait_healthy; then
      log "OK: 已恢复到应用前的 profile，并验证出网正常"
      return 2
    fi
  fi
  log "ERROR: 恢复旧 profile 后仍不健康，需人工检查：docker logs $CONTAINER"
  return 1
}

# 手动强制刷新（--force / --apply-raw）
force_refresh() {
  local raw="${1:-}" url ua tmp rc
  rotate_log
  url="$(sub_url)"
  ua="$(sub_ua)"
  if [ -z "$url" ]; then
    say "读不到订阅地址（profiles.url 为空）"
    return 2
  fi
  tmp="$STATE_DIR/tmp.sub.$$"
  if ! fetch_subscription "$url" "$ua" "$tmp"; then
    say "订阅下载失败（网络或机场故障）"
    rm -f "$tmp"
    return 1
  fi
  apply_profile "$tmp" "手动强制" "$raw"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    md5sum "$tmp" | awk '{print $1}' > "$STATE_DIR/sub_hash"
    date +%s > "$STATE_DIR/last_sub_sync"
    say "强制更新完成"
  else
    say "强制更新未完全成功（rc=$rc），详见 $LOG_FILE"
  fi
  rm -f "$tmp"
  return "$rc"
}
