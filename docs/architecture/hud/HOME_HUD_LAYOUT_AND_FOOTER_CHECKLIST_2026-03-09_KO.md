# Home HUD Layout And Footer Checklist (2026-03-09)

## 목표

- 홈 HUD가 가능한 화면에서는 남는 세로 영역을 자연스럽게 사용한다.
- 홈 HUD가 작은 화면이나 불안정한 제약 환경에서는 안전한 스크롤 레이아웃으로 내려간다.
- 하단 상태바는 transport/debug 메타를 넣지 않는다.
- 하단 상태바는 실제 semantic live 정보가 있을 때만 값을 표기하고, 없으면 빈칸을 유지한다.

## 현재 판단

- 홈 HUD의 "남는 세로 공간 채우기"는 `ListView + AspectRatio` 구조로는 해결되지 않는다.
- `SliverFillRemaining` 경로는 intrinsic/semantics 충돌을 일으켜 재사용하지 않는다.
- 안전한 대안은 `홈 전용 2모드`이다.
  - 충분한 높이: `Column + Expanded HUD`
  - 부족한 높이: 기존 스크롤형 레이아웃

## 체크리스트

- [x] 하단 상태바 표시 정책 문서화
- [x] 하단 상태바를 semantic live 값만 쓰도록 정리
- [x] `driveMode`는 assist 문맥과 의미 있는 live 값이 없으면 빈칸 처리
- [x] `LIMIT/CAM/구간`은 assist 문맥과 의미 있는 live 값이 없으면 빈칸 처리
- [x] `APN/APM`은 실제 semantic connectivity badge가 있을 때만 표기
- [x] 홈 HUD에 `Column + Expanded` 기반 pinned layout 추가
- [x] 작은 화면 fallback은 스크롤형 레이아웃 유지
- [x] drive inline speed cluster를 home 계열 통합형으로 정리
- [x] drive overlay speed cluster를 home 계열 통합형으로 정리
- [x] drive 화면 `dispose 중 setState` 경로 차단
- [x] `flutter analyze`로 관련 파일 검증

## 진행 기록

- 2026-03-09: 작업 시작. 상태바 정책과 홈 HUD 2모드 레이아웃을 함께 정리한다.
- 2026-03-09: footer를 semantic-only로 통일했다. `driveMode`와 `LIMIT`는 assist 문맥이 없으면 숨긴다.
- 2026-03-09: 홈 탭에 pinned layout을 추가했다. 충분한 높이에서는 `Column + Expanded HUD`, 작은 높이에서는 스크롤 fallback을 유지한다.
- 2026-03-09: drive inline/overlay speed cluster의 내부 레터박스를 제거하고 home과 같은 통합형 레이아웃으로 맞춘다.
- 2026-03-09: `dispose()` 중 sidecar 정리 과정에서 `setState()`가 호출되던 경로를 차단한다.
- 2026-03-09: `flutter analyze` 기준 관련 파일 정적검사를 통과했다.
