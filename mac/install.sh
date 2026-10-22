#!/bin/bash
# Usage: sudo bash install.sh   (once)
set -euo pipefail
cd "$(dirname "$0")"
[ "$EUID" -eq 0 ] || { echo "Run as: sudo bash install.sh"; exit 1; }
# sing-box must be at the exact path com.indo.hotspot-tun.singbox.plist launches
SINGBOX=/opt/homebrew/bin/sing-box
[ -x "$SINGBOX" ] || { echo "[FAIL] $SINGBOX 없음 -> brew install sing-box"; exit 1; }
# A manual Wi-Fi proxy left on (e.g. 172.20.10.1) breaks all browsing once off the hotspot; the TUN replaces it
for get in webproxy securewebproxy socksfirewallproxy; do
  out=$(networksetup -get$get Wi-Fi 2>/dev/null || true)
  if grep -q '^Enabled: Yes' <<< "$out"; then
    networksetup -set${get}state Wi-Fi off
    echo "Wi-Fi 수동 프록시($get) 끔"
  fi
done
mkdir -p /usr/local/etc/hotspot-tun /usr/local/var/hotspot-tun /usr/local/libexec
install -m 644 config.json /usr/local/etc/hotspot-tun/config.json
install -m 755 hotspot-tun.sh /usr/local/libexec/hotspot-tun.sh
install -m 644 com.indo.hotspot-tun.singbox.plist /Library/LaunchDaemons/
install -m 644 com.indo.hotspot-tun.watch.plist /Library/LaunchDaemons/
launchctl bootout system/com.indo.hotspot-tun.watch 2>/dev/null || true
launchctl bootout system/com.indo.hotspot-tun.singbox 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.indo.hotspot-tun.watch.plist
sleep 3
launchctl print system/com.indo.hotspot-tun.singbox >/dev/null 2>&1 && echo "TUN on" || echo "Standing by (TUN stays off until the hotspot and proxy app are reachable)"
