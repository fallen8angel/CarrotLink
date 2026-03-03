# APK 빌드/설치 스크립트 사용법 (Dev)

프로젝트 기준 경로: `D:\CarrotLink\CarrotLink-dev`

## 1) 완전 원클릭 (권장)
- 파일: `tools\windows\oneclick_release_build_install.cmd`
- 동작: Release APK 빌드 -> adb 업데이트 설치(`-r`, 삭제 없음)
- 사용: 더블클릭

## 2) 기존 APK만 빠른 설치
- 파일: `tools\windows\oneclick_install_existing_release.cmd`
- 동작: 빌드 생략 -> 기존 `app-release.apk`를 adb 업데이트 설치
- 사용: 더블클릭

## 3) 메뉴형 실행
- 파일: `tools\windows\apk_menu.cmd`
- 동작: 메뉴에서 빌드/설치/재설치/경로열기 선택
- 사용: 더블클릭

## 4) 핵심 PowerShell 스크립트
- 파일: `scripts\build_dev_apk.ps1`
- 주요 옵션:
  - `-BuildMode release|debug|profile`
  - `-Install` : 설치까지 진행
  - `-SkipBuild` : 빌드 생략
  - `-OpenOutput` : 탐색기에서 APK 선택 표시
  - `-PromptDevice` : 다중 adb 기기 연결 시 번호 선택
  - `-NoPause` : 종료 대기 없이 바로 종료

예시:
```powershell
powershell -ExecutionPolicy Bypass -File D:\CarrotLink\CarrotLink-dev\scripts\build_dev_apk.ps1 -BuildMode release -Install -PromptDevice
```

추가 예시(테스트용):
```powershell
# debug 설치
powershell -ExecutionPolicy Bypass -File D:\CarrotLink\CarrotLink-dev\scripts\build_dev_apk.ps1 -BuildMode debug -Install

# profile 설치
powershell -ExecutionPolicy Bypass -File D:\CarrotLink\CarrotLink-dev\scripts\build_dev_apk.ps1 -BuildMode profile -Install
```
