#!/bin/bash
# Builds HotspotProxy and installs it on a USB-connected iPhone (automates the manual xcodebuild/devicectl steps).
# Usage: bash scripts/install-ios.sh [device name substring | UDID] [--check]
#   --check  run the prerequisite checks and device discovery only (no generate/build/install)
set -euo pipefail
cd "$(dirname "$0")/.."

ok()   { printf "  [OK]   %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; [ -n "${2:-}" ] && printf "         -> %s\n" "$2"; exit 1; }

CHECK_ONLY=0
DEVICE_ARG=""
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) DEVICE_ARG="$a" ;;
  esac
done

echo "== 1. 도구"
command -v xcodegen >/dev/null 2>&1 && ok "xcodegen $(command -v xcodegen)" || fail "xcodegen 없음" "brew install xcodegen"
# xcode-select must point at a full Xcode, not CommandLineTools (xcodebuild fails under CLT)
XDIR=$(xcode-select -p 2>/dev/null || true)
[[ "$XDIR" == *.app/Contents/Developer ]] || fail "xcode-select가 Xcode.app이 아님 (${XDIR:-없음})" "Xcode 26.x 설치 후 sudo xcode-select -s /Applications/Xcode.app (docs/BUILD.md 참고)"
XVER=$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}' || true)
XMAJOR=${XVER%%.*}
[[ "$XMAJOR" =~ ^[0-9]+$ ]] && [ "$XMAJOR" -ge 26 ] || fail "Xcode ${XVER:-버전 확인 불가} ($XDIR)" "Xcode 26.x 필요, docs/BUILD.md 참고"
ok "Xcode $XVER ($XDIR)"

echo "== 2. 서명 설정 (signing.env)"
[ -f signing.env ] || fail "signing.env 없음" "cp signing.env.example signing.env 후 값 입력"
set -a; source signing.env; set +a
DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-}
BUNDLE_PREFIX=${BUNDLE_PREFIX:-}
if [ -z "$DEVELOPMENT_TEAM" ] || [ -z "$BUNDLE_PREFIX" ] || [ "$DEVELOPMENT_TEAM" = "ABCDE12345" ] || [ "$BUNDLE_PREFIX" = "com.example" ]; then
  fail "DEVELOPMENT_TEAM / BUNDLE_PREFIX가 비었거나 예시값" "cp signing.env.example signing.env 후 값 입력"
fi
ok "팀 $DEVELOPMENT_TEAM, 번들 접두 $BUNDLE_PREFIX"

echo "== 3. 아이폰 찾기"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
xcrun devicectl list devices > "$TMPD/list.txt" 2>&1 || true
xcrun devicectl list devices --json-output "$TMPD/list.json" -q >/dev/null 2>&1 || true
# Prints one line per matching available iPhone: identifier(UUID) <TAB> udid <TAB> name
# Availability comes from the text State column (available/connected); JSON pairingState is the fallback.
DEVICES=$(python3 - "$TMPD/list.json" "$TMPD/list.txt" "$DEVICE_ARG" <<'PY' || true
import json, re, sys
jpath, tpath, want = sys.argv[1], sys.argv[2], sys.argv[3].lower()
try:
    devs = json.load(open(jpath))["result"]["devices"]
except Exception:
    sys.exit(2)
text = open(tpath, errors="replace").read().splitlines()
for d in devs:
    hw = d.get("hardwareProperties", {}); cp = d.get("connectionProperties", {}); dp = d.get("deviceProperties", {})
    if hw.get("deviceType") != "iPhone" and hw.get("platform") != "iOS":
        continue
    uuid, udid, name = d.get("identifier", ""), hw.get("udid", ""), dp.get("name", "")
    if want and want not in name.lower() and want not in udid.lower() and want not in uuid.lower():
        continue
    state = None
    for line in text:
        if uuid and uuid in line:
            m = re.search(r"\b(unavailable|available|connected)\b", line)
            state = m.group(1) if m else None
            break
    if state is None:
        avail = cp.get("tunnelState") == "connected" or (cp.get("pairingState") == "paired" and "transportType" in cp)
    else:
        avail = state in ("available", "connected")
    if avail and udid:
        print(f"{uuid}\t{udid}\t{name}")
PY
)
N=$(printf "%s" "$DEVICES" | grep -c . || true)
if [ "$N" -eq 0 ]; then
  [ -s "$TMPD/list.json" ] || fail "devicectl 목록을 못 읽음" "Xcode를 한 번 실행해 추가 구성 요소 설치 후 다시 실행"
  fail "사용 가능한 아이폰 없음${DEVICE_ARG:+ (\"$DEVICE_ARG\")}" "USB 연결 + 아이폰에서 '이 컴퓨터를 신뢰' + 설정 › 개인정보 보호 및 보안 › 개발자 모드 켜기"
elif [ "$N" -gt 1 ]; then
  echo "  [FAIL] 아이폰이 ${N}대 연결됨. 기기 이름이나 UDID를 인자로 넘기세요:"
  printf "%s\n" "$DEVICES" | awk -F'\t' '{printf "         %s  (UDID %s)\n", $3, $2}'
  echo "         -> 예: bash scripts/install-ios.sh \"$(printf "%s\n" "$DEVICES" | head -1 | cut -f3)\""
  exit 1
fi
IFS=$'\t' read -r UUID UDID DNAME <<< "$DEVICES"
ok "$DNAME (UDID $UDID)"

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "점검 통과. 빌드·설치는 --check 없이 실행."
  exit 0
fi

echo "== 4. 프로젝트 생성 (xcodegen)"
bash scripts/generate.sh >/dev/null || fail "scripts/generate.sh 실패" "signing.env 값과 project.yml 확인"
ok "HotspotProxy.xcodeproj 생성"

echo "== 5. 빌드 (로그: build/install-ios.log)"
mkdir -p build
LOG=build/install-ios.log
if xcodebuild -project HotspotProxy.xcodeproj -scheme HotspotProxy -configuration Debug \
     -destination "id=$UDID" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
     -derivedDataPath build -quiet build > "$LOG" 2>&1; then
  ok "빌드 성공"
else
  if grep -qE "Unable to log in|No Account for Team" "$LOG"; then
    fail "빌드 실패: 서명 계정 없음" "Xcode › Settings › Accounts에 팀 계정 로그인"
  elif grep -qE "App Group|doesn't support" "$LOG"; then
    fail "빌드 실패: App Group 프로파일 발급 불가" "유료 팀 필요 또는 Xcode에서 재로그인"
  else
    echo "  [FAIL] 빌드 실패. 로그 마지막 20줄:"
    tail -20 "$LOG" | sed 's/^/         /'
    exit 1
  fi
fi

echo "== 6. 설치"
APP=build/Build/Products/Debug-iphoneos/HotspotProxy.app
[ -d "$APP" ] || fail "$APP 없음" "build/install-ios.log 확인"
xcrun devicectl device install app --device "$UUID" "$APP" >> "$LOG" 2>&1 || { tail -10 "$LOG" | sed 's/^/         /'; fail "설치 실패" "아이폰 잠금 해제 후 다시 실행"; }
ok "설치 완료"

echo "== 7. 실행"
if xcrun devicectl device process launch --terminate-existing --device "$UUID" "$BUNDLE_PREFIX.hotspotproxy" >> "$LOG" 2>&1; then
  ok "앱 실행"
else
  fail "앱 실행 실패" "아이폰 설정 › 일반 › VPN 및 기기 관리에서 개발자 앱 신뢰 후 다시 실행"
fi

echo "완료. 아이폰에서 Start Proxy를 누르고, 맥에서 sudo bash mac/install.sh 실행."
