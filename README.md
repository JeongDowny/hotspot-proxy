# Hotspot Proxy

iPhone 핫스팟을 프록시로 바꿔, 테더링한 맥의 트래픽을 iPhone 자체 셀룰러 경로로 내보내는 iOS 앱과 맥 자동 전환 스크립트.
[Indosaram/hotspot-proxy](https://github.com/Indosaram/hotspot-proxy)를 포크해 iOS 26 · IPv6 전용 통신사 환경에서 동작하도록 고친 버전이다.

## 왜 쓰나

통신사는 핫스팟(테더링) 트래픽을 따로 분류해 속도를 제한하거나 용량을 별도로 센다. 이 앱은 iPhone 안에서 HTTP · HTTPS(CONNECT) · SOCKS5 프록시를 띄운다. 맥이 그 프록시를 거쳐 나가면 통신사 입장에서는 iPhone 자체 트래픽으로 보인다.

맥 쪽 스크립트는 핫스팟에 붙는 순간 sing-box TUN을 켜서 **모든** 트래픽을 프록시로 보내고, 핫스팟을 벗어나면 원래대로 되돌린다. 수동 설정이 없다.

## 구조

```
iPhone                                   Mac
┌──────────────────────┐   핫스팟 Wi-Fi   ┌──────────────────────────────┐
│ Hotspot Proxy 앱     │◄───────────────►│ launchd: hotspot-tun.watch     │
│  · HTTP/SOCKS5 :8080 │                 │   30초마다 + 네트워크 변경마다  │
│  · 모든 인터페이스   │                 │   hotspot-tun.sh 실행          │
│    에서 수신         │                 │     ├ 핫스팟 판정 (게이트웨이)  │
│  · 위젯 / 딥링크     │                 │     ├ 프록시 주소 탐색          │
└──────────┬───────────┘                 │     │   v4 gw → v6 링크로컬     │
           │ 셀룰러                      │     └ sing-box TUN on/off + DNS │
           ▼                             │ sing-box (utun199)             │
        인터넷                           │   TCP·DNS → socks proxy        │
                                         │   UDP → direct                 │
                                         └──────────────────────────────┘
```

| 경로 | 역할 |
|---|---|
| `Sources/`, `Shared/`, `Widget/` | iOS 앱, 공유 상태, WidgetKit 확장 |
| `project.yml` | XcodeGen 스펙. 서명 정보는 `signing.env`에서 읽는다 |
| `scripts/generate.sh` | `signing.env`를 읽어 `.xcodeproj`를 생성 |
| `mac/install.sh`, `uninstall.sh` | 맥 자동 전환 데몬 설치·제거 (sudo) |
| `mac/hotspot-tun.sh` | 핫스팟 판정과 TUN 전환 로직 |
| `mac/config.json` | sing-box 설정 |
| `mac/check.sh` | 현재 상태를 OK/FAIL로 점검 |
| `mac/probe/` | 20초 주기 상태 기록기 (문제 추적용, 선택) |
| `docs/` | 상세 가이드와 작업 기록 |

## 원본과 달라진 점

| 항목 | 원본 | 이 포크 |
|---|---|---|
| 핫스팟 판정 | 맥 IP가 `172.20.10.x`인지 | 기본 게이트웨이가 `172.20.10.1` 또는 `192.0.0.1`인지 |
| 프록시 주소 | `172.20.10.1` 고정 | v4 게이트웨이 → 안 열리면 iPhone IPv6 링크로컬(`fe80::…%en0`) 자동 탐색 |
| sing-box | 서버 고정 | 탐색한 주소로 교체·재시작, `bind_interface: en0`, UDP는 direct |
| 앱 업스트림 연결 | `.waiting`을 실패로 처리, 실패 응답 유실 | `.waiting` 대기(15초 상한), 실패 응답 전송 후 종료. 카카오톡 로그인 등 동시 다중 연결 앱 수정 |
| 서명 정보 | 스펙에 하드코딩 | `signing.env`(git 무시)로 분리. App Group은 Info.plist에서 읽음 |
| 진단 | 없음 | `check.sh`, 상태 기록기, `watch.log` |

iOS 26에서 IPv6 전용 통신사를 쓰면 핫스팟이 맥에 `192.0.0.2`를 주고 게이트웨이 `192.0.0.1`은 가상 주소라 iPhone 앱이 응답하지 않는다. 앱은 iPhone의 IPv6 링크로컬 주소에서만 응답한다. 이것이 원본이 동작하지 않던 이유였다.

## 요구 사항

- iPhone: iOS 17 이상, 개발자 모드.
- Mac: Xcode 26.x(iPhone의 iOS 버전과 맞는 SDK), Homebrew, `xcodegen`, `sing-box`.
- **유료** Apple 개발자 계정. App Group 권한이 필요해 무료 Personal Team으로는 서명되지 않는다. 개발용 서명은 1년 유효.

## 빠른 시작

### 1. iPhone 앱

```bash
brew install xcodegen
cp signing.env.example signing.env      # 팀 ID와 번들 접두를 적는다
bash scripts/generate.sh
open HotspotProxy.xcodeproj
```

Xcode에서 팀 계정으로 로그인한 뒤 iPhone을 대상으로 Run. 처음 한 번은 USB로 연결해 "이 컴퓨터를 신뢰"를 누른다. 이후 같은 Wi-Fi에서 무선 설치가 된다. 터미널만으로 하는 절차는 [docs/BUILD.md](docs/BUILD.md).

### 2. Mac 자동 전환

```bash
brew install sing-box
sudo bash mac/install.sh
```

맥 Wi-Fi의 수동 프록시 설정은 비워 둔다. 수동 프록시가 있으면 핫스팟이 아닐 때 브라우저가 전부 막힌다.

### 3. 사용

1. iPhone 앱에서 **Start Proxy**.
2. iPhone 설정 › 개인용 핫스팟 화면을 열어 둔다. 닫혀 있으면 맥에서 핫스팟이 검색되지 않는다.
3. 맥 Wi-Fi에서 iPhone을 고른다. 약 2초 뒤 TUN이 켜진다.
4. 끊으면 2초 뒤 원래대로.

### 4. 확인

```bash
bash mac/check.sh
```

1~5번 OK이고 6번의 두 공인 IP가 같으면 정상이다. 실측: 프록시 경유 다운 56 Mbps · 업 30 Mbps · RTT 89 ms (iPhone 15 Pro, 5G).

## 문제가 생기면

`mac/probe/probe.sh`를 LaunchAgent로 올려 두면 20초마다 상태가 바뀔 때만 한 줄을 남기고, 핫스팟 중에는 iPhone 주소 후보마다 8080 포트를 두드려 어느 주소가 열리는지 기록한다. 모든 원인을 이 로그로 찾았다.

```bash
# 등록 (sudo 불필요)
cat > ~/Library/LaunchAgents/com.local.hotspot-probe.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.local.hotspot-probe</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$PWD/mac/probe/probe.sh</string></array>
  <key>StartInterval</key><integer>20</integer><key>RunAtLoad</key><true/>
  <key>WatchPaths</key><array><string>/Library/Preferences/SystemConfiguration</string></array>
</dict></plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.hotspot-probe.plist
```

증상별 원인과 해결은 [docs/share-guide.md](docs/share-guide.md) 7장. 

## 되돌리기

```bash
sudo bash mac/uninstall.sh
launchctl bootout gui/$(id -u)/com.local.hotspot-probe
```

## Tailscale과 같이 쓰기 (선택)

핫스팟 중 Tailscale 제어 트래픽도 프록시로 보내려면 GUI 앱 대신 Homebrew `tailscaled`를 launchd로 돌린다. `sudo bash mac/install-tailscale.sh`를 **한 번만** 실행한다. 두 번 실행하면 `Bootstrap failed: 5`가 난다. 전환 후 GUI 앱은 열지 않는다. 자세한 절차와 함정은 share-guide 4장.

## 라이선스

원본 저장소의 라이선스를 따른다.
