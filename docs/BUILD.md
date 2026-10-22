# 팀원용 직접 빌드 절차

저장소에는 서명 정보가 들어 있지 않다. `signing.env`에 팀 ID와 번들 접두를 적으면 나머지는 스크립트가 채운다. 전달받은 묶음(kit)에는 `signing.env`가 이미 들어 있다.

## 빌드에 포함된 식별자

| 항목 | 값 |
|---|---|
| Apple 개발자 팀 | `signing.env`의 `DEVELOPMENT_TEAM` |
| 앱 번들 ID | `<BUNDLE_PREFIX>.hotspotproxy` |
| 위젯 번들 ID | `<BUNDLE_PREFIX>.hotspotproxy.widget` |
| App Group | `group.<BUNDLE_PREFIX>.hotspotproxy` |
| 서명 방식 | Automatic (Xcode가 팀 프로파일을 자동 발급) |
| 최소 iOS | 17.0 |

Xcode에 **그 팀에 속한 Apple 계정**으로 로그인되어 있어야 한다. 다른 팀이면 `signing.env`의 두 값만 바꾼다.

## 이 팀원 맥 (macOS 26.5.1) → Xcode 26.6

- App Store의 Xcode는 27이라 macOS 26.6이 필요해 설치가 안 된다. **Xcode 26.6**을 받는다. 요구 사항은 macOS 26.2 이상이다.
- 다운로드 페이지: https://developer.apple.com/download/all/?q=Xcode%2026.6 (Apple 개발자 계정 로그인 필요, 약 3~4 GB `.xip`)
- 직접 링크(로그인 후): https://download.developer.apple.com/Developer_Tools/Xcode_26.6/Xcode_26.6.xip
- 설치: `.xip` 더블클릭 → 생성된 `Xcode.app`을 응용 프로그램 폴더로 이동 → 실행해 추가 구성 요소 설치 → 터미널 `sudo xcode-select -s /Applications/Xcode.app`
- Xcode 26.6의 iOS SDK는 26.5이지만 iOS 26.6 기기에 설치·디버깅이 된다(작성자 환경이 동일 조합).

## Xcode 버전 고르기 (다른 맥 macOS 버전별)

아이폰이 iOS 26.6이면 Xcode도 iOS 26.x SDK가 든 26 계열이어야 한다.

| 맥 macOS | 설치 가능한 Xcode | 비고 |
|---|---|---|
| Tahoe 26.6 이상 | Xcode 27, 26.6 | 그대로 App Store에서 받으면 됨 |
| Tahoe 26.2 ~ 26.5 | Xcode 26.4 ~ 26.6 | App Store 버전이 안 맞으면 아래 다운로드 페이지에서 26.6 |
| Sequoia 15.6 ~ 15.x | Xcode 26.0 ~ 26.3 | 아래 다운로드 페이지에서 **Xcode 26.3** |
| Sequoia 15.5 이하, Sonoma | Xcode 16.x | iOS 26 SDK가 없어 iOS 26.6 기기에 설치 불가. macOS 업데이트 필요 |

- 옛 버전 다운로드: https://developer.apple.com/download/all/ (개발자 계정 로그인 후 "Xcode" 검색, `.xip` 파일)
- 설치: `.xip`을 더블클릭해 풀고 `Xcode.app`을 응용 프로그램 폴더로 옮긴 뒤 한 번 실행해 추가 구성 요소를 설치한다. 기존 Xcode와 나란히 둘 수 있다. 터미널은 `sudo xcode-select -s /Applications/Xcode.app`.
- 주의: Xcode 26.3으로 iOS 26.6 기기에 설치할 때 "기기 지원 파일" 경고가 나올 수 있다. Xcode가 자동 내려받기를 제안하면 받으면 된다. 안 되면 macOS를 26.2 이상으로 올리고 Xcode 26.6을 쓴다.

## 빌드·설치

설치는 스크립트 2개, 점검은 스크립트 1개로 끝난다.

1. Xcode › Settings › Accounts에 팀 계정으로 로그인한다.
2. 아이폰을 USB로 연결하고 아이폰에서 "이 컴퓨터를 신뢰"를 누른다. 아이폰 설정 › 개인정보 보호 및 보안 › 개발자 모드를 켠다.
3. 도구를 설치한다.
   ```bash
   brew install xcodegen sing-box
   ```
4. 아이폰 앱을 빌드·설치·실행한다. `signing.env`가 없으면 먼저 `cp signing.env.example signing.env` 후 값을 넣는다(묶음에 있으면 생략).
   ```bash
   bash scripts/install-ios.sh             # 아이폰 1대면 자동 선택
   bash scripts/install-ios.sh "iPhone"    # 여러 대면 기기 이름(일부) 또는 UDID를 인자로
   bash scripts/install-ios.sh --check     # 도구·서명·기기만 점검, 빌드 안 함
   ```
   단계마다 `[OK]`/`[FAIL]`이 찍히고, 실패하면 다음에 할 일을 한 줄로 알려 준다. 빌드 로그는 `build/install-ios.log`.
   끝나면 아이폰 앱에서 Start Proxy를 누른다. 앱이 안 열리면 아이폰 설정 › 일반 › VPN 및 기기 관리에서 개발자 앱을 신뢰한다.
5. 맥 쪽 TUN을 설치한다. 비밀번호 입력이 필요하니 실제 터미널에서 실행한다.
   ```bash
   sudo bash mac/install.sh
   ```
6. 상태를 점검한다.
   ```bash
   bash mac/check.sh
   ```

`install-ios.sh`가 내부에서 돌리는 명령은 예전 수동 절차와 같다. 스크립트 없이 하려면:

```bash
bash scripts/generate.sh
xcrun devicectl list devices                         # UDID(00008130-…)와 UUID 확인
xcodebuild -project HotspotProxy.xcodeproj -scheme HotspotProxy -configuration Debug \
  -destination 'id=<UDID>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -derivedDataPath build build
xcrun devicectl device install app --device <UUID> build/Build/Products/Debug-iphoneos/HotspotProxy.app
```

맥 스크립트 설명과 사용법은 `docs/share-guide.md` 4장(맥 자동 전환 스크립트)과 5장(사용)을 본다.
