# CarrotLink-dev 구조/모듈 리팩토링 보고서 (2026-02-26)

## 1) 목적
- 대형 화면 파일을 기능 단위로 분리해 수정 영향 범위를 줄이고, SSH/GitHub/Discovery 유지보수를 쉽게 만든다.
- 기존 동작은 유지하고 구조만 정리한다.

## 2) 적용 결과

### A. 설정 화면 계층 분리
- 기존 단일 파일 `lib/screens/settings_screen.dart`를 역할별 화면 파일로 분리.
- 현재 구조:
  - `lib/screens/settings/settings_home_screen.dart`
  - `lib/screens/settings/connection_settings_screen.dart`
  - `lib/screens/settings/backup_settings_screen.dart`
  - `lib/screens/settings/share_settings_screen.dart`
  - `lib/screens/settings/info_settings_screen.dart`
- `lib/screens/settings_screen.dart`는 호환용 barrel export로 유지.

### B. ConnectionSettings 대형 파일 분해
- `connection_settings_screen.dart`의 상태/라이프사이클만 메인에 유지.
- 기능 메서드는 `part + extension`으로 분리.
- 분리 파일:
  - `connection_settings_persistence.dart`: 설정 로드/저장, 키 백업/복원
  - `connection_settings_keys.dart`: 수동키/생성키 적용, 키 삭제/활성화
  - `connection_settings_auth.dart`: GitHub 로그인/키 생성 흐름
  - `connection_settings_discovery.dart`: 장치 검색/연결/진단
  - `connection_settings_widgets.dart`: 화면 구성 위젯

## 3) 검증
- 실행 명령:
  - `C:\flutter\bin\flutter.bat analyze lib/screens/settings/connection_settings_screen.dart lib/screens/settings_screen.dart`
- 결과:
  - `No issues found`

## 4) 유지보수 기준 (앞으로)
- 새로운 기능은 `ConnectionSettings` 본 파일에 직접 추가하지 않고, 책임에 맞는 part 파일에 추가.
- 저장소 키/키백업/로그인 흐름 변경 시 UI 파일(`widgets`)이 아니라 `auth`/`persistence`에서 우선 처리.
- 검색/재연결 정책은 `discovery`에서 단일 관리.
- 화면 텍스트/버튼만 변경할 때는 `widgets`만 수정.

## 5) 기대 효과
- 파일 단위 영향 범위가 줄어 코드 탐색 속도 향상.
- SSH 연결 이슈 수정 시 원인 위치 추적이 쉬워짐(인증/키/검색 분리).
- 추후 stable 반영 시 충돌 범위 축소.
