#!/bin/sh
# uninstall.sh — 卸掉 LaunchAgent 和安装的脚本；日志保留（里面有 token，自己决定删不删）。
set -eu

LABEL=com.deepseek.dsh-web
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"

/bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$HOME/.local/bin/dsh-web" "$HOME/.local/bin/dsh-web-url" "$HOME/.local/bin/dsh-mode"

echo "已卸载服务。"
echo "日志仍在：$HOME/Library/Logs/dsh-web.log（含 token，可 rm）"
