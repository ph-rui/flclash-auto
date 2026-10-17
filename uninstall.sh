#!/usr/bin/env bash
# 卸载：移除软链与程序目录。默认保留配置；--purge 连配置一起删。
# 运行状态（STATE_DIR）与备份（BACKUP_DIR）始终不删，避免误伤现有部署数据。
set -uo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
LIB_DIR="$PREFIX/lib/flclash-auto"
BIN_LINK="$PREFIX/bin/flclash-auto"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/flclash-auto"

say() { printf '%s\n' "$*"; }

cur="$(crontab -l 2>/dev/null || true)"
if printf '%s' "$cur" | grep -qF '# flclash-auto-managed'; then
  printf '%s\n' "$cur" | grep -vF '# flclash-auto-managed' | crontab -
  say "已移除 flclash-auto 托管的 cron 条目"
fi

rm -f "$BIN_LINK"
rm -rf "$LIB_DIR"
say "已删除程序: $LIB_DIR 与 $BIN_LINK"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$CONF_DIR"
  say "已删除配置: $CONF_DIR"
else
  say "保留配置: $CONF_DIR（需要一并删除时用 --purge）"
fi

say "注意: 运行状态（STATE_DIR）、备份（BACKUP_DIR）与 FlClash 数据目录未被改动"
