#!/bin/sh
# install.sh — 把 dsh-web 装成用户级 LaunchAgent。
#
#   sh install.sh            只安装文件，不启动（装完用 dsh-mode web 切过来）
#   sh install.sh --start    安装并立即 bootstrap（会等桌面 App 释放会话锁）
set -eu

HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
LABEL=com.deepseek.dsh-web
BIN_DIR="$HOME/.local/bin"
AGENTS="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
PORT="${DSH_WEB_PORT:-8443}"
PLIST="$AGENTS/$LABEL.plist"
DSH_BIN="/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"

start=0
for arg in "$@"; do
	case "$arg" in
		--start) start=1 ;;
		*) echo "未知参数：$arg（只支持 --start）" >&2; exit 2 ;;
	esac
done

if [ ! -x "$DSH_BIN" ]; then
	echo "找不到 CLI：$DSH_BIN" >&2
	echo "确认 /Applications/DeepSeek Harness.app 存在；App 被改名/移动后需先改回。" >&2
	exit 1
fi

case "$PORT" in
	''|*[!0-9]*) echo "DSH_WEB_PORT 必须是数字，当前：$PORT" >&2; exit 1 ;;
esac

umask 022
mkdir -p "$BIN_DIR" "$AGENTS" "$LOG_DIR"
install -m 755 "$HERE/bin/dsh-web" "$BIN_DIR/dsh-web"
install -m 755 "$HERE/bin/dsh-web-url" "$BIN_DIR/dsh-web-url"
install -m 755 "$HERE/bin/dsh-mode" "$BIN_DIR/dsh-mode"
install -m 644 "$HERE/bin/dsh-web-samesite-lax.cjs" "$BIN_DIR/dsh-web-samesite-lax.cjs"

# 反向代理模式的三件套（DSH_WEB_HOST / PUBLIC_URL / TRUSTED_HOST）：
# 环境变量优先，其次沿用已安装 plist 里的值，都没有就留空（空值等于原来的直连模式）。
plist_value() {
	[ -f "$PLIST" ] || return 0
	/usr/bin/plutil -extract "EnvironmentVariables.$1" raw -o - "$PLIST" 2>/dev/null || true
}
WEB_HOST="${DSH_WEB_HOST:-$(plist_value DSH_WEB_HOST)}"
PUBLIC_URL="${DSH_WEB_PUBLIC_URL:-$(plist_value DSH_WEB_PUBLIC_URL)}"
TRUSTED_HOST="${DSH_WEB_TRUSTED_HOST:-$(plist_value DSH_WEB_TRUSTED_HOST)}"

/usr/bin/sed -e "s|__HOME__|$HOME|g" -e "s|__PORT__|$PORT|g" \
	-e "s|__WEB_HOST__|$WEB_HOST|g" \
	-e "s|__PUBLIC_URL__|$PUBLIC_URL|g" \
	-e "s|__TRUSTED_HOST__|$TRUSTED_HOST|g" \
	"$HERE/com.deepseek.dsh-web.plist.in" > "$PLIST.tmp"
/usr/bin/plutil -lint "$PLIST.tmp" >/dev/null || { echo "生成的 plist 不合法" >&2; rm -f "$PLIST.tmp"; exit 1; }
mv "$PLIST.tmp" "$PLIST"
chmod 644 "$PLIST"

echo "已安装："
echo "  $BIN_DIR/dsh-web"
echo "  $BIN_DIR/dsh-web-url"
echo "  $BIN_DIR/dsh-mode"
echo "  $BIN_DIR/dsh-web-samesite-lax.cjs"
echo "  $PLIST"
echo

if [ "$start" = 1 ]; then
	/bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
	/bin/launchctl bootstrap "gui/$(id -u)" "$PLIST"
	echo "已 bootstrap；如果桌面 App 还开着，它会等在后台，等 App 退出后自动起来。"
else
	echo "未启动。退出桌面 App 后执行："
	echo "  dsh-mode web        # 会等 App 退出、重载服务并打印访问地址"
fi

echo
echo "拿访问地址：dsh-web-url"
echo "看日志：    tail -n 40 \"$LOG_DIR/dsh-web.log\""
