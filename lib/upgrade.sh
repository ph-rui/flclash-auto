#!/usr/bin/env bash
# lib/upgrade.sh — 版本发现、灰度门限、安装、固化、回滚

# in_window/do_upgrade 的参数是"可选覆盖值"，正常调用不传参，属有意设计
# shellcheck disable=SC2119,SC2120

# $1 是否比 $2 新（语义化版本，用 sort -V）
ver_newer_than() {
  local hi
  hi="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)"
  [ "$1" = "$hi" ] && [ "$1" != "$2" ]
}

# 是否处于维护窗口，支持跨零点。可选 $1 = "HH:MM"（便于测试）
in_window() {
  local s e ss ee now hh mm
  s="${UPGRADE_WINDOW%-*}"
  e="${UPGRADE_WINDOW#*-}"
  ss=$(( 10#${s%:*} * 60 + 10#${s#*:} ))
  ee=$(( 10#${e%:*} * 60 + 10#${e#*:} ))
  if [ -n "${1:-}" ]; then
    hh="${1%:*}"
    mm="${1#*:}"
  else
    hh="$(date +%H)"
    mm="$(date +%M)"
  fi
  now=$(( 10#$hh * 60 + 10#$mm ))
  if [ "$ss" -le "$ee" ]; then
    [ "$now" -ge "$ss" ] && [ "$now" -le "$ee" ]
  else
    [ "$now" -ge "$ss" ] || [ "$now" -le "$ee" ]
  fi
}

# 取 GitHub 最新 release：输出 "版本<TAB>发布epoch<TAB>deb地址"
latest_release() {
  local json=""
  json="$(curl -fsS -m 25 -H 'Accept: application/vnd.github+json' "$GH_API" 2>/dev/null || true)"
  if ! printf '%s' "$json" | grep -q '"tag_name"'; then
    json="$(curl -fsS -m 25 -x "$PROXY" -H 'Accept: application/vnd.github+json' "$GH_API" 2>/dev/null || true)"
  fi
  printf '%s' "$json" | python3 -c '
import datetime
import json
import re
import sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)

tag = (d.get("tag_name") or "").lstrip("v")
pub = d.get("published_at") or ""
try:
    ep = int(datetime.datetime.strptime(pub, "%Y-%m-%dT%H:%M:%SZ")
             .replace(tzinfo=datetime.timezone.utc).timestamp())
except Exception:
    ep = 0

url = ""
names = [(a.get("name") or "", a.get("browser_download_url") or "")
         for a in d.get("assets", [])]
for pat in (r"linux-amd64\.deb$", r"amd64\.deb$", r"x86_64.*\.deb$"):
    for name, link in names:
        if re.search(pat, name):
            url = link
            break
    if url:
        break

if not (tag and url and ep):
    sys.exit(1)
sys.stdout.write("%s\t%d\t%s" % (tag, ep, url))
'
}

# deb 完整性校验。dpkg-deb -f 只读文件头，截断文件会误判通过；
# 必须用 dpkg-deb -c 强制解压 data.tar 才能识别，再校验版本与期望一致。
verify_deb() {
  local f="$1" want="$2" v
  [ -s "$f" ] || return 1
  dpkg-deb -c "$f" >/dev/null 2>&1 || return 1
  v="$(dpkg-deb -f "$f" Version 2>/dev/null)" || return 1
  [ "${v%%+*}" = "$want" ] || return 1
  return 0
}

# 从运行中的容器精确捕获 docker run 参数（升级/回滚重建容器用）。
# 覆盖：name/network/user/privileged/cap-add/device/binds/env 差异/restart。
# 未覆盖 add-host、dns、sysctl、ulimit、shm-size、publish —— 本工具不生成这些参数；
# 若手工加过，请先 --save-run-args 并人工核对，否则重建会丢参数。
capture_run_args() {
  local img img_env c h p perm b e rn mr out
  img="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"
  img_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$img" 2>/dev/null | sort -u || true)"
  out="$STATE_DIR/run-args.tmp"
  {
    echo "RUN_ARGS=("
    printf '  "-d"\n'
    printf '  "--name"\n  "%s"\n' "$CONTAINER"
    printf '  "--network"\n  "%s"\n' "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$CONTAINER" 2>/dev/null)"
    printf '  "--user"\n  "%s"\n' "$(docker inspect --format '{{.Config.User}}' "$CONTAINER" 2>/dev/null)"
    if [ "$(docker inspect --format '{{.HostConfig.Privileged}}' "$CONTAINER" 2>/dev/null)" = "true" ]; then
      printf '  "--privileged"\n'
    fi
    for c in $(docker inspect --format '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null); do
      printf '  "--cap-add"\n  "%s"\n' "$c"
    done
    docker inspect --format '{{range .HostConfig.Devices}}{{.PathOnHost}}:{{.PathInContainer}}:{{.CgroupPermissions}}{{println}}{{end}}' "$CONTAINER" 2>/dev/null |
      while IFS=: read -r h p perm; do
        [ -n "$h" ] && printf '  "--device"\n  "%s:%s:%s"\n' "$h" "$p" "${perm:-rwm}"
      done
    docker inspect --format '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null |
      while IFS= read -r b; do
        [ -n "$b" ] && printf '  "-v"\n  "%s"\n' "$b"
      done
    if [ -n "$img_env" ]; then
      # 只搬运"当初 -e 传进去的"差异项，不把镜像默认值钉死
      comm -13 <(printf '%s\n' "$img_env") \
        <(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null | sort -u) |
        while IFS= read -r e; do
          [ -n "$e" ] && printf '  "-e"\n  "%s"\n' "$e"
        done
    else
      docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null |
        while IFS= read -r e; do
          [ -n "$e" ] && printf '  "-e"\n  "%s"\n' "$e"
        done
    fi
    rn="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER" 2>/dev/null || true)"
    mr="$(docker inspect --format '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "$CONTAINER" 2>/dev/null || true)"
    case "$rn" in
      always|unless-stopped) printf '  "--restart"\n  "%s"\n' "$rn" ;;
      on-failure) printf '  "--restart"\n  "on-failure:%s"\n' "${mr:-10}" ;;
      *) printf '  "--restart"\n  "no"\n' ;;
    esac
    echo ")"
  } > "$out" 2>/dev/null || { rm -f "$out"; return 1; }
  mv "$out" "$STATE_DIR/run-args"
}

# 用指定镜像重建容器（配置在宿主卷上，重建不丢数据）
recreate_container() {
  local image="$1"
  [ -s "$STATE_DIR/run-args" ] || capture_run_args || { log "ERROR: 无法捕获 run 参数"; return 1; }
  # shellcheck disable=SC1090,SC1091
  source "$STATE_DIR/run-args" || { log "ERROR: run 参数文件损坏"; return 1; }
  [ -n "${RUN_ARGS[*]:-}" ] || { log "ERROR: run 参数为空"; return 1; }
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  docker run "${RUN_ARGS[@]}" "$image" >/dev/null 2>&1
}

mark_bad() {
  [ -n "${1:-}" ] || return 0
  printf '%s\n' "$1" > "$STATE_DIR/upgrade_blocked"
  log "INFO: 已将 v$1 标记为坏版本，暂停对其自动升级（人工 --upgrade --force 可覆盖）"
}

do_rollback() {
  local prev
  prev="$(cat "$STATE_DIR/prev_image" 2>/dev/null || true)"
  if [ -z "$prev" ]; then
    log "ERROR: 没有回滚镜像记录（state/prev_image），需人工介入"
    return 1
  fi
  log "INFO: 执行回滚 -> $prev"
  recreate_container "$prev" || { log "ERROR: 回滚重建容器失败，需人工介入"; return 1; }
  if wait_healthy; then
    log "OK: 回滚成功，已恢复到 $prev 并验证出网正常"
    return 0
  fi
  log "ERROR: 回滚后仍不健康！需人工检查：docker logs $CONTAINER"
  return 1
}

do_upgrade() {
  local force=0 dry=0 a
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      --dry-run) dry=1 ;;
      *) die "未知的 --upgrade 参数: $a" ;;
    esac
  done
  [ "$dry" = "1" ] || rotate_log

  local info tag pub deb cur new prev_image ts debfile pkg try got=0 days blocked upgraded_today
  info="$(latest_release)" || { log "ERROR: 取不到 GitHub release（api.github.com 不可达），放弃"; return 1; }
  tag="$(printf '%s' "$info" | cut -f1)"
  pub="$(printf '%s' "$info" | cut -f2)"
  deb="$(printf '%s' "$info" | cut -f3)"
  cur="$(installed_version)"
  if [ -z "$tag" ] || [ -z "$deb" ]; then
    log "ERROR: release 信息不完整，放弃"
    return 1
  fi
  if [ -z "$cur" ]; then
    log "ERROR: 读不到当前版本（容器未运行？），放弃"
    return 1
  fi

  days=$(( ( $(date +%s) - pub ) / 86400 ))
  blocked="$(cat "$STATE_DIR/upgrade_blocked" 2>/dev/null || true)"
  upgraded_today=false
  if [ "$(cat "$STATE_DIR/last_upgrade" 2>/dev/null || true)" = "$(date +%F)" ]; then
    upgraded_today=true
  fi

  if [ "$dry" = 1 ]; then
    say "[dry-run] 当前 $cur -> 候选 $tag（发布 ${days} 天）"
    if ver_newer_than "$tag" "$cur"; then say "[dry-run] 版本: 有更新"; else say "[dry-run] 版本: 已是最新（真跑会直接退出）"; fi
    say "[dry-run] 观察期: ${days}/${UPGRADE_WAIT_DAYS} 天（只约束自动升级，手动 --upgrade 不受限）"
    if in_window; then
      say "[dry-run] 维护窗口 $UPGRADE_WINDOW: 当前在窗口内"
    else
      say "[dry-run] 维护窗口 $UPGRADE_WINDOW: 当前在窗口外（自动升级会等待）"
    fi
    if [ "$upgraded_today" = true ]; then
      say "[dry-run] 今日已升级过: 是（真跑会跳过）"
    else
      say "[dry-run] 今日已升级过: 否"
    fi
    if [ "$blocked" = "$tag" ]; then
      say "[dry-run] 该版本已被标记为坏版本（自动升级会跳过；--force 可覆盖）"
    fi
    if health_ok; then
      say "[dry-run] 当前健康: 正常"
    else
      say "[dry-run] 当前健康: 异常（真跑会拒绝，除非 --force）"
    fi

    debfile="/tmp/FlClash-$tag-linux-amd64.deb"
    rm -f "$debfile"
    say "[dry-run] 下载并校验 deb ..."
    if curl -fsL --connect-timeout 8 -m 90 -o "$debfile" "$deb" 2>/dev/null && verify_deb "$debfile" "$tag"; then
      say "[dry-run] deb 直连下载并校验通过（$(du -h "$debfile" | cut -f1)）"
    elif curl -fsL --connect-timeout 8 -m 600 -x "$PROXY" -o "$debfile" "$deb" 2>/dev/null && verify_deb "$debfile" "$tag"; then
      say "[dry-run] deb 经代理下载并校验通过（$(du -h "$debfile" | cut -f1)）"
    else
      say "[dry-run] deb 下载或校验失败（真跑会中止，不改动任何东西）"
      rm -f "$debfile"
      return 1
    fi
    rm -f "$debfile"
    say "[dry-run] 真跑将执行：备份配置 -> 停应用 -> dpkg -i -> 重启 -> 健康验证 -> docker commit flclash:$tag -> 用新镜像重建 -> 再验证；任一步失败自动回滚到 $(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || echo 旧镜像)"
    return 0
  fi

  if [ "$force" = 1 ]; then
    rm -f "$STATE_DIR/upgrade_blocked"
    log "INFO: --force：跳过版本新旧/每日一次/坏版本/健康 四项门限"
  else
    if ! ver_newer_than "$tag" "$cur"; then log "INFO: 当前 $cur 已是最新，无需升级"; return 0; fi
    if [ "$blocked" = "$tag" ]; then log "INFO: v$tag 已被标记为坏版本，跳过（人工 --upgrade --force 可覆盖）"; return 0; fi
    if [ "$upgraded_today" = true ]; then log "INFO: 今天已升级过一次，跳过"; return 0; fi
    if ! health_ok; then
      log "ERROR: 当前代理不健康，拒绝升级（先让 --check 自愈，或 --force）"
      return 1
    fi
  fi

  if ! lock_acquire; then
    log "WARN: 已有升级流程在运行（$STATE_DIR/upgrade.lock），本轮跳过"
    return 1
  fi
  trap 'lock_release' EXIT

  prev_image="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"
  printf '%s\n' "$prev_image" > "$STATE_DIR/prev_image"
  capture_run_args || log "WARN: run 参数捕获可能有缺，请核对 $STATE_DIR/run-args"

  mkdir -p "$BACKUP_DIR"
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$DATA_DIR/database.sqlite" "$BACKUP_DIR/database.sqlite.pre-upgrade-$ts" 2>/dev/null || true
  cp -a "$DATA_DIR/shared_preferences.json" "$BACKUP_DIR/shared_preferences.json.pre-upgrade-$ts" 2>/dev/null || true
  cp -a "$(profile_path)" "$STATE_DIR/profile.$PROFILE_ID.yaml.pre-upgrade-$ts" 2>/dev/null || true
  log "INFO: 开始升级 FlClash $cur -> $tag（回滚镜像: ${prev_image:-无}，配置已备份）"

  # 下载：直连快速失败 -> 代理；最多 3 轮，每轮都做完整性校验
  debfile="/tmp/FlClash-$tag-linux-amd64.deb"
  for try in 1 2 3; do
    rm -f "$debfile"
    if curl -fsL --connect-timeout 8 -m 90 -o "$debfile" "$deb" 2>/dev/null && verify_deb "$debfile" "$tag"; then
      got=1
      log "INFO: deb 直连下载并校验通过（$(du -h "$debfile" | cut -f1)）"
      break
    fi
    if curl -fsL --connect-timeout 8 -m 600 -x "$PROXY" -o "$debfile" "$deb" 2>/dev/null && verify_deb "$debfile" "$tag"; then
      got=1
      log "INFO: deb 经代理下载并校验通过（$(du -h "$debfile" | cut -f1)）"
      break
    fi
    log "WARN: deb 第 $try 次下载不完整或校验失败，重试"
    sleep 3
  done
  if [ "$got" -ne 1 ]; then
    log "ERROR: deb 下载或完整性校验始终失败，未改动任何东西: $deb"
    rm -f "$debfile"
    return 1
  fi

  pkg="/tmp/$(basename "$debfile")"
  if ! docker cp "$debfile" "$CONTAINER:$pkg" >/dev/null 2>&1; then
    log "ERROR: docker cp 失败，未改动任何东西"
    rm -f "$debfile"
    return 1
  fi

  # 防御：messagebus 的 statoverride 会让包 postinst 失败（镜像里应已永久修复）
  docker exec "$CONTAINER" sh -c \
    'test -f /var/lib/dpkg/statoverride && sed -i "/dbus-daemon-launch-helper/d" /var/lib/dpkg/statoverride; true' \
    >/dev/null 2>&1

  # 先停应用：避免旧版进程在解包期间回写配置（dpkg 本身是先写 .dpkg-new 再 rename）
  docker exec "$CONTAINER" pkill -f '/opt/FlClash/FlClash' >/dev/null 2>&1 || true
  sleep 3

  if ! docker exec "$CONTAINER" dpkg -i "$pkg" >"$STATE_DIR/install-$tag.log" 2>&1; then
    log "INFO: dpkg -i 未成功（详见 $STATE_DIR/install-$tag.log），走代理补依赖后重试"
    if ! docker exec "$CONTAINER" sh -c \
      "export http_proxy=$PROXY https_proxy=$PROXY; apt-get -o Acquire::Retries=3 install -f -y >/dev/null 2>&1 && dpkg -i $pkg >/dev/null 2>&1" \
      >>"$STATE_DIR/install-$tag.log" 2>&1; then
      log "ERROR: 新版本安装失败，回滚。安装日志尾部: $(tail -3 "$STATE_DIR/install-$tag.log" 2>/dev/null | tr '\n' ' ')"
      rm -f "$debfile"
      mark_bad "$tag"
      do_rollback
      return 1
    fi
  fi
  rm -f "$debfile"
  docker exec "$CONTAINER" sh -c "rm -f $pkg" >/dev/null 2>&1 || true

  new="$(installed_version)"
  if [ "$new" != "$tag" ] && ! ver_newer_than "$new" "$cur"; then
    log "ERROR: 安装后版本不符（期望 $tag，实得 ${new:-未知}），回滚"
    mark_bad "$tag"
    do_rollback
    return 1
  fi

  docker restart "$CONTAINER" >/dev/null 2>&1
  if ! wait_healthy; then
    log "ERROR: 新版本启动后未能出网，回滚"
    mark_bad "$tag"
    do_rollback
    return 1
  fi

  # 固化进镜像：日后容器被删除重建也不会回退旧版
  if docker commit "$CONTAINER" "flclash:$tag" >/dev/null 2>&1; then
    if recreate_container "flclash:$tag" && wait_healthy; then
      date +%F > "$STATE_DIR/last_upgrade"
      rm -f "$STATE_DIR/upgrade_candidate"
      log "OK: 升级完成 FlClash $cur -> $tag，已固化为 flclash:$tag 并用其重建容器，健康验证通过"
      note_update "已升级至 v$tag"
      log "提示: 现有 flclash 镜像: $(docker images flclash --format '{{.Tag}}' 2>/dev/null | tr '\n' ' ')"
      log "提示: 保留最近 $KEEP_IMAGES 个镜像用于回滚；更旧的可用 docker rmi flclash:<tag> 手动清理（本工具不自动删除镜像）"
      return 0
    fi
    log "ERROR: 用 flclash:$tag 重建后不健康（或重建失败），回滚"
    mark_bad "$tag"
    do_rollback
    return 1
  fi

  # commit 失败时不要重建容器（当前容器已是健康的新版本，重建反而有丢容器的风险）
  date +%F > "$STATE_DIR/last_upgrade"
  rm -f "$STATE_DIR/upgrade_candidate"
  log "OK: FlClash 已升级到 $tag 并通过健康验证，但 docker commit 失败 -> 版本未固化"
  log "ERROR: 需人工固化，否则容器一旦重建会回退旧版: docker commit $CONTAINER flclash:$tag"
  note_update "已升级至 v$tag（未固化，需人工 docker commit）"
  return 0
}

# cron 每小时调用：有新版 + 观察期满 + 维护窗口 + 当前健康，才升级
do_check_update() {
  rotate_log
  if [ "$UPGRADE_ENABLED" != "1" ]; then
    note_update "自动升级已关闭（UPGRADE_ENABLED=0）"
    return 0
  fi

  local info tag pub deb cur days
  info="$(latest_release)" || { log "WARN: 版本检查失败（GitHub 不可达）"; return 1; }
  tag="$(printf '%s' "$info" | cut -f1)"
  pub="$(printf '%s' "$info" | cut -f2)"
  deb="$(printf '%s' "$info" | cut -f3)"
  cur="$(installed_version)"
  if [ -z "$cur" ]; then
    log "WARN: 读不到当前版本（容器没在跑？）"
    return 1
  fi

  if ! ver_newer_than "$tag" "$cur"; then
    rm -f "$STATE_DIR/upgrade_candidate"
    note_update "版本已最新（v$cur）"
    return 0
  fi
  if [ "$(cat "$STATE_DIR/upgrade_blocked" 2>/dev/null || true)" = "$tag" ]; then
    note_update "v$tag 已被标记为坏版本，暂停自动升级（人工确认后用 --upgrade --force）"
    return 0
  fi

  days=$(( ( $(date +%s) - pub ) / 86400 ))
  printf '%s\t%s\t%s\n' "$tag" "$pub" "$deb" > "$STATE_DIR/upgrade_candidate"

  if [ "$days" -lt "$UPGRADE_WAIT_DAYS" ]; then
    note_update "候选 v$tag（当前 v$cur）观察期 ${days}/${UPGRADE_WAIT_DAYS} 天"
    return 0
  fi
  if ! in_window; then
    note_update "候选 v$tag 观察期满（${days}天），等待维护窗口 $UPGRADE_WINDOW"
    return 0
  fi

  note_update "候选 v$tag 条件齐备（${days}天，窗口内），开始升级"
  do_upgrade
}

do_status() {
  local img status
  img="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"
  status="$(docker ps --filter "name=^${CONTAINER}$" --format '{{.Status}}' 2>/dev/null || true)"
  say "容器: ${img:-未找到} | ${status:-未运行}"
  say "FlClash: $(installed_version)"
  say "PROFILE_ID: $PROFILE_ID"
  say "订阅地址: $(mask_url "$(sub_url)")"
  say "改写生效: $(transform_present && echo yes || echo NO)"
  say "健康检查: $(health_ok && echo OK || echo FAIL)"
  say "出口: $(curl -s -m 12 -x "$PROXY" 'http://ip-api.com/json?fields=country,query,isp' 2>/dev/null || true)"
  say "日志: $LOG_FILE"
}

do_version_status() {
  local info tag pub deb cur days
  cur="$(installed_version)"
  say "当前版本: ${cur:-未知}"
  if ! info="$(latest_release)"; then
    say "GitHub: 取不到最新 release（网络或限流）"
    return 1
  fi
  tag="$(printf '%s' "$info" | cut -f1)"
  pub="$(printf '%s' "$info" | cut -f2)"
  deb="$(printf '%s' "$info" | cut -f3)"
  days=$(( ( $(date +%s) - pub ) / 86400 ))
  say "最新可见: v$tag（发布 ${days} 天）  deb: $(basename "$deb")"
  if ver_newer_than "$tag" "$cur"; then
    if [ "$UPGRADE_ENABLED" = "1" ]; then
      say "自动升级: 开（观察期 ${UPGRADE_WAIT_DAYS} 天，窗口 $UPGRADE_WINDOW）"
    else
      say "自动升级: 关"
    fi
    if [ "$(cat "$STATE_DIR/upgrade_blocked" 2>/dev/null || true)" = "$tag" ]; then
      say "  注意: 该版本已被标记为坏版本，不会自动升级"
    fi
    if [ "$days" -lt "$UPGRADE_WAIT_DAYS" ]; then
      say "下一步: 还需等待观察 $((UPGRADE_WAIT_DAYS - days)) 天"
    elif in_window; then
      say "下一步: 正在维护窗口内，下次 cron（每小时）即会升级"
    else
      say "下一步: 等待维护窗口 $UPGRADE_WINDOW 内的整点 cron"
    fi
  else
    say "结论: 已是最新"
  fi
  say "可回滚镜像: $(docker images flclash --format '{{.Tag}}' 2>/dev/null | tr '\n' ' ')"
}

do_status_json() {
  local cur="" info="" tag="" days=-1 state="latest" transform="false" healthy="false" ip="" images="[]" err="null"
  cur="$(installed_version)"
  transform_present && transform="true"
  health_ok && healthy="true"
  ip="$(curl -s -m 12 -x "$PROXY" 'http://ip-api.com/json?fields=query' 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("query",""))' 2>/dev/null || true)"
  images="$(docker images flclash --format '{{.Tag}}' 2>/dev/null |
    python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))' 2>/dev/null || echo '[]')"

  if [ "$UPGRADE_ENABLED" != "1" ]; then
    state="disabled"
  fi
  if info="$(latest_release)"; then
    tag="$(printf '%s' "$info" | cut -f1)"
    days=$(( ( $(date +%s) - $(printf '%s' "$info" | cut -f2) ) / 86400 ))
    if [ "$state" != "disabled" ]; then
      if ! ver_newer_than "$tag" "$cur"; then
        state="latest"
      elif [ "$(cat "$STATE_DIR/upgrade_blocked" 2>/dev/null || true)" = "$tag" ]; then
        state="blocked"
      elif [ "$days" -lt "$UPGRADE_WAIT_DAYS" ]; then
        state="waiting"
      else
        state="window"
      fi
    fi
  else
    err="\"github unreachable\""
  fi

  printf '{"installed_version":"%s","latest_version":"%s","upgrade_state":"%s","days_waited":%s,' \
    "$(json_escape "$cur")" "$(json_escape "$tag")" "$state" "$days"
  printf '"profile_id":%s,"transform_ok":%s,"healthy":%s,"exit_ip":"%s",' \
    "${PROFILE_ID:-0}" "$transform" "$healthy" "$(json_escape "$ip")"
  printf '"container_image":"%s","images":%s,"error":%s}\n' \
    "$(json_escape "$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)")" \
    "$images" "$err"
}
