#!/bin/sh
# 把代理装成 macOS 登录项（LaunchAgent）：登录后自动在后台运行，退出了会自动重启。
# 用法：tools/proxy-agent.sh install | uninstall | restart | status | log
set -e
cd "$(dirname "$0")/.."
LABEL=com.weread-kindle.proxy
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PROXY_DIR="$(pwd)/proxy"
LOG="$PROXY_DIR/.data/proxy.log"
NODE="$(command -v node)"

case "${1:-status}" in
install)
    mkdir -p "$PROXY_DIR/.data" "$(dirname "$PLIST")"
    cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE</string>
        <string>src/server.js</string>
    </array>
    <key>WorkingDirectory</key><string>$PROXY_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$(dirname "$NODE"):/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "installed: $PLIST"
    ;;
uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "uninstalled"
    ;;
restart)
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
    echo "restarted"
    ;;
status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state =|pid =|last exit code" || echo "not installed"
    ;;
log)
    tail -n 40 "$LOG"
    ;;
*)
    echo "usage: $0 install|uninstall|restart|status|log" >&2
    exit 1
    ;;
esac
