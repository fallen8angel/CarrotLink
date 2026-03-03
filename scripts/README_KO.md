# CarrotLink Scripts

`scripts/build_dev_apk.ps1`와 `scripts/apk_menu.ps1`는 Android APK 빌드/설치 자동화를 위한 스크립트입니다.

## 1) 메뉴형 실행

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\apk_menu.ps1
```

주요 메뉴:

- Release/Debug/Profile 빌드 + 설치
- 기존 APK 설치만
- Clean + PubGet + 빌드 + 설치
- 무선 adb 연결 후 설치
- 고급 실행(세부 옵션 직접 입력)

## 2) 단일 명령형 실행

기본 Release 빌드 후 설치:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_dev_apk.ps1 -BuildMode release -Install -PromptDevice
```

기존 Debug APK 설치만:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_dev_apk.ps1 -BuildMode debug -SkipBuild -Install -PromptDevice
```

무선 연결 + 설치 + 설치 후 실행:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_dev_apk.ps1 `
  -BuildMode release -SkipBuild -Install `
  -ConnectAddress 172.30.1.21:5555 -WaitForDeviceSeconds 30 `
  -InstallRetry 2 -LaunchAfterInstall -UseFirstDevice
```

## 3) 자주 쓰는 옵션

- `-Clean`: `flutter clean` 실행
- `-PubGet`: `flutter pub get` 실행
- `-SkipBuild`: 빌드 생략, 기존 APK 사용
- `-Install`: 빌드 후 adb 설치
- `-PromptDevice`: 기기 여러 대일 때 선택창 표시
- `-UseFirstDevice`: 기기 여러 대일 때 첫 번째 기기 자동 선택
- `-ConnectAddress`: 설치 전에 `adb connect <ip:port>` 수행
- `-WaitForDeviceSeconds`: 기기 온라인 대기 시간(초)
- `-InstallRetry`: 설치 재시도 횟수
- `-UninstallFirst`: 설치 전 앱 삭제
- `-LaunchAfterInstall`: 설치 직후 앱 실행
- `-OpenOutput`: APK 파일 위치를 탐색기에서 열기
- `-Target`: 빌드 엔트리포인트 파일 지정
- `-Flavor`: flavor 빌드
- `-SplitPerAbi`: ABI 분리 APK 빌드
- `-DartDefine`: `--dart-define` 전달 (여러 개 가능)
- `-ExtraBuildArg`: 추가 빌드 인자 전달 (여러 개 가능)
- `-ListDevicesOnly`: adb 기기 목록만 출력

## 4) 예시: Dart define 여러 개

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_dev_apk.ps1 `
  -BuildMode release -Install -PromptDevice `
  -DartDefine APP_ENV=dev,HUD=true `
  -ExtraBuildArg --verbose
```
