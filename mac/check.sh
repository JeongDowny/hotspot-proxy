#!/bin/bash
# 핫스팟 프록시 상태 점검. 실행: bash ~/source/hotspot-proxy/mac/check.sh
ok(){ printf "  [OK]   %s\n" "$1"; }
no(){ printf "  [FAIL] %s\n" "$1"; }
GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
echo "== 1. 맥이 아이폰 핫스팟에 붙어 있나 (게이트웨이 172.20.10.1 또는 192.0.0.1)"
if [[ "$GW" =~ ^172\.20\.10\.1$ || "$GW" =~ ^192\.0\.0\.1$ ]]; then ok "핫스팟 게이트웨이 $GW, 맥 IP $(ipconfig getifaddr en0 2>/dev/null)"; else no "핫스팟 아님. 게이트웨이 ${GW:-없음}, 맥 IP $(ipconfig getifaddr en0 2>/dev/null || echo 없음)"; fi
V6GW=$(netstat -rn -f inet6 2>/dev/null | awk '$1=="default"{print $2; exit}')
PROXY_HOST=""
if [ -n "$GW" ] && nc -z -G 2 "$GW" 8080 >/dev/null 2>&1; then PROXY_HOST="$GW"; elif [ -n "$V6GW" ] && nc -z -G 2 "$V6GW" 8080 >/dev/null 2>&1; then PROXY_HOST="$V6GW"; fi
echo "== 2. 아이폰 앱 프록시가 응답하나 (v4 게이트웨이 $GW 또는 v6 라우터 ${V6GW:-없음})"
if [ -n "$PROXY_HOST" ]; then ok "프록시 주소 $PROXY_HOST:8080 열림"; else no "응답 없음. 아이폰 앱에서 Start Proxy 확인"; fi
echo "== 3. 감시 데몬(30초마다 자동 전환)이 떠 있나"
if launchctl print system/com.indo.hotspot-tun.watch >/dev/null 2>&1; then ok "watch 데몬 등록됨 (mode=$(cat /usr/local/var/hotspot-tun/mode 2>/dev/null))"; else no "watch 데몬 없음. sudo bash mac/install.sh 필요"; fi
echo "== 4. sing-box TUN이 켜져 있나"
if launchctl print system/com.indo.hotspot-tun.singbox >/dev/null 2>&1; then ok "sing-box 실행 중"; else no "sing-box 꺼짐 (핫스팟 아니면 정상)"; fi
if ifconfig utun199 >/dev/null 2>&1; then ok "utun199 인터페이스 있음"; else no "utun199 없음 (핫스팟 아니면 정상)"; fi
echo "== 5. DNS가 TUN(172.19.0.2)으로 잡혔나"
if networksetup -getdnsservers Wi-Fi | grep -qx 172.19.0.2; then ok "DNS 172.19.0.2"; else no "DNS 기본값 (핫스팟 아니면 정상)"; fi
echo "== 6. 실제 트래픽 경로"
direct=$(curl -s -m 8 https://api.ipify.org 2>/dev/null)
viaproxy=$(curl -s -m 8 --proxy "socks5h://[$PROXY_HOST]:8080" https://api.ipify.org 2>/dev/null)
echo "  지금 맥의 공인 IP      : ${direct:-실패}"
echo "  프록시 경유 공인 IP     : ${viaproxy:-실패(프록시 미응답)}"
if [ -n "$direct" ] && [ "$direct" = "$viaproxy" ]; then ok "맥 트래픽이 프록시(아이폰 셀룰러)를 통해 나감"; elif [ -n "$viaproxy" ]; then no "프록시는 되지만 맥 기본 경로는 아직 직결. TUN 미작동"; fi
echo "== 7. 최근 로그 (watch / sing-box)"
tail -3 /usr/local/var/hotspot-tun/watch.log 2>/dev/null
tail -5 /usr/local/var/hotspot-tun/sing-box.log 2>/dev/null || echo "  로그 없음"
echo "== 8. Tailscale (CLI 데몬)"
tsip=$(/opt/homebrew/bin/tailscale ip -4 2>/dev/null)
if [ -n "$tsip" ]; then ok "tailscale IP $tsip"; else no "tailscale 미연결 (CLI 데몬을 안 쓰면 무시)"; fi
