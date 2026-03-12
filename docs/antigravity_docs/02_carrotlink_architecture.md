# CarrotLink-dev 아키텍처

## 기본 정보

| 항목 | 값 |
|------|-----|
| 패키지명 | `carrot_pilot_manager` |
| 버전 | 2.0050.0+2005000 |
| SDK | Flutter (Dart ≥3.0.0, <4.0.0) |
| 상태관리 | Provider |
| 테마 | Dark Mode Only |

## 디렉토리 구조

```
lib/
├── main.dart                  # 앱 엔트리포인트, Provider 설정
├── constants.dart             # 전역 상수
├── theme/
│   └── app_theme.dart         # 다크 테마 정의
├── models/
│   ├── carrot_profile_models.dart    # 프로필 데이터 모델
│   └── carrot_settings_models.dart   # 설정 데이터 모델
├── services/                  # 20개 비즈니스 로직 서비스
│   ├── ssh_service.dart              # SSH 연결/명령 (39KB)
│   ├── sidecar_service.dart          # 사이드카 프로세스 관리 (51KB)
│   ├── background_service.dart       # 백그라운드 서비스 (28KB)
│   ├── github_service.dart           # GitHub/Git 관리 (27KB)
│   ├── link_hud_service.dart         # HUD 데이터 연동 (23KB)
│   ├── device_action_service.dart    # 기기 제어 (23KB)
│   ├── backup_service.dart           # 백업/복원 (20KB)
│   ├── carrot_profile_service.dart   # 프로필 관리 (10KB)
│   ├── update_service.dart           # 앱 업데이트 (11KB)
│   ├── ssh_key_helper.dart           # SSH 키 관리 (11KB)
│   ├── google_drive_service.dart     # Google Drive 연동 (4KB)
│   ├── macro_service.dart            # 명령어 매크로 (5KB)
│   └── ...                           # 기타 서비스
├── screens/                   # 화면 구성
│   ├── splash_screen.dart            # 스플래시 화면
│   ├── dashboard_screen.dart         # 메인 대시보드 (24KB)
│   ├── tabs/                         # 탭 화면 (14개 파일)
│   ├── drive/                        # 실시간 주행 화면 (24개 파일)
│   └── settings/                     # 설정 화면 (9개 파일)
├── features/                  # 기능 모듈 (Clean Architecture)
│   ├── hud/                          # HUD 기능
│   └── yolo/                         # YOLO 객체 인식
├── widgets/                   # 공통 위젯 (9개 파일)
└── ui/
    └── adaptive/                     # 적응형 UI 컴포넌트
```

## 앱 시작 흐름

```
main()
  ├── WidgetsFlutterBinding 초기화
  ├── FlutterBackgroundService exitApp 리스너
  ├── Startup Warmup (비동기)
  │   ├── intl 초기화 (ko_KR)
  │   ├── 화면 방향 고정 (세로)
  │   ├── 백그라운드 서비스 초기화
  │   └── 스토리지 레이아웃 초기화
  └── MultiProvider 설정
      ├── SSHService
      ├── SharedRuntimeManager (SSHService 의존)
      ├── MacroService
      ├── GoogleDriveService
      ├── BackupService
      ├── UpdateService
      └── DiagnosticsService
          └── CarrotLinkApp → SplashScreen → DashboardScreen
```

## Provider 의존성 그래프

```
SSHService (독립)
    └── SharedRuntimeManager (SSHService에 의존, ProxyProvider)

MacroService (독립)
GoogleDriveService (독립)
BackupService (독립)
UpdateService (독립)
DiagnosticsService (싱글톤, 독립)
```

## 주요 의존 패키지

| 패키지 | 용도 |
|--------|------|
| `dartssh2` | SSH 클라이언트 |
| `provider` | 상태 관리 |
| `xterm` | 터미널 에뮬레이터 |
| `google_sign_in` / `googleapis` | Google Drive 인증/API |
| `web_socket_channel` | WebSocket 통신 |
| `webview_flutter` | 웹 HUD 표시 |
| `video_player` / `chewie` | 주행 영상 재생 |
| `re_editor` / `re_highlight` | 코드/텍스트 편집기 |
| `flutter_fancy_tree_view2` | 파일 트리 뷰 |
| `flutter_background_service` | 백그라운드 실행 |
| `flutter_local_notifications` | 로컬 알림 |
| `wakelock_plus` | 화면 꺼짐 방지 |

## 에셋

```
assets/
├── icon.png                 # 앱 아이콘
├── speed_bg.png             # 속도 배경 이미지
├── models/
│   └── yolo26n.pte          # YOLO 모델 (PyTorch ExecuTorch)
└── sidecar/
    ├── camera.py / camera.sh    # 카메라 사이드카 스크립트
    ├── diag.py / diag.sh        # 진단 사이드카 스크립트
    ├── hud.py / hud.sh          # HUD 사이드카 스크립트
    └── sidecar.py / sidecar.sh  # 사이드카 관리 스크립트
```
