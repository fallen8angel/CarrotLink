# CarrotLink 전체 코드 구조 정밀 분석 (2026-02-26)

최종 분석일: 2026-02-26  
분석 대상 경로: `/mnt/e/CarrotLink/CarrotLink`

이 문서는 CarrotLink 저장소 전체(앱 코드, 서비스 계층, 주요 화면, 운영 스크립트, 문서)의 구조를 정밀 분석한 결과를 정리한다. 기존 `docs/MASTER_DEVELOPMENT_GUIDE_KO.md`와 `docs/architecture/DEV_STRUCTURE_REFACTOR_2026-02-26.md`를 참고하되, 실제 코드 구현 기준으로 재확인한 내용 중심으로 작성했다.

## 1. 한눈 요약

- 프로젝트 성격: Flutter 기반 Android 중심 운영 앱 (openpilot 장치 원격 관리/백업/로그/파일 탐색기)
- 핵심 아키텍처: `Provider` 기반 전역 서비스 + 탭 중심 UI + SSH/GitHub/Google Drive 연동
- 실제 운영 허브: `lib/services/ssh_service.dart` (연결/명령/SFTP/탐색/heartbeat)
- 오케스트레이터 화면: `lib/screens/dashboard_screen.dart` (자동 연결/재시도/디스커버리/업데이트/백업 모니터 시작)
- 복잡도 집중 영역:
  - `lib/screens/backup_manager_screen.dart` (1390 LOC)
  - `lib/screens/tabs/file_explorer/file_explorer_controller.dart` (1170 LOC)
  - `lib/services/ssh_service.dart` (1002 LOC)
  - `lib/services/github_service.dart` (816 LOC)
- 구조적 강점:
  - 서비스 중심 분리
  - `ConnectionSettings` 분할(part+extension) 적용
  - `DeviceActionService`로 Git/System 액션 명령 중앙화
  - 파일 탐색기 컨트롤러-UI 분리와 전송 일시정지/취소/재시도 지원
- 주요 리스크:
  - 민감정보 저장 전략(토큰 미러 파일, private gist 저장)
  - `UpdateService` APK 다운로드 메모리 버퍼링
  - `BackupManagerScreen` 복원 명령의 shell quoting 취약점 가능성
  - Android release 서명이 debug key로 설정됨

## 2. 저장소 구조 개요

### 2.1 최상위 폴더 역할

- `lib/`: 앱 핵심 코드 (UI, 서비스, 위젯, 테마)
- `docs/`: 개발/운영/구조 문서
- `scripts/`: PowerShell 기반 빌드/설치 자동화 스크립트
- `tools/windows/`: CMD 래퍼(원클릭 실행)
- `android/`: Android 빌드/권한/서비스 선언
- `ios/`, `macos/`, `linux/`, `windows/`, `web/`: Flutter 플랫폼 스캐폴딩
- `test/`: 최소 수준 테스트/실험성 테스트

### 2.2 `lib/` 규모(정량)

- 총 Dart 코드 라인 수(`lib/`): 약 **17,164 LOC**
- 화면/탭/UI 파일 비중이 높고, 서비스 계층도 상당히 큼

상위 대형 파일(LOC 기준):

- `lib/screens/backup_manager_screen.dart` (1390)
- `lib/screens/tabs/file_explorer/file_explorer_controller.dart` (1170)
- `lib/services/ssh_service.dart` (1002)
- `lib/services/github_service.dart` (816)
- `lib/widgets/drive_list_widget.dart` (717)
- `lib/screens/tabs/file_explorer_tab.dart` (717)
- `lib/screens/dashboard_screen.dart` (603)
- `lib/screens/github_login_screen.dart` (592)

## 3. 런타임 아키텍처 (앱 시작부터 탭 진입까지)

### 3.1 앱 초기화 흐름

진입점은 `lib/main.dart`다.

핵심 초기화 순서:

1. `WidgetsFlutterBinding.ensureInitialized()`
2. `initializeDateFormatting('ko_KR')`
3. `initializeService()` 호출 (백그라운드 서비스 초기화, 비동기 fire-and-forget)
4. `StorageLayoutService.instance.ensureBaseFolders()` 비동기 시작
5. 백그라운드 서비스 `exitApp` 이벤트 리스너 등록
6. 세로 화면 고정
7. `MultiProvider`로 전역 서비스 주입 후 `CarrotLinkApp` 실행

### 3.2 전역 Provider 구성

`lib/main.dart`에서 등록되는 전역 서비스:

- `SSHService`
- `MacroService`
- `GoogleDriveService`
- `BackupService`
- `UpdateService`
- `DiagnosticsService.instance` (singleton)

의미:

- 연결/명령/파일전송/탐색 상태는 앱 전역 공유 (`SSHService`)
- 백업/업데이트/UI 토스트/진단 로그가 탭 간 일관성 유지 가능

### 3.3 첫 화면 분기

`lib/screens/splash_screen.dart`:

- `PackageInfo`로 버전 표시
- `SharedPreferences('is_first_run')` 검사
- Android 권한 상태 검사
- 조건에 따라 `PermissionScreen` 또는 `DashboardScreen`으로 이동

`lib/screens/permission_screen.dart`:

- Android 권한 3종 관리
  - 알림
  - 배터리 최적화 제외
  - 저장소 접근 (Manage External Storage/Legacy)
- 완료 시 `StorageLayoutService.ensureBaseFolders()` 호출
- 최초 실행이면 `is_first_run = false` 저장 후 대시보드 이동

## 4. 핵심 아키텍처 지도 (서비스 중심)

### 4.1 가장 중요한 허브: `SSHService`

`lib/services/ssh_service.dart`는 사실상 앱의 코어 런타임이다.

책임:

- SSH 연결/인증(비밀번호, PEM 키)
- 연결 상태 관리 및 heartbeat
- 명령 실행(`executeCommandResult`)
- 명령 직렬화 큐(`_enqueueCommand`)
- 스트리밍 명령 실행(`executeCommandStream`)
- 인터랙티브 shell 세션(`startShell`)
- SFTP CRUD/read/write/upload/download
- IP discovery (UDP + subnet scan)
- Git 업데이트 여부 확인
- background service와 상태 동기화

구조적 특징:

- foreground와 background에 각각 SSH 연결이 존재할 수 있음 (복잡도 상승 요인)
- heartbeat가 `_runningCommandCount`를 참조해 겹침 최소화
- discovery에 generation 개념을 둬 이전 세션 이벤트를 무시함
- `manualDisconnectRequested` 쿨다운(2분)으로 자동 재연결 억제

### 4.2 GitHub 계층: `GitHubService`

`lib/services/github_service.dart` 책임:

- GitHub Device Flow OAuth 시작/토큰 polling
- 토큰 저장/검증/삭제 (`flutter_secure_storage` + 파일 미러)
- GitHub public SSH keys 목록/등록/삭제
- 관리용 private gist 기반 SSH keyring 관리 (개인키 포함)
- 개인키 PEM에서 공개키/지문 추출

핵심 설계 포인트:

- 토큰 스코프 검증(`admin:public_key`, `gist`)
- 토큰 미러 파일(`StorageLayoutService.authPath`)로 secure storage 실패 대비
- gist keyring으로 다기기 개인키 복원 워크플로우 지원

### 4.3 백업 계층

구성:

- `BackupService`: openpilot params 변경 감지 + JSON 백업 + Drive 업로드 + 동기화
- `GoogleDriveService`: Google Sign-In + Drive 폴더 생성/업로드/목록/다운로드/삭제
- `KeyBackupService`: SSH 개인키 로컬 백업/복원(체크섬 검증 포함)
- `StorageLayoutService`: `/storage/emulated/0/CarrotLink/{auth,routes,logs,fleet,app,tmp}` 구조 생성

`BackupService` 동작 방식:

- 주기 타이머 + SSH 연결 리스너 기반 모니터링
- `/data/params/d` 파일 해시(md5 체인) 비교로 변경 감지
- `manager.py`에서 `default_params` 파싱 후 백업 대상 키 목록 결정
- 로컬 JSON 저장 후 Google Drive 자동 업로드(로그인 상태일 때)

### 4.4 액션 계층: `DeviceActionService`

`lib/services/device_action_service.dart`는 Git/시스템 작업의 명령 정의 레이어다.

장점:

- `GitTab`, `SystemTab`에서 shell 스크립트 직접 조합 중복 제거
- repo 탐지 스크립트 중앙화 (`/data/openpilot`, `/home/comma/openpilot`)
- 브랜치명 sanitize 처리
- 액션별 timeout 차등 설정
- 결과를 `DeviceActionResult`로 표준화

### 4.5 기타 서비스

- `DiagnosticsService`: 앱 내부 진단 로그 메모리 버퍼(최대 200개) + export/clear
- `UpdateService`: GitHub Releases 기반 APK 업데이트 검사/다운로드/설치
- `MacroService`: 사용자 커스텀 매크로 CRUD + 기본 매크로 세트
- `SSHKeyHelper`: RSA 키 생성, PEM/SSH 공개키 인코딩, 비밀번호 기반 기기 키 설치
- `background_service.dart`: foreground service notification + 별도 SSH 연결 유지 + 명령 실행/상태 전달

## 5. 화면 계층 구조 분석

### 5.1 최상위 셸: `DashboardScreen`

`lib/screens/dashboard_screen.dart`는 단순 탭 컨테이너를 넘어서 앱 운영 정책의 중심이다.

담당 기능:

- 권한 재요청/백그라운드 서비스 시작
- 자동 연결 루프 (2초 주기)
- 네트워크 변경 감지(`connectivity_plus`) 후 debounce 재연결
- SSH discovery stream 수신 후 자동 연결 시도
- openpilot 대상 검증 (`/data/openpilot`, params 파일 확인)
- 업데이트 체크 및 업데이트 다이얼로그
- 백업 모니터 시작
- 초기 설정 미완료(GitHub 로그인/SSH 키 없음) 시 연결 설정 유도

구조 평가:

- 강력한 오케스트레이터 역할을 잘 수행하지만 파일 크기(603 LOC)가 커서 정책 분리 여지 있음

### 5.2 홈 탭: `HomeTab`

`lib/screens/tabs/home_tab.dart`

주요 역할:

- SSH 연결 상태/브랜치/커밋/기기 ID 표시
- GitHub 로그인/활성 SSH 키 상태 체크
- 백업 상태 칩 및 백업 관리자 진입
- Google Drive 연동 토글

특징:

- `BackupService.startMonitoring()`를 여기서도 호출 (대시보드에서도 호출됨)
- 30초 상태 갱신 타이머 + 2초 prerequisite 확인 타이머

### 5.3 Git 탭: `GitTab`

`lib/screens/tabs/git_tab.dart`

역할:

- Git 작업 실행 UI (브랜치 선택/pull/reset/sync/reboot)
- 명령 로그 기록/보관 (`SharedPreferences('git_logs')`)
- 브랜치 다이얼로그에서 remote/local ref 비교 및 업데이트 표시

핵심 연계:

- `DeviceActionService.loadGitBranchSnapshot()`
- `DeviceActionService.runAction()`

### 5.4 관리 탭: `SystemTab`

`lib/screens/tabs/system_tab.dart`

역할:

- 재부팅/소프트재시작/재빌드/데이터 삭제 등 관리 액션 UI
- 액션 실행 전 확인 다이얼로그
- 결과 로그(명령어/stdout/stderr/exit code)를 상세 다이얼로그로 표시

장점:

- 사용자에게 실제 실행 스크립트를 long-press로 미리 보여줌

### 5.5 터미널 탭: `TerminalTab` + `TerminalScreen`

`lib/screens/tabs/terminal_tab.dart`

구성:

- 하위 탭 3개: 터미널 / 매크로 / 파일
- `TerminalScreen`는 `xterm` 기반 SSH shell 세션 UI

특징:

- SSH 재연결 감지 시 터미널 세션 자동 재부착 시도
- 가상 키보드(ESC/TAB/CTRL+C/화살표 등)
- 매크로 빠른 실행 버튼
- 폰트 크기 저장 (`terminal_font_size`)

### 5.6 로그 탭: `LogsTab`

`lib/screens/tabs/logs_tab.dart`

하위 탭:

- 대시캠녹화: `DriveListWidget` (route/segment 중심)
- 화면녹화: `_RemoteVideoLogsView` (여러 폴더 후보 탐색)
- TMUX: `_TmuxLogsView` (주기 polling + capture-pane)

특징:

- tmux 로그는 3초 간격 live polling, 표시 줄 수 제한(350줄)
- screenrecord 영상 폴더 후보를 순차 탐색

### 5.7 파일 탐색기: `FileExplorerTab` + `FileExplorerController`

구조적으로 가장 잘 분리된 영역 중 하나.

`lib/screens/tabs/file_explorer_tab.dart`:

- UI 이벤트 처리(다이얼로그, 토스트, 파일 픽커, 화면 전환)
- 컨트롤러 바인딩/AnimatedBuilder 렌더링

`lib/screens/tabs/file_explorer/file_explorer_controller.dart`:

- 상태 모델(현재 경로, 검색, 정렬, 북마크, 선택, 클립보드, 배치 상태)
- SFTP/SSH 명령 조합 로직
- 배치 다운로드/업로드/폴더 업로드
- 진행률 throttle, pause/cancel/retry

세부 기능:

- 북마크 관리 (`SharedPreferences`)
- 다중선택/복사/잘라내기/붙여넣기
- tar 압축/압축해제
- 디렉터리 다운로드 시 원격 tar 생성 후 다운로드
- 실패 전송 재시도 액션 유지
- lazy render (`visibleFiles`, load more)

보조 위젯:

- `file_explorer_top_toolbar.dart`
- `file_explorer_file_list_view.dart` (TreeView 기반 + load-more tile)
- `file_explorer_bottom_bar.dart`
- `file_editor_screen.dart` (텍스트 편집기)

### 5.8 백업 관리자: `BackupManagerScreen`

`lib/screens/backup_manager_screen.dart`는 기능이 매우 많아 현재 최대 파일이다.

주요 기능:

- 로컬/클라우드 백업 탭
- 다중 선택 삭제
- 백업 상세 보기
- 수동 백업 생성
- Google Drive 업로드/다운로드/삭제
- 백업 diff 비교 후 선택 복원
- 마지막 복원 파일 추적 (`last_restored_backup`)

구조 평가:

- 실제 사용자 가치가 높지만 UI/데이터 처리/복원 로직이 하나의 StatefulWidget에 몰림
- 향후 `local/cloud/restore diff/ui` 단위 분리 가치가 큼

### 5.9 설정 영역 (분리 리팩터 반영 상태)

`lib/screens/settings/` 구성은 문서와 실제 구현이 일치한다.

핵심:

- `connection_settings_screen.dart` (state + lifecycle + part 선언)
- `connection_settings_persistence.dart`
- `connection_settings_keys.dart`
- `connection_settings_auth.dart`
- `connection_settings_discovery.dart`
- `connection_settings_widgets.dart`

평가:

- 문서(`docs/architecture/DEV_STRUCTURE_REFACTOR_2026-02-26.md`)의 분리 의도가 실제 코드에도 잘 반영됨
- 인증/키/저장/디스커버리/UI 책임이 비교적 명확

## 6. `ConnectionSettings` 워크플로우 정밀 분석

### 6.1 목적

- GitHub 로그인
- SSH 키 생성/적용/복원
- openpilot 기기 디스커버리
- 수동 연결

### 6.2 로그인 이후 키 상태 동기화 전략

`_syncKeyStateAfterLogin()` 흐름:

1. GitHub 공개키 목록 로드 시도
2. 실패 시 로컬 백업 키만 복원 시도
3. 활성 키가 있으면 원격 GitHub 키와 매칭/붙이기 + gist 동기화
4. 활성 키 없으면
   - managed gist 복원
   - 로컬 백업 + GitHub 동기화 복원
   - 로컬에 있는 생성키 재활성화

이 설계는 "재설치/다기기/토큰 만료" 시나리오에 강함.

### 6.3 키 저장 전략 (호환성 포함)

신규/현재 키:

- `current_key_type`
- `current_private_key`
- `active_generated_id`
- `generated_key_<id>`
- `generated_pub_<id>`

호환성 유지용 구키:

- `private_key_<id>`
- `public_key_<id>`
- `active_key_id` (마이그레이션 소스)
- `user_private_key` (legacy)

### 6.4 디스커버리 연동

`connection_settings_discovery.dart`는 `SSHService.startDiscovery()`를 감싸며:

- 조건 충족 시 자동 디스커버리 시작
- 수동 디스커버리 모드에서 IP autofill + 중복 토스트 억제
- 최근 진단 로그 snippet 기반 실패 로그 다이얼로그 제공

## 7. 데이터 저장 구조 (SecureStorage / SharedPreferences / 파일시스템)

### 7.1 SecureStorage 중심 키 (핵심 연결/인증)

주요 키:

- `github_token`
- `ssh_ip`, `ssh_port`, `ssh_username`, `ssh_password`
- `current_private_key`, `current_key_type`, `active_generated_id`
- `generated_key_<id>`, `generated_pub_<id>`

### 7.2 SharedPreferences 중심 키 (UI/설정/기록)

주요 키:

- `is_first_run`
- `backup_interval_minutes`
- `git_logs`
- `share_convert_mp4`
- `terminal_font_size`
- `update_channel`
- `ignore_update_until`
- `last_check_time`, `last_backup_time`
- `last_restored_backup`

### 7.3 외부 저장소 디렉터리

`StorageLayoutService` 기준 Android 공용 경로:

- `/storage/emulated/0/CarrotLink/auth`
- `/storage/emulated/0/CarrotLink/routes`
- `/storage/emulated/0/CarrotLink/logs`
- `/storage/emulated/0/CarrotLink/fleet`
- `/storage/emulated/0/CarrotLink/app`
- `/storage/emulated/0/CarrotLink/tmp`

활용 예:

- GitHub 토큰 미러 파일
- SSH 개인키 백업 파일
- 다운로드(일부 기능)

## 8. 의존성 결합도 분석 (정량)

로컬 import 기준 inbound 상위:

- `lib/services/ssh_service.dart` : 14개 파일에서 참조
- `lib/widgets/custom_toast.dart` : 12개 파일에서 참조
- `lib/widgets/design_components.dart` : 4개 파일에서 참조
- `lib/screens/tabs/file_explorer/file_explorer_controller.dart` : 4개 파일에서 참조

의미:

- `SSHService`는 의도대로 코어 허브
- `CustomToast`는 UI 전역 공통 피드백 레이어
- `file_explorer_controller`는 UI 내부 재사용 구조가 잘 잡힘

outbound(로컬 import) 상위:

- `connection_settings_screen.dart`, `home_tab.dart`, `file_explorer_tab.dart` (각 7개)

의미:

- 이 파일들은 "조립/오케스트레이션" 성격이 강함

## 9. 플랫폼/빌드/운영 스크립트 분석

### 9.1 Android Manifest 특징

`android/app/src/main/AndroidManifest.xml`에서 확인된 주요 권한:

- 네트워크/포그라운드 서비스/부팅 수신
- 알림 권한
- 배터리 최적화 제외 요청
- 설치 패키지 요청
- 전체 외부저장소 관리 (`MANAGE_EXTERNAL_STORAGE`)

백그라운드 서비스 선언:

- `id.flutter.flutter_background_service.BackgroundService`
- `foregroundServiceType="dataSync"`

### 9.2 Android Gradle 설정 특징

`android/app/build.gradle.kts`:

- `com.google.gms.google-services` 플러그인 사용
- Java/Kotlin 17
- release 빌드가 debug signing 사용 (중요 리스크)
- `applicationId = "com.example.carrot_pilot_manager"` (플레이스토어/배포 단계에서는 정리 필요)

### 9.3 운영 스크립트 체계

Windows 기준 운영 편의성이 잘 정리되어 있음:

- `scripts/build_dev_apk.ps1`: 빌드/설치 핵심 스크립트
- `scripts/apk_menu.ps1`: 메뉴형 실행
- `tools/windows/*.cmd`: PowerShell 래퍼(원클릭)

문서 연계도 좋음:

- `docs/operations/APK_SCRIPT_USAGE_KO.md`
- `docs/operations/TERMINAL_BUILD_INSTALL_COMMANDS_KO.md`
- `docs/operations/GIT_SYSTEM_TAB_SSH_COMMANDS_KO.md`

## 10. 구조적 강점 (구현 기준)

1. 서비스 중심 아키텍처가 실제로 잘 작동함

- UI가 SSH/GitHub/Backup 등 핵심 로직을 대부분 서비스에 위임
- 탭 간 상태 공유가 자연스러움

2. `ConnectionSettings` 분할이 성공적임

- 인증/키/저장/디스커버리/UI를 `part`로 분리
- 향후 수정 위치 판단이 쉬움

3. `DeviceActionService` 도입 품질이 좋음

- Git/System 액션 명령이 중앙화되어 회귀 위험 감소
- sanitize/timeout/결과 구조화까지 포함

4. 파일 탐색기 설계 완성도가 높음

- 컨트롤러와 UI 분리
- 배치 전송 진행률/일시정지/취소/재시도
- 탐색/검색/정렬/선택/클립보드/압축 기능 통합

5. 운영 문서/스크립트가 실제 코드와 상당히 맞물려 있음

- 문서가 단순 설명이 아니라 유지보수 가이드로 활용 가능 수준

## 11. 주요 리스크 및 개선 우선순위 (정밀 리뷰)

### 11.1 보안/민감정보 저장 리스크 (우선순위 높음)

1. GitHub 토큰 미러 파일 저장

- `GitHubService`가 secure storage 외에 외부 저장소(`CarrotLink/auth`)에 토큰 미러를 저장함
- 운영 복원성에는 유리하지만, 기기 접근 시 노출면이 커짐

권장:

- 기본 비활성화 + 복구 모드에서만 opt-in
- 최소한 파일 권한/암호화 전략 도입 검토

2. private gist에 개인키 저장

- managed keyring gist에 `privateKeyPem` 저장
- 복원 UX는 매우 좋지만, GitHub 계정 탈취 시 SSH 개인키도 함께 노출

권장:

- passphrase 기반 암호화 후 gist 저장
- 또는 로컬 백업만 기본, gist는 선택 기능으로 명확 분리

### 11.2 데이터 무결성/쉘 인젝션 리스크 (우선순위 높음)

1. 백업 복원 시 값 쓰기 방식

- `BackupManagerScreen._performRestore()`에서 `echo -n "$value" > /data/params/d/$key`
- 값에 `"`, `$`, 백슬래시, 개행이 포함되면 손상 또는 의도치 않은 shell 확장 가능성

권장:

- base64 인코딩 후 원격에서 decode하여 파일 쓰기
- 또는 SFTP write API 사용

2. 백업 diff/current params 수집 방식

- `grep -r . /data/params/d/`는 binary/NULL/newline 값 처리에 취약
- 일부 params는 텍스트 가정이 깨질 수 있음

권장:

- 키별 안전 읽기(현재 `BackupService` 배치 읽기 방식 재사용)
- 바이너리 값은 base64 비교로 분리

### 11.3 메모리/성능 리스크 (우선순위 중간)

1. `UpdateService.downloadUpdate()`

- APK 다운로드를 `List<int> bytes`에 전부 모은 뒤 파일 저장
- 대용량 APK에서 메모리 사용량 급증 가능

권장:

- 스트림을 파일 sink로 직접 pipe

2. `BackupService.createBackup()` 대용량 stdout 처리

- 배치 읽기 결과를 한 번에 문자열로 받아 파싱
- params 수/값 크기 증가 시 메모리 부담 증가

권장:

- 청크 기반 파싱 또는 키 수/출력 크기 안전장치

3. `HomeTab`의 2초 간격 secure storage polling

- GitHub 로그인/키 상태 확인을 2초마다 `FlutterSecureStorage` read
- 필요 이상 polling 가능성

권장:

- `DiagnosticsService`/`SSHService` 또는 `ValueNotifier` 이벤트 기반 갱신
- 최소 10~30초로 완화

### 11.4 아키텍처/복잡도 리스크 (우선순위 중간)

1. 백그라운드 서비스와 foreground SSH 이중 연결

- `SSHService` + `background_service.dart` 각각 SSH 클라이언트 관리
- 상태 불일치/중복 heartbeat/디버깅 난이도 상승

권장:

- 역할 분리 문서화 강화 (foreground = UI/SFTP, background = heartbeat/notification 등)
- 장기적으로 단일 연결 전략 검토

2. 대형 단일 파일 유지비용

- `backup_manager_screen.dart`, `ssh_service.dart`, `github_service.dart`가 매우 큼

권장:

- `BackupManager`: local/cloud/restore/ui로 분리
- `SSHService`: connection/command/sftp/discovery/git-status mixin or subservice 분리
- `GitHubService`: oauth, public-key, gist-keyring, crypto helper 분리

### 11.5 배포/운영 리스크 (우선순위 높음)

1. release signing이 debug 키 사용

- `android/app/build.gradle.kts` release 빌드가 debug signing
- 내부 테스트에는 편하지만 실제 배포 체계에는 부적절

2. `applicationId`/namespace가 example 값 유지

- 브랜딩/배포/스토어 등록 시 기술 부채

## 12. 잠재적 중복/레거시 흔적

- `lib/theme/app_theme.dart` 존재하지만 `main.dart`에서 별도 ThemeData를 직접 구성 (미사용 가능성 높음)
- `lib/screens/github_verification_screen.dart`는 현재 `GithubLoginScreen` 기반 흐름으로 대체된 흔적(참조 없음)
- `lib/widgets/video_list_widget.dart`는 `LogsTab` 현재 구현에서 직접 사용되지 않음
- `ConnectionSettingsScreen`에 `_usernameController`, `_passwordController`, `_portController`가 남아 있으나 UI는 IP+키 기반 고정 연결 중심

레거시를 완전히 제거하기보다는 문서화 후 단계적으로 정리하는 것이 안전하다.

## 13. 테스트/분석 상태

### 13.1 자동 테스트

`test/` 현황:

- `widget_test.dart`: 앱 시작 smoke test 수준
- `ssh_key_check.dart`: 실험성/검증용 테스트 형태

평가:

- 핵심 로직(SSH/GitHub/키 복원/백업 파싱/버전 비교)에 대한 단위 테스트가 부족함

### 13.2 정적 분석 실행 가능 여부

분석 환경에서 `flutter` 명령을 찾을 수 없어 `flutter analyze` 실행 불가:

- 확인 결과: `/bin/bash: flutter: command not found`

따라서 본 문서는 정적 분석 결과가 아닌 코드 정독 기반 구조 분석이다.

## 14. 개선 로드맵 (권장 순서)

### Phase 1 (안전성 우선)

1. `BackupManagerScreen` 복원 쓰기 로직을 SFTP/base64 방식으로 변경
2. `UpdateService` 다운로드 스트리밍 저장으로 변경
3. release signing 설정 분리 및 `applicationId` 정리
4. 민감정보 저장 정책(토큰 미러/gist private key) 옵션화 및 경고 UI 추가

### Phase 2 (유지보수성)

1. `BackupManagerScreen` 파일 분할
2. `SSHService` 내부 모듈 분리 (connect/command/sftp/discovery)
3. `GitHubService` 기능 분할 (oauth/key/gist/crypto)
4. 레거시 UI/미사용 파일 정리 (`github_verification_screen.dart`, `video_list_widget.dart`, `app_theme.dart` 검토)

### Phase 3 (품질/테스트)

1. 단위 테스트 추가:
   - `UpdateService._isNewer`
   - `DeviceActionService._sanitizeBranch`
   - backup filename parser (`BackupManagerScreen._parseBackupInfo`)
   - key fingerprint/normalize helpers
2. integration smoke 테스트:
   - 설정 로그인 흐름(서비스 mocking)
   - 파일 탐색기 컨트롤러 상태 전환

## 15. 결론

CarrotLink는 단순 SSH 유틸리티를 넘어, openpilot 장치 운영(연결/업데이트/Git/시스템 제어/백업/로그/파일 탐색)을 통합한 실사용 앱 구조를 갖추고 있다. 특히 `SSHService`, `DashboardScreen`, `ConnectionSettings`, `FileExplorerController`의 조합이 제품의 핵심 경쟁력을 형성한다.

현재 가장 큰 과제는 "기능 추가"보다 "안전성/보안/복잡도 관리"이며, 이 문서의 우선순위 항목만 정리해도 유지보수 비용과 운영 리스크를 크게 낮출 수 있다.

