# Fishcut Camera

TikTok, Instagram Reels, YouTube Shorts용 iPhone 촬영 앱이다. 1순위 기능은 **한 번 녹화로 16:9 가로본과 9:16 세로본을 동시에 얻는 것**이다.

- 렌즈 하나(메인 24mm)로 찍고 파일 두 개를 동시에 쓴다. 두 파일은 색과 소리가 같다.
- 다음 단계는 촬영 노하우 내장(렌즈 고정, 셔터 180도, 장소별 색온도와 ISO 안내, Apple Log)과 Fishcut으로 자동 전송이다.
- 편집기 [Fishcut](https://github.com/NomaDamas/fishcut-dev)과 함께 쓴다.

## 시제품 (#1)

iPhone 메인(광각 24mm) 렌즈 하나로 한 번 녹화하면 두 파일이 동시에 생기는 촬영 앱이다(#1). 렌즈 두 개(MultiCam)는 쓰지 않는다.

| 파일 | 해상도 | 내용 |
|---|---|---|
| `<yyMMdd-HHmmss>_16x9.mov` | 3840x2160 | 전체 프레임 |
| `<yyMMdd-HHmmss>_9x16.mov` | 1080x1920 | 같은 프레임의 가운데 1215x2160을 잘라 줄인 본 |

- 구조: `AVCaptureSession`(후면 광각, 4K 30fps, SDR) -> 영상/오디오 데이터 출력 -> `AVAssetWriter` 두 개(HEVC). 세로본은 Core Image로 자르고 줄여 풀 버퍼에 그린다. 두 파일은 같은 영상 프레임과 같은 오디오 샘플 버퍼를 받는다.
- 미리보기에 9:16 잘림 가이드(양옆 어둡게, 노란 테두리)가 보인다. 화면은 가로(LandscapeRight) 고정이다.
- 오디오: 외부 USB-C 마이크가 있으면 우선 쓰고 없으면 내장 마이크다. 쓰는 입력은 화면 위쪽에 표시된다.
- 파일은 앱 Documents에 저장되고 파일 공유(`UIFileSharingEnabled`)로 Mac이 가져간다.
- Apple Log와 HLG는 2단계다. 지금은 SDR(Rec.709)만 기록한다.

## 촬영 모드

화면 왼쪽 아래에서 고른다. 녹화 중에는 바꿀 수 없다.

| 모드 | 카메라 | 파일 |
|---|---|---|
| 가로+세로 (#1) | 후면 1x 하나 | `_16x9.mov` 3840×2160, `_9x16.mov` 1080×1920 |
| 전후면 (#3) | 후면 1x + 전면, `AVCaptureMultiCamSession` | `_back.mov` (4K, 기기 한도를 넘으면 1080p), `_front.mov` (1080p, 좌우 반전) |

- 전후면 모드는 두 영상을 합치지 않고 파일 두 개로 저장한다. 같은 시작 시각과 같은 오디오를 쓴다. 편집기에서 화면 속 화면, 분할, 컷 전환을 고른다.
- 전후면 모드의 해상도는 후면 4K + 전면 1080p부터 시도하고, 카메라 두 개의 하드웨어 한도(`hardwareCost`)를 넘으면 낮춘다. 실제로 쓰는 값은 형식 칩에 나온다.
- 전후면 모드의 그리드는 16:9 3분할이다. 촬영 설정(노출, 색온도 등)은 아직 가로+세로 모드에만 적용된다.

## 촬영 화면과 설정 (#2)

- 9:16 틀 안에는 글자를 두지 않는다. 왼쪽에 마이크 이름과 소리 크기 미터, 오른쪽에 상태 칩, 녹화 버튼, 타이머, 설정 버튼이 있다.
- 상태 칩은 기기가 실제로 쓰는 값을 읽어 보여 준다: `4K 30 · SDR`, 셔터(180도면 초록), ISO, 색온도, 초점, 남은 용량과 녹화 가능 시간. 잠금은 자물쇠 아이콘, 자동은 `A` 아이콘이다.
- 녹화 중에는 화면 둘레에 빨간 선이 생기고 타이머가 돈다. 화면은 꺼지지 않는다.
- 설정 시트 하나: 프레임(24/30), 셔터 180도 + ISO 고정(켜는 순간의 밝기로 ISO 계산), 색온도(자동/5600K/3200K/지금 값), 녹화 중 자동 색온도 잠금, 초점 잠금, 손떨림 보정, 마이크 입력. 설정은 앱을 다시 열어도 유지된다.
- 미리보기를 탭하면 그 위치에 초점과 노출을 맞춘다.
- 3분할 그리드: 가로선은 두 비율이 같이 쓴다. 노란 9:16 틀 가장자리(34.2%, 65.8%)가 16:9의 세로 3분할(33.3%, 66.7%)과 거의 같아 따로 그리지 않고, 틀 안에 9:16용 세로 3분할을 그린다.
- 수평계: 가운데 흰 눈금과 실제 수평선(노랑)을 겹쳐 보여 주고, 1도 안이면 초록 한 줄로 합쳐지며 진동이 온다. 20도 넘게 기울면 숨긴다. 그리드와 수평계는 설정에서 끌 수 있다.
- iOS 26 이상. 외부 UI 라이브러리 없이 SwiftUI와 Liquid Glass만 쓴다.

### 접근성

모든 컨트롤에 접근성 이름, 값, 식별자(`hud.*`, `chip.*`, `meter.audio`, `settings.*`)가 있다. VoiceOver 사용자와 접근성 트리로 폰을 다루는 도구가 같은 이름으로 앱을 읽고 조작한다.

```sh
xcodebuild test -project FishcutCamera.xcodeproj -scheme FishcutCamera \
  -destination 'platform=iOS Simulator,name=<시뮬레이터 이름>' CODE_SIGNING_ALLOWED=NO
```

`UITests/AccessibilityTests.swift`가 식별자를 확인하고 Apple 접근성 감사(`performAccessibilityAudit`)를 돌린다. 예외는 두 가지다. 촬영 화면의 상태 칩은 글자 크기 상한을 두고 길게 누르면 큰 글자 보기를 띄우므로 Dynamic Type 검사를 뺀다. 설정 시트의 완료 버튼(막대 버튼은 iOS가 큰 글자 보기로 대신한다)과 `화이트 밸런스` 섹션 머리글도 Dynamic Type 검사에서 뺀다. 머리글이 걸리는 원인은 아직 밝히지 못했다(다른 머리글은 통과한다).

## 빌드와 설치

```sh
xcodegen generate   # project.yml -> FishcutCamera.xcodeproj (커밋하지 않음)
xcodebuild -project FishcutCamera.xcodeproj -scheme FishcutCamera \
  -destination 'id=<기기 UDID>' -allowProvisioningUpdates -derivedDataPath "$TMPDIR/fishcut-camera" \
  DEVELOPMENT_TEAM=<팀 ID> build
xcrun devicectl device install app --device <기기 UDID> "$TMPDIR/fishcut-camera/Build/Products/Debug-iphoneos/FishcutCamera.app"
xcrun devicectl device process launch --device <기기 UDID> com.seungwonme.fishcut.camera
```

서명은 자동이다. 팀 ID는 개인 계정 정보라 저장소에 두지 않고 빌드할 때 `DEVELOPMENT_TEAM`으로 넘긴다(Xcode > Settings > Accounts의 팀). Xcode > Settings > Accounts에 Apple ID가 로그인돼 있어야 한다.

## Mac으로 가져오기

```sh
printf 'ls -l\nexit\n' | pymobiledevice3 apps afc com.seungwonme.fishcut.camera --documents --native
pymobiledevice3 apps pull com.seungwonme.fishcut.camera /Documents/<파일> <저장 경로> --documents --native
```

라이선스: Apache-2.0
