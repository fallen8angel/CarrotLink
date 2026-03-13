# CarrotLink-dev 서비스 계층

## 서비스 목록 전체

총 **20개** 서비스 파일이 `lib/services/` 에 존재합니다.

| # | 서비스 | 크기 | 카테고리 |
|---|--------|------|---------|
| 1 | `sidecar_service.dart` | 51KB | 핵심 |
| 2 | `ssh_service.dart` | 39KB | 핵심 |
| 3 | `background_service.dart` | 28KB | 시스템 |
| 4 | `github_service.dart` | 27KB | Git |
| 5 | `link_hud_service.dart` | 23KB | HUD |
| 6 | `device_action_service.dart` | 23KB | 기기 제어 |
| 7 | `backup_service.dart` | 20KB | 백업 |
| 8 | `update_service.dart` | 11KB | 업데이트 |
| 9 | `ssh_key_helper.dart` | 11KB | SSH |
| 10 | `carrot_profile_service.dart` | 10KB | 설정 |
| 11 | `key_backup_service.dart` | 7KB | 백업 |
| 12 | `macro_service.dart` | 5KB | 터미널 |
| 13 | `carrot_profile_compare_service.dart` | 4KB | 설정 |
| 14 | `google_drive_service.dart` | 4KB | 클라우드 |
| 15 | `carrot_server_settings_service.dart` | 3KB | 설정 |
| 16 | `storage_layout_service.dart` | 2KB | 시스템 |
| 17 | `native_overlay_hud_service.dart` | 2KB | HUD |
| 18 | `diagnostics_service.dart` | 2KB | 진단 |
| 19 | `github_oauth_ui_service.dart` | 2KB | Git |
| 20 | `hud_drive_settings_service.dart` | 1KB | HUD |

---

## 핵심 서비스 상세

### 1. SSHService (39KB)

**역할:** comma 디바이스와의 SSH 연결을 관리하는 핵심 서비스

- SSH 세션 생성/유지/종료
- 명령 실행 및 결과 수신
- SFTP 파일 전송 (업로드/다운로드)
- 연결 상태 모니터링
- 다중 채널 관리

### 2. SidecarService (51KB)

**역할:** comma 디바이스에 "사이드카" 프로세스를 배포하고 실행을 관리

- 사이드카 스크립트(`assets/sidecar/*`)를 기기로 전송
- camera, diag, hud 프로세스 원격 실행/종료
- 프로세스 상태 모니터링
- 실시간 데이터 수신 파이프라인

### 3. BackgroundService (28KB)

**역할:** 앱이 백그라운드에 있을 때도 동작하는 서비스

- 자동 백업 스케줄링
- 연결 상태 모니터링
- 알림 관리
- 앱 종료 시 정리 작업

### 4. GitHubService (27KB)

**역할:** CarrotPilot 소스코드의 Git 관리

- 현재 브랜치/커밋 정보 조회
- `git pull` 최신 업데이트
- 브랜치 변경 (`git checkout`)
- 변경사항 되돌리기 (`git reset`)
- GitHub 계정 연동 (OAuth)

### 5. LinkHudService (23KB)

**역할:** 실시간 HUD 데이터를 CarrotPilot으로부터 수신

- WebSocket 기반 실시간 데이터 스트리밍
- 주행 속도, 조향각, 차선 정보 등 파싱
- HUD 위젯에 데이터 공급

### 6. DeviceActionService (23KB)

**역할:** comma 디바이스의 시스템 레벨 제어

- 소프트 재시작 (UI만 재시작)
- 전체 재부팅
- 재빌드 (소스 코드 재컴파일)
- 학습 데이터 초기화
- 카메라 보정 초기화
- 녹화 영상 삭제

### 7. BackupService (20KB)

**역할:** CarrotPilot 설정의 백업/복원

- Google Drive 연동 자동 백업
- 수동 백업 생성
- 설정 변경 감지 시 자동 백업
- 이전 백업 목록 조회/복원
- 백업 간 비교 기능

### 8. UpdateService (11KB)

**역할:** CarrotLink 앱 자체의 업데이트 관리

- 최신 버전 확인
- 업데이트 채널 선택 (Stable / Dev)
- 업데이트 다운로드/설치 안내

---

## 서비스 카테고리별 구분

```
핵심 연결         Git 관리          HUD/주행          백업/클라우드       시스템
─────────────    ─────────────    ─────────────    ─────────────    ─────────────
SSHService       GitHubService    LinkHudService   BackupService    BackgroundSvc
SidecarService   GithubOAuthUI    NativeOverlay    KeyBackupSvc     StorageLayout
SSHKeyHelper                      HudDriveSettings GoogleDriveSvc   DiagnosticsSvc
DeviceActionSvc                                                     UpdateService

설정 관리         터미널
─────────────    ─────────────
CarrotProfileSvc MacroService
CarrotProfileCmp
CarrotServerSet
```
