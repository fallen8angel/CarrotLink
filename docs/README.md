# CarrotLink-dev 문서 인덱스

## 핵심 문서

- `MASTER_DEVELOPMENT_GUIDE_KO.md`  
  구조/기능/유지보수/코딩 기준 통합 가이드
- `architecture/README.md`
  아키텍처 문서 카테고리 인덱스

## AI 빠른 참조

- stock 주행그래픽/HUD 원본 기준:
  - `architecture/carrotpilot/C3_STOCK_ONROAD_GRAPHICS_HUD_REFERENCE_2026-03-10_KO.md`
- c3/c4 그래픽 포팅 후보 검토:
  - `architecture/carrotpilot/CARROTPILOT_C3_C4_GRAPHICS_PORT_REVIEW_2026-03-14_KO.md`
- stock 그래픽 1차 미세조정 기준:
  - `architecture/carrotpilot/CARROTPILOT_STOCK_GRAPHICS_FINE_TUNING_2026-03-14_KO.md`
- 원본 HUD 값 의미:
  - `architecture/carrotpilot/CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md`
- 원본 producer 와 CarrotLink consumer 매핑:
  - `architecture/link/CARROTLINK_PRODUCER_CONSUMER_MAP_2026-03-11_KO.md`
- stock 화면 YOLO 개발자용 오프라인 재생 기준:
  - `architecture/yolo/STOCK_MODE_YOLO_DEVELOPER_PLAYBACK_2026-03-15_KO.md`
- 현재 HUD 리팩토링 기준:
  - `architecture/hud/refactoring/HUD_REFACTORING_V3_2026-03-11_KO.md`
- 현재 앱 구현 수준/요소 매트릭스:
  - `architecture/carrotpilot/CARROTPILOT_ONROAD_ELEMENT_MATRIX_2026-03-02_KO.md`
- lead/radar 정합:
  - `architecture/carrotpilot/STOCK_MODE_LEAD_RADAR_ALIGNMENT_CHECKLIST_2026-03-09_KO.md`

## 문서 카테고리

- `architecture/core/`
  공통 구조, 코드베이스 분석, LiveDriveCanvas 모듈화
- `architecture/hud/`
  Adaptive HUD 재구성, semantic snapshot, handoff
- `architecture/hud/refactoring/`
  HUD 리팩토링 기준 문서와 이후 handoff/checklist 누적
- `architecture/link/`
  CarrotLink side-load/app producer-consumer 매핑 문서
- `architecture/carrotpilot/`
  carrotpilot/onroad/TMAP 입력 구조 분석, stock 원본 onroad 그래픽/HUD 기준 문서
- `architecture/yolo/`
  YOLO 기반 객체감지 설계, 타당성, 통합 계획, 진행 handoff
- `operations/`
  운영/배포/빌드/터미널 사용 문서
- `_analysis/`
  초기 스캔 산출물과 분석 원본

## 운영 문서

- `operations/APK_SCRIPT_USAGE_KO.md`
- `operations/TERMINAL_BUILD_INSTALL_COMMANDS_KO.md`
- `operations/GIT_SYSTEM_TAB_SSH_COMMANDS_KO.md`
- `operations/SIDECAR_DEPLOY_USAGE_KO.md`
