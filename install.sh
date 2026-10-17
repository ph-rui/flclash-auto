#!/usr/bin/env bash
# 幂等安装：拷贝 bin/lib 到 PREFIX，建软链，生成配置
set -uo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
LIB_DIR="$PREFIX/lib/flclash-auto"
BIN_DIR="$PREFIX/bin"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/flclash-auto"
CONF="$CONF_DIR/config.conf"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

say() { printf '%s\n' "$*"; }

missing=0
for c in docker curl sqlite3 python3 ss awk sed grep; do
  if ! command -v "$c" >/dev/null 2>&1; then
    say "缺少命令: $c"
    missing=1
  fi
done
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  say "缺少 python3-yaml，请安装: sudo apt install python3-yaml"
  missing=1
fi

mkdir -p "$LIB_DIR" "$BIN_DIR" "$CONF_DIR" || exit 1
rm -rf "${LIB_DIR:?}/bin" "${LIB_DIR:?}/lib"
cp -a "$ROOT/bin" "$ROOT/lib" "$LIB_DIR/" || exit 1
chmod +x "$LIB_DIR/bin/flclash-auto"

ln -sfn "$LIB_DIR/bin/flclash-auto" "$BIN_DIR/flclash-auto"

if [ ! -f "$CONF" ]; then
  cp "$ROOT/config/flclash-auto.conf.example" "$CONF"
  say "已生成配置: $CONF（请按需修改 DATA_DIR / STATE_DIR / CONTAINER）"
else
  say "保留已有配置: $CONF"
fi

say ""
say "安装完成: $BIN_DIR/flclash-auto"
say "下一步:"
say "  1) 编辑配置 $CONF"
say "  2) $BIN_DIR/flclash-auto --selftest"
say "  3) $BIN_DIR/flclash-auto --install-cron"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    say ""
    say "提示: $BIN_DIR 不在 PATH 中，可把下面一行加入 ~/.bashrc："
    say "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

[ "$missing" -eq 0 ]
