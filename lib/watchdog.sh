#!/usr/bin/env bash
# lib/watchdog.sh — 巡检状态机：锁让路 -> 改写漂移 -> 订阅到期 -> 健康阶梯

# DRY_RUN=1 时只说明理由，不产生任何副作用（供 --explain 使用）
explain() {
  [ "${DRY_RUN:-0}" = "1" ] && say "$*"
  return 0
}

main_check() {
  local url ua last now fails tmp raw_hash prev_hash rc
  DRY_RUN="${DRY_RUN:-0}"

  rotate_log

  # 1) 升级进行中：此时应用会被主动停掉，健康检查必然失败，必须让路
  if lock_active; then
    explain "升级流程进行中（upgrade.lock 存在），本轮让路"
    return 0
  fi

  url="$(sub_url)"
  ua="$(sub_ua)"
  if [ -z "$url" ]; then
    explain "读不到订阅地址（profiles.url 为空）"
    log "ERROR: 读不到订阅地址（profiles.url 为空）"
    return 1
  fi

  # 2) 改写漂移：被 UI 手动更新会退回 select，需重新下载并改写
  if ! transform_present; then
    explain "profile 中已无 url-test 分组（可能被 UI 手动更新），需重新下载并改写"
    [ "$DRY_RUN" = "1" ] && return 0
    tmp="$STATE_DIR/tmp.sub.$$"
    if ! fetch_subscription "$url" "$ua" "$tmp"; then
      log "WARN: 改写丢失，但订阅下载失败，下轮重试"
      rm -f "$tmp"
      return 0
    fi
    apply_profile "$tmp" "改写丢失恢复"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      md5sum "$tmp" | awk '{print $1}' > "$STATE_DIR/sub_hash"
      date +%s > "$STATE_DIR/last_sub_sync"
      log "OK: 改写已恢复"
    else
      log "ERROR: 改写恢复未成功（rc=$rc），下轮继续"
    fi
    rm -f "$tmp"
    return 0
  fi
  explain "profile 改写完好（存在 url-test 分组）"

  # 3) 订阅到期
  last="$(cat "$STATE_DIR/last_sub_sync" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [ $((now - last)) -ge "$SUB_REFRESH_INTERVAL" ]; then
    explain "订阅距上次同步 $((now - last))s，已超过 ${SUB_REFRESH_INTERVAL}s，需检查更新"
    [ "$DRY_RUN" = "1" ] && return 0
    tmp="$STATE_DIR/tmp.sub.$$"
    if ! fetch_subscription "$url" "$ua" "$tmp"; then
      log "WARN: 订阅下载失败（机场临时故障？），本轮跳过"
      rm -f "$tmp"
      return 0
    fi
    raw_hash="$(md5sum "$tmp" | awk '{print $1}')"
    prev_hash="$(cat "$STATE_DIR/sub_hash" 2>/dev/null || true)"
    # 失败时也推进时间戳：避免每 5 分钟重下、把机场打烦；hash 保持旧值，下个周期重试
    echo "$now" > "$STATE_DIR/last_sub_sync"
    if [ "$raw_hash" != "$prev_hash" ]; then
      log "INFO: 订阅内容有变化（${prev_hash:-无记录} -> $raw_hash）"
      apply_profile "$tmp" "订阅更新"
      rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "$raw_hash" > "$STATE_DIR/sub_hash"
        log "OK: 订阅更新完成"
      else
        log "ERROR: 订阅已下载但应用未成功（rc=$rc），下个周期重试"
      fi
    else
      log "INFO: 订阅无变化"
    fi
    rm -f "$tmp"
    return 0
  fi
  explain "订阅未到期（还剩 $((SUB_REFRESH_INTERVAL - (now - last)))s）"

  # 4) 健康
  if health_ok; then
    echo 0 > "$STATE_DIR/health_fail"
    explain "健康检查正常，无需动作"
    return 0
  fi
  explain "健康检查失败（若计数达到 $HEALTH_FAIL_THRESHOLD 将重启容器）"
  [ "$DRY_RUN" = "1" ] && return 0

  fails=$(( $(cat "$STATE_DIR/health_fail" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$STATE_DIR/health_fail"
  log "WARN: 健康检查失败（连续 $fails 次，阈值 $HEALTH_FAIL_THRESHOLD）"
  [ "$fails" -ge "$HEALTH_FAIL_THRESHOLD" ] || return 0

  log "INFO: 达到阈值，重启容器自愈"
  docker restart "$CONTAINER" >/dev/null 2>&1
  if wait_healthy; then
    echo 0 > "$STATE_DIR/health_fail"
    log "OK: 重启后恢复"
    return 0
  fi

  log "WARN: 重启无效，强制重下订阅并改写"
  tmp="$STATE_DIR/tmp.sub.$$"
  if fetch_subscription "$url" "$ua" "$tmp"; then
    apply_profile "$tmp" "故障自愈"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      md5sum "$tmp" | awk '{print $1}' > "$STATE_DIR/sub_hash"
      date +%s > "$STATE_DIR/last_sub_sync"
      echo 0 > "$STATE_DIR/health_fail"
      log "OK: 强制刷新后恢复"
    else
      log "ERROR: 强制刷新未成功（rc=$rc），需人工检查"
    fi
  else
    log "ERROR: 订阅下载失败，需人工检查（机场整体不可达？）"
  fi
  rm -f "$tmp"
  return 0
}
