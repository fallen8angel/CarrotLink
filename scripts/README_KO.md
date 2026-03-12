# CarrotLink Scripts

`scripts/build_dev_apk.ps1`와 `scripts/apk_menu.ps1`는 Android APK 빌드/설치 자동화를 위한 스크립트입니다.

`scripts/export_yolo_executorch.py`는 로컬 `yolo26n.pt`, `yolo26s.pt` 같은 Ultralytics 가중치를 ExecuTorch `.pte`로 export하고, 생성된 `.pte`를 `assets/models`로 복사하는 보조 스크립트입니다.

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

## 5) YOLO -> ExecuTorch export

기본 `416x416`, batch 1로 `yolo26n.pt`를 export하고 앱 asset 경로까지 복사:

```powershell
python .\scripts\export_yolo_executorch.py .\scripts\yolo26n.pt
```

`yolo26n.pt`, `yolo26s.pt`를 같이 export:

```powershell
python .\scripts\export_yolo_executorch.py .\scripts\yolo26n.pt .\scripts\yolo26s.pt
```

주의:

- 현재 Ultralytics ExecuTorch export는 `torch>=2.9.0`, Python `executorch==1.0.0`, `flatbuffers`, `setuptools<71.0.0` 환경이 필요합니다.
- 앱 Android runtime AAR과 Python export runtime은 별개이므로, export는 전용 venv에서 돌리는 편이 안전합니다.
- Windows에서는 `flatc.exe`가 필요합니다. 스크립트는 아래 순서로 찾습니다.
  - `--flatc <path>`
  - `FLATC_EXECUTABLE`
  - `tools/flatbuffers/flatc.exe`
- 예시 전용 venv:

```powershell
python -m venv .venv-yolo-export
.\.venv-yolo-export\Scripts\python.exe -m pip install --upgrade pip
.\.venv-yolo-export\Scripts\python.exe -m pip install "setuptools<71.0.0" flatbuffers executorch==1.0.0 "torch>=2.9.0" "ultralytics[export]"
.\.venv-yolo-export\Scripts\python.exe -m pip install ultralytics==8.3.234 --no-deps
```
