# CarrotLink Dev 빌드/설치 터미널 명령어

기준 경로: `D:\CarrotLink\CarrotLink-dev`

## 1) 프로젝트 폴더 이동

```powershell
cd D:\CarrotLink\CarrotLink-dev
```

## 2) ADB 무선 연결 (pair/connect) 필요한 경우

휴대폰(개발자 옵션)에서 **무선 디버깅 > 기기 페어링** 정보 확인 후 실행:

```powershell
adb pair <폰IP:PAIR포트>
# 예: adb pair 192.168.0.25:37099
```

비밀번호/코드 입력 후, 실제 디버깅 포트로 연결:

```powershell
adb connect <폰IP:ADB포트>
# 예: adb connect 192.168.0.25:41237
```

연결 확인:

```powershell
adb devices
```

`device` 상태로 보여야 설치 가능.

## 3) 가장 쉬운 방식: 스크립트로 릴리즈 빌드 + 설치

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_dev_apk.ps1 -BuildMode release -Install
```

창 자동 종료가 싫으면(기본은 대기), 그대로 쓰면 됨.

## 4) 빌드 없이 기존 APK만 빠르게 설치

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_dev_apk.ps1 -BuildMode release -SkipBuild -Install
```

## 5) Debug/Profile 빌드 + 설치 (테스트용)

Debug:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_dev_apk.ps1 -BuildMode debug -Install
```

Profile:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_dev_apk.ps1 -BuildMode profile -Install
```

주의:
- `debug/profile`은 테스트용.
- 기존 배포앱 업데이트 설치(동일 서명 유지) 목적이면 `release` 권장.

## 6) 스크립트 없이 수동 빌드 + 설치

릴리즈 빌드:

```powershell
C:\flutter\bin\flutter.bat build apk --release
```

설치(삭제 없이 업데이트):

```powershell
adb install -r D:\CarrotLink\CarrotLink-dev\build\app\outputs\flutter-apk\app-release.apk
```

## 7) 여러 기기 연결 시 특정 기기 지정 설치

```powershell
adb devices
adb -s <device_serial> install -r D:\CarrotLink\CarrotLink-dev\build\app\outputs\flutter-apk\app-release.apk
```

## 8) 자주 나는 오류 체크

1. `adb devices`가 비어있음  
   - `adb pair` + `adb connect`를 다시 수행

2. `offline` 또는 `unauthorized`  
   - `adb disconnect` 후 다시 `adb connect`  
   - 폰에서 디버깅 승인 팝업 허용

3. `flutter` 명령 못 찾음  
   - `C:\flutter\bin\flutter.bat` 절대경로로 실행
