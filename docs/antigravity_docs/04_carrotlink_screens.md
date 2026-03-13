# CarrotLink-dev 화면 구성 및 UI

## 화면 네비게이션 흐름

```
SplashScreen → DashboardScreen
                  ├── HomeTab (홈)
                  ├── GitTab (Git 관리, 114KB)
                  ├── SystemTab (시스템 제어)
                  ├── TerminalTab (터미널, 32KB)
                  ├── FileExplorerTab (파일 탐색기, 50KB)
                  ├── LogsTab (로그 뷰어, 89KB)
                  ├── CarrotSettingsTab (설정 편집, 81KB)
                  ├── CarrotBackupTab (백업 관리, 51KB)
                  ├── MacroTab (매크로, 8KB)
                  └── DeviceSettingsTab (기기 설정, 3KB)
```

## 설정 화면 (screens/settings/)

| 파일 | 크기 | 기능 |
|------|------|------|
| `settings_home_screen.dart` | 3KB | 설정 메인 화면 |
| `connection_settings_screen.dart` | 4KB | 연결 설정 메인 |
| `connection_settings_auth.dart` | 9KB | SSH 인증 설정 |
| `connection_settings_discovery.dart` | 10KB | 기기 자동 탐색 |
| `connection_settings_keys.dart` | 10KB | SSH 키 관리 |
| `connection_settings_persistence.dart` | 17KB | 연결 정보 저장/불러오기 |
| `connection_settings_widgets.dart` | 26KB | 연결 설정 UI 위젯 |
| `hud_settings_screen.dart` | 7KB | HUD 표시 설정 |
| `info_settings_screen.dart` | 6KB | 앱 정보 화면 |

## 실시간 주행 화면 (screens/drive/)

LiveDriveCanvas는 24개 파일로 분리된 가장 복잡한 화면입니다:

| 파일 | 크기 | 역할 |
|------|------|------|
| `live_drive_canvas_screen.dart` | 36KB | 메인 화면 조립 |
| `live_drive_canvas_overlay_components.dart` | **133KB** | 2D 오버레이 렌더링 (경로/차선/리드/레이더) |
| `live_drive_canvas_debug_popup_components.dart` | **108KB** | 디버그 팝업 UI |
| `live_drive_canvas_overlay_sync_components.dart` | 42KB | 오버레이 데이터 동기화 |
| `live_drive_canvas_overlay_models_components.dart` | 38KB | 오버레이 데이터 모델 |
| `live_drive_canvas_layout_components.dart` | 32KB | 레이아웃 관리 |
| `live_drive_canvas_camera_html_components.dart` | 28KB | 카메라 HTML 뷰 |
| `live_drive_canvas_sidecar_runtime_components.dart` | 27KB | 사이드카 런타임 관리 |
| `live_drive_canvas_debug_actions_components.dart` | 24KB | 디버그 액션 |
| `live_drive_canvas_overlay_preview_components.dart` | 20KB | 오버레이 프리뷰 |
| `live_drive_canvas_hud_components.dart` | 17KB | HUD 위젯 |
| `live_drive_canvas_ar_scene_components.dart` | 14KB | AR 씬 렌더링 |
| `live_drive_canvas_ar_replay_components.dart` | 15KB | AR 리플레이 |
| `live_drive_canvas_plot_components.dart` | 12KB | 실시간 그래프 |
| `live_drive_canvas_camera_components.dart` | 11KB | 카메라 스트림 관리 |
| `live_drive_canvas_lifecycle_components.dart` | 8KB | 생명주기 관리 |
| `live_drive_canvas_sidecar_components.dart` | 8KB | 사이드카 통합 |
| `live_drive_canvas_sidecar_bootstrap_components.dart` | 5KB | 사이드카 부트스트랩 |
| `live_drive_canvas_sidecar_transport_components.dart` | 5KB | 사이드카 전송 |
| `live_drive_canvas_overlay_math_components.dart` | 7KB | 오버레이 수학 연산 |
| `live_drive_canvas_plot_models_components.dart` | 7KB | 그래프 데이터 모델 |
| `live_drive_canvas_debug_components.dart` | 4KB | 디버그 컴포넌트 |
| `live_drive_canvas_camera_diag_components.dart` | 4KB | 카메라 진단 |

## 공통 위젯 (widgets/)

| 파일 | 크기 | 기능 |
|------|------|------|
| `dashcam_player_screen.dart` | 26KB | 주행 영상 플레이어 |
| `drive_list_widget.dart` | 24KB | 주행 목록 위젯 |
| `video_list_widget.dart` | 9KB | 비디오 목록 |
| `update_dialog.dart` | 6KB | 업데이트 알림 |
| `command_execution_dialog.dart` | 6KB | 명령 실행 다이얼로그 |
| `design_components.dart` | 5KB | 공통 디자인 컴포넌트 |
| `section_tab_bar.dart` | 4KB | 탭바 위젯 |
| `custom_toast.dart` | 4KB | 토스트 알림 |
| `connection_required_view.dart` | 3KB | 연결 필요 화면 |

## Features (Clean Architecture)

### HUD (`features/hud/`)
- `hud.dart` — 배럴 파일 (export)
- `application/` — 유스케이스
- `data/` — 데이터소스
- `domain/` — 엔티티, 리포지토리 인터페이스
- `presentation/` — UI/BLoC

### YOLO (`features/yolo/`)
- `yolo.dart` — 배럴 파일
- `domain/` — YOLO 도메인 모델
- `presentation/` — YOLO UI 컴포넌트
