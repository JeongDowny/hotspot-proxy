#!/bin/bash
# tailscaled binds directly to the physical interface (en0), bypassing the TUN,
# so on the hotspot we pass the phone proxy via env to route control/DERP (HTTPS) through it.
GW=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/{print $2}')
V6GW=$(/usr/sbin/netstat -rn -f inet6 2>/dev/null | /usr/bin/awk '$1=="default"{print $2; exit}')
if [[ "$GW" =~ ^172\.20\.10\.1$ || "$GW" =~ ^192\.0\.0\.1$ ]]; then
  if /usr/bin/nc -z -G 2 "$GW" 8080 >/dev/null 2>&1; then export HTTPS_PROXY=http://$GW:8080 HTTP_PROXY=http://$GW:8080
  elif [ -n "$V6GW" ] && /usr/bin/nc -z -G 2 "$V6GW" 8080 >/dev/null 2>&1; then export HTTPS_PROXY="http://[$V6GW]:8080" HTTP_PROXY="http://[$V6GW]:8080"; fi
fi
exec /opt/homebrew/bin/tailscaled
