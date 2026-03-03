# CarrotLink-dev 마스터 개발/유지보수 가이드

최종 업데이트: 2026-02-26  
대상: `D:\CarrotLink\CarrotLink-dev`

이 문서는 CarrotLink-dev의 구조, 핵심 기능, 유지보수 방식, 코딩 기준을 한 번에 보는 기준 문서다.

## 1. 목표와 원칙

- 모든 기능 변경은 `dev`에서 먼저 작업하고 검증 후 `stable`로 이관한다.
- SSH/GitHub/Discovery 로직은 동작 안정성을 우선으로 유지한다.
- 화면(UI) 수정과 연결 로직 수정을 분리해 충돌/회귀를 줄인다.
- 신규 개발자는 이 문서를 기준으로 수정 위치를 먼저 결정한 뒤 코딩한다.

## 2. 프로젝트 구조

## 2.1 최상위 핵심 폴더

- `lib/`: 앱 코드
- `docs/`: 운영/구조/가이드 문서
- `scripts/`: PowerShell 자동화 스크립트
- `tools/windows/`: 원클릭 CMD 실행 도구
- `android/`: 안드로이드 빌드/서명 설정

## 2.2 `lib/` 구조

```text
lib/
  main.dart
  constants.dart
  screens/
    splash_screen.dart
    permission_screen.dart
    dashboard_screen.dart
    github_login_screen.dart
    github_verification_screen.dart
    settings_screen.dart        (barrel export)
    diagnostics_screen.dart
    settings/
      settings_home_screen.dart
      connection_settings_screen.dart
      connection_settings_auth.dart
      connection_settings_discovery.dart
      connection_settings_keys.dart
      connection_settings_persistence.dart
      connection_settings_widgets.dart
      backup_settings_screen.dart
      info_settings_screen.dart
      share_settings_screen.dart
    tabs/
      home_tab.dart
      git_tab.dart
      system_tab.dart
      terminal_tab.dart
      file_explorer_tab.dart
      file_editor_screen.dart
      macro_tab.dart
  services/
    ssh_service.dart
    github_service.dart
    key_backup_service.dart
    ssh_key_helper.dart
    diagnostics_service.dart
    background_service.dart
    backup_service.dart
    google_drive_service.dart
    macro_service.dart
    update_service.dart
  widgets/
  theme/
```

## 3. 핵심 기능 흐름

## 3.1 앱 시작 흐름

1. `main.dart`  
   Provider 등록 (`SSHService`, `BackupService`, `UpdateService` 등)
2. `splash_screen.dart`  
   최초 실행/권한 상태 체크
3. `permission_screen.dart` 또는 `dashboard_screen.dart` 진입
4. `dashboard_screen.dart`  
   자동 재연결 루프, 네트워크 변경 감지, 자동 탐색 트리거

## 3.2 openpilot SSH 준비 흐름 (권장 순서)

1. GitHub 로그인 완료 (`github_token`)
2. SSH 개인키 준비 (`current_private_key`)
3. 기기 검색/연결 (`ssh_ip`, `ssh_port`, `ssh_username`)

관련 UI는 `settings/connection_settings_*`에 분리되어 있다.

## 3.3 SSH 연결/검색 핵심

- 실연결/재연결/탐색 엔진: `services/ssh_service.dart`
- 설정 화면 오케스트레이션: `settings/connection_settings_discovery.dart`
- Dashboard 자동연결 정책: `screens/dashboard_screen.dart`

## 4. Connection Settings 파일 책임

- `connection_settings_screen.dart`  
  상태 필드, 라이프사이클, `part` 선언, `_setStateSafe` 공통 래퍼
- `connection_settings_persistence.dart`  
  설정 로드/저장, 키 마이그레이션, 백업 복원/상태
- `connection_settings_keys.dart`  
  수동키/생성키 적용, 활성키 해제, 키 삭제/선택
- `connection_settings_auth.dart`  
  GitHub 로그인/토큰 검증/키 생성 흐름
- `connection_settings_discovery.dart`  
  검색 세션, 연결 시도, 진단 팝업
- `connection_settings_widgets.dart`  
  연결 설정 화면 UI 빌드

원칙:
- UI 텍스트/버튼 변경만이면 `widgets`만 수정
- 저장소 키/복원 정책은 `persistence` 또는 `keys` 수정
- 인증/로그인은 `auth` 수정
- 검색/재연결 정책은 `discovery` + `ssh_service` 수정

## 5. 저장 데이터 키(중요)

자주 쓰는 키:

- `github_token`
- `ssh_ip`, `ssh_port`, `ssh_username`, `ssh_password`
- `current_key_type`, `current_private_key`, `active_generated_id`
- `generated_key_<id>`, `generated_pub_<id>`
- 호환성 키: `private_key_<id>`, `public_key_<id>`

주의:
- 키 저장 포맷을 바꿀 때는 마이그레이션 코드를 먼저 넣고, 기존 키를 바로 삭제하지 않는다.

## 6. 유지보수 작업 절차 (권장)

1. 변경 범위 정의: UI/인증/키/검색 중 어디인지 먼저 확정
2. 수정 파일 최소화: 책임 파일만 수정
3. 진단 로그 추가: `DiagnosticsService`로 핵심 이벤트 기록
4. 정적 분석: 최소 대상 파일 `flutter analyze`
5. 실제 시나리오 테스트: 아래 7장 체크리스트
6. dev 문서 업데이트
7. stable 반영(검증 완료 후)

## 7. 시나리오 테스트 체크리스트

## 7.1 신규 설치

- 권한 허용 후 대시보드 진입 가능
- 설정 > 연결에서 GitHub 로그인 가능
- 키 생성/적용 후 자동 검색 가능

## 7.2 재설치/재로그인

- 기존 키 백업 복원 동작
- 토큰 만료 시 재로그인 유도
- 키 중복 생성 없이 기존 키 재사용 가능한지 확인

## 7.3 네트워크 변동

- Wi-Fi 변경 후 자동 재연결 시도
- 연결 끊김 후 검색 재시작
- 수동 해제 시 쿨다운 동안 자동 재연결 억제

## 7.4 예외 상황

- GitHub 일시 오류(네트워크/서버)에서 앱 크래시 없는지
- 잘못된 키/잘못된 IP 입력 시 사용자 메시지 확인

## 8. 코딩 가이드

## 8.1 기본

- 파일 책임을 넘는 수정 금지
- 큰 파일은 기능 단위 분리 유지
- 동작 변경이 없으면 리팩토링만 수행
- 하드코딩 문자열/키 이름은 가능한 중앙화

## 8.2 비동기/상태

- 비동기 후 UI 갱신 전 `mounted` 확인
- ConnectionSettings에서는 직접 `setState` 대신 `_setStateSafe` 사용
- `BuildContext` async-gap 경고는 실제 크래시 가능 구간 우선 해소

## 8.3 로그/진단

- `print` 대신 `DiagnosticsService` 우선
- 카테고리 예: `ssh`, `discovery`, `github`, `autoconnect`
- 장애 재현 시점의 입력값(IP, 포트, 토큰 유무, 키 유무)을 남긴다

## 8.4 보안

- 개인키/토큰을 로그에 원문 출력 금지
- 개인키는 최소 범위에서만 복사/전달
- 토큰 삭제 시 로컬 상태도 함께 초기화

## 9. dev -> stable 이관 규칙

1. dev에서 기능/버그 수정
2. 정적 분석 + 실기기 시나리오 검증
3. 관련 문서 업데이트
4. stable에 선택 이관 (기능 단위로)
5. stable에서 최소 재검증

권장:
- 한 번에 큰 묶음 이관보다 기능 단위 이관
- SSH/GitHub/탐색은 항상 묶어서 회귀 테스트

## 10. 빌드/설치 문서

자세한 빌드/설치 명령은 아래 문서 참조:

- `docs/operations/APK_SCRIPT_USAGE_KO.md`
- `docs/operations/TERMINAL_BUILD_INSTALL_COMMANDS_KO.md`

## 11. 빠른 수정 가이드 (어디를 고칠지)

- “GitHub 로그인은 되는데 키 동기화가 안 됨”  
  `github_service.dart`, `connection_settings_auth.dart`, `connection_settings_persistence.dart`
- “IP 검색 버튼이 동작 안 함”  
  `connection_settings_discovery.dart`, `ssh_service.dart`
- “연결 후 끊기고 재연결 안 됨”  
  `dashboard_screen.dart`, `ssh_service.dart`
- “설정 화면 문구/버튼/레이아웃만 변경”  
  `connection_settings_widgets.dart`, `settings_home_screen.dart`

## 12. 문서 운영 규칙

- 구조 변경 시 이 문서를 같은 날 갱신
- 변경 보고서는 `docs/architecture/`에 누적
- 운영 명령/스크립트 변경은 `docs/operations/` 갱신

