#!/bin/bash
# 20초마다 맥·아이폰 양쪽 상태를 한 줄로 기록. 로그: ~/source/hotspot-proxy/mac/probe/probe.log
LOG=${PROBE_LOG:-$(cd "$(dirname "$0")" && pwd)/probe.log}
PHONE_TS=${PHONE_TAILSCALE_IP:-}   # optional: phone Tailscale IP to check the app is alive regardless of hotspot
GW=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/{print $2}')
IP=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null)
if [[ "$GW" =~ ^172\.20\.10\.1$ || "$GW" =~ ^192\.0\.0\.1$ ]]; then HS=yes; else HS=no; fi
socks_ok() { [ -n "$1" ] && [ "$(printf '\x05\x01\x00' | /usr/bin/nc -G 3 -w 3 "$1" 8080 2>/dev/null | /usr/bin/od -An -tx1 | tr -d ' \n' | head -c 4)" = "0500" ]; }
if socks_ok "$GW"; then GWP=socks; elif [ -n "$GW" ] && /usr/bin/nc -z -G 2 "$GW" 8080 >/dev/null 2>&1; then GWP=tcp-only; else GWP=closed; fi
V6GW0=$(/usr/sbin/netstat -rn -f inet6 2>/dev/null | /usr/bin/awk '$1=="default"{print $2; exit}')
if socks_ok "$V6GW0"; then V6P=socks; elif [ -n "$V6GW0" ] && /usr/bin/nc -z -G 2 "$V6GW0" 8080 >/dev/null 2>&1; then V6P=tcp-only; else V6P=closed; fi
if socks_ok "$PHONE_TS"; then APP=up; elif [ -n "$PHONE_TS" ] && /usr/bin/nc -z -G 3 "$PHONE_TS" 8080 >/dev/null 2>&1; then APP=suspended; else APP=down; fi
if /bin/launchctl print system/com.indo.hotspot-tun.singbox >/dev/null 2>&1; then SB=on; else SB=off; fi
if /sbin/ifconfig utun199 >/dev/null 2>&1; then TUN=yes; else TUN=no; fi
DNS=$(/usr/sbin/networksetup -getdnsservers Wi-Fi 2>/dev/null | grep -E '^[0-9]' | head -1)
MODE=$(cat /usr/local/var/hotspot-tun/mode 2>/dev/null)
PUB=$(/usr/bin/curl -s -m 5 https://api.ipify.org 2>/dev/null)
LAST=$(tail -1 "$LOG" 2>/dev/null | cut -d' ' -f3-)
NOW="ip=${IP:-none} gw=${GW:-none} hotspot=$HS gw8080=$GWP v6gw8080=$V6P iphoneApp=$APP singbox=$SB tun=$TUN dns=${DNS:-default} mode=${MODE:-?} pubip=${PUB:-fail}"
[ "$NOW" != "$LAST" ] && echo "$(date '+%F %T') $NOW" >> "$LOG"
# 핫스팟일 때 아이폰의 실제 링크 주소 후보를 찾아 8080을 두드려 본다 (1분에 한 번)
if [ "$HS" = yes ] && [ "$(( $(date +%s) / 60 ))" != "$(cat /tmp/hotspot-probe.min 2>/dev/null)" ]; then
  echo $(( $(date +%s) / 60 )) > /tmp/hotspot-probe.min
  V6GW=$(/usr/sbin/netstat -rn -f inet6 2>/dev/null | /usr/bin/awk '$1=="default"{print $2; exit}')
  echo "  [detail] en0 addrs: $(/sbin/ifconfig en0 | /usr/bin/grep inet | /usr/bin/awk '{print $2}' | tr '\n' ' ')" >> "$LOG"
  echo "  [detail] v6 default router: ${V6GW:-none}" >> "$LOG"
  echo "  [detail] arp(en0): $(/usr/sbin/arp -an -i en0 2>/dev/null | /usr/bin/awk '{print $2}' | tr -d '()' | tr '\n' ' ')" >> "$LOG"
  echo "  [detail] ndp(en0): $(/usr/sbin/ndp -an 2>/dev/null | /usr/bin/awk '$3 ~ /en0/ && $1 !~ /^fe80::1%|^ff/ {print $1}' | head -6 | tr '\n' ' ')" >> "$LOG"
  for c in "$GW" "$V6GW" $(/usr/sbin/arp -an -i en0 2>/dev/null | /usr/bin/awk '{print $2}' | tr -d '()') $(/usr/sbin/ndp -an 2>/dev/null | /usr/bin/awk '$3 ~ /en0/ && $1 !~ /^ff/ {print $1}' | head -6) $PHONE_TS; do
    [ -z "$c" ] && continue
    r=$(/usr/bin/nc -z -G 2 "$c" 8080 >/dev/null 2>&1 && echo open || echo closed)
    echo "  [detail] probe $c:8080 -> $r" >> "$LOG"
  done
  if [ -n "$PHONE_TS" ]; then ps=$(/usr/bin/curl -s -m 6 --proxy "socks5h://$PHONE_TS:8080" https://api.ipify.org 2>/dev/null); echo "  [detail] pubip via phone tailscale socks5: ${ps:-fail}" >> "$LOG"; fi
fi
exit 0
