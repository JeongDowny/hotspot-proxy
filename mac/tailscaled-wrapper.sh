#!/bin/bash
# tailscaled binds directly to the physical interface (en0), bypassing the TUN,
# so on the hotspot we pass the phone proxy via env to route control/DERP (HTTPS) through it.
GW=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/{print $2}')
V6GW=$(/usr/sbin/netstat -rn -f inet6 2>/dev/null | /usr/bin/awk '$1=="default"{print $2; exit}')
# A suspended iOS app still accepts TCP (kernel backlog) but never answers, so a bare connect test
# is not enough: require a real SOCKS5 greeting reply (05 00) within 3s.
socks_ok() { [ -n "$1" ] && [ "$(printf '\x05\x01\x00' | /usr/bin/nc -G 3 -w 3 "$1" 8080 2>/dev/null | /usr/bin/od -An -tx1 | tr -d ' \n' | head -c 4)" = "0500" ]; }
if [[ "$GW" =~ ^172\.20\.10\.1$ || "$GW" =~ ^192\.0\.0\.1$ ]]; then
  if socks_ok "$GW"; then export HTTPS_PROXY=http://$GW:8080 HTTP_PROXY=http://$GW:8080
  elif [ -n "$V6GW" ] && socks_ok "$V6GW"; then export HTTPS_PROXY="http://[$V6GW]:8080" HTTP_PROXY="http://[$V6GW]:8080"; fi
fi
exec /opt/homebrew/bin/tailscaled
