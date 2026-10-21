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

```bash
brew install xcodegen
cp signing.env.example signing.env   # 묶음에 signing.env가 있으면 생략
bash scripts/generate.sh
open HotspotProxy.xcodeproj
```

1. Xcode › Settings › Accounts에 팀 계정 로그인.
2. 아이폰을 USB로 연결, 아이폰에서 "이 컴퓨터를 신뢰". 아이폰 설정 › 개인정보 보호 및 보안 › 개발자 모드 켜기.
3. 상단 실행 대상을 아이폰으로 고르고 Run(⌘R). 처음에는 기기 등록과 프로파일 발급이 자동으로 돈다.
4. 앱이 안 열리면 아이폰 설정 › 일반 › VPN 및 기기 관리에서 Enter Next Inc. 신뢰.

터미널로만 하려면:

```bash
xcrun devicectl list devices                         # UDID(00008130-…)와 UUID 확인
xcodebuild -project HotspotProxy.xcodeproj -scheme HotspotProxy -configuration Debug \
  -destination 'id=<UDID>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -derivedDataPath build build
xcrun devicectl device install app --device <UUID> build/Build/Products/Debug-iphoneos/HotspotProxy.app
```

그다음 맥 쪽 설정은 `docs/share-guide.md` 4장부터.
