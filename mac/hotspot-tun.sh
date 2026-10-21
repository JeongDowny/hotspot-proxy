#!/bin/bash
# Runs on network changes (and every 30s). Turns the TUN on when on the iPhone hotspot with the proxy app up, off otherwise.
# Hotspot detection is gateway-based: iOS hands out 172.20.10.x (classic) or 192.0.0.x (newer iOS / IPv6-only carriers).
LABEL=com.indo.hotspot-tun.singbox
PLIST=/Library/LaunchDaemons/$LABEL.plist
CONF=/usr/local/etc/hotspot-tun/config.json
SVC=Wi-Fi
TUN_DNS=172.19.0.2   # address inside the TUN; sing-box hijacks it and resolves via the proxy
GW=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/{print $2}')
# iOS 26 hotspots on IPv6-only carriers give 192.0.0.x where 192.0.0.1 is a virtual gateway; the phone's proxy only answers
# on its IPv6 link-local (the v6 default router). Classic hotspots answer on 172.20.10.1.
V6GW=$(/usr/sbin/netstat -rn -f inet6 2>/dev/null | /usr/bin/awk '$1=="default"{print $2; exit}')   # e.g. fe80::...%en0
on_hotspot() { [[ "$GW" =~ ^172\.20\.10\.1$ || "$GW" =~ ^192\.0\.0\.1$ ]]; }
PROXY_HOST=""
if on_hotspot; then
  if /usr/bin/nc -z -G 2 "$GW" 8080 >/dev/null 2>&1; then PROXY_HOST="$GW"
  elif [ -n "$V6GW" ] && /usr/bin/nc -z -G 2 "$V6GW" 8080 >/dev/null 2>&1; then PROXY_HOST="$V6GW"; fi
fi
proxy_up() { [ -n "$PROXY_HOST" ]; }
running() { /bin/launchctl print system/$LABEL >/dev/null 2>&1; }
dns_is() { /usr/sbin/networksetup -getdnsservers "$SVC" | grep -qx "$1"; }
if on_hotspot && proxy_up; then
  # point sing-box at whichever address the iPhone is using this time
  if ! /usr/bin/grep -q "\"server\": \"$PROXY_HOST\"" "$CONF"; then
    /usr/bin/sed -i '' "s|^      \"server\": \"[0-9a-fA-F.:%a-z]*\",$|      \"server\": \"$PROXY_HOST\",|" "$CONF"   # 6-space indent = the socks outbound only
    running && /bin/launchctl bootout system/$LABEL   # restart sing-box with the new server
  fi
  running || /bin/launchctl bootstrap system "$PLIST"
  dns_is "$TUN_DNS" || /usr/sbin/networksetup -setdnsservers "$SVC" "$TUN_DNS"
else
  running && /bin/launchctl bootout system/$LABEL
  dns_is "$TUN_DNS" && /usr/sbin/networksetup -setdnsservers "$SVC" Empty
fi
# When hotspot mode flips, restart tailscaled so it picks up the right proxy env
MODE_FILE=/usr/local/var/hotspot-tun/mode
if on_hotspot && proxy_up; then MODE=hotspot; else MODE=normal; fi
if [ "$(cat $MODE_FILE 2>/dev/null)" != "$MODE" ]; then
  echo "$MODE" > $MODE_FILE
  echo "$(date '+%F %T') mode=$MODE gw=${GW:-none} v6gw=${V6GW:-none} proxy=${PROXY_HOST:-none}" >> /usr/local/var/hotspot-tun/watch.log
  /bin/launchctl print system/com.indo.tailscaled >/dev/null 2>&1 && /bin/launchctl kickstart -k system/com.indo.tailscaled
fi
exit 0
