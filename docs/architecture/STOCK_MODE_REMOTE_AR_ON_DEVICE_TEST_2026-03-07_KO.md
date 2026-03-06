# CarrotLink Stock Mode Remote AR 실기기 테스트 가이드 (2026-03-07)

최초 작성일: 2026-03-07
대상 앱 경로: `E:\CarrotLink\CarrotLink`
테스트 예정일 예시: `2026-03-08 출근길`

이 문서는 현재 구현된 stock mode remote AR 기능을 실기기에서 어떻게 점검할지 정리한다.

## 1. 현재 상태 요약

2026-03-07 기준 현재 구현은 다음까지 올라와 있다.

- semantic AR scene 생성
- Flutter -> native AR scene bridge
- native AR scene renderer
- anchor smoothing / render smoothing / policy / retention / stabilize
- AR scene 진단 팝업
- AR scene capture / replay

즉, 코드 구조와 디버그 도구는 준비된 상태다. 내일부터 필요한 것은 실제 주행 장면에서 입력이 들어올 때 어떤 값이 올라오는지 확인하는 것이다.

## 2. 지금 당장 안 되는 것

다음 조합만으로는 현재 live AR scene 이 만들어지지 않는다.

- 폰에서 fake GPS 사용
- 폰에서 TMap 화면만 실행
- `alive` 미실행
- comma road/wide camera live stream 미생성

이유:

- CarrotLink는 폰 TMap 화면을 읽지 않는다
- 현재 AR scene은 sidecar/comma live payload 기준으로 만들어진다
- calibration, route path, turn cue, native camera view가 없으면 local/native AR payload가 모두 `null`일 수 있다

즉 `폰 TMap만 보이는 상태`는 AR 입력이 아니라 참고 화면일 뿐이다.

## 3. 내일 출근길 테스트 목표

내일 2026-03-08 출근길 테스트의 목표는 아래 4개다.

- live AR scene 이 실제로 생성되는지 확인
- native camera view 위로 AR scene payload 가 push 되는지 확인
- capture 를 저장한 뒤 replay 가 동작하는지 확인
- 어떤 조건에서 scene 이 비거나 약해지는지 로그를 남기기

## 4. 출발 전 준비

출발 전에 아래를 맞춘다.

- comma 기기와 CarrotLink 연결
- stock 모드 진입 가능 상태
- road 또는 wideRoad 카메라가 실제로 뜨는 상태
- TMap 경로 안내 시작
- 가능하면 첫 테스트는 `road` 카메라 기준으로 시작

권장:

- 처음에는 wideRoad보다 road 카메라부터 본다
- 경로가 긴 구간보다 분기/회전이 있는 경로가 좋다

## 5. 테스트 순서

### 5.1 주행 화면 진입

1. CarrotLink 에서 stock HUD 주행 화면으로 들어간다.
2. 실제 원격 road 카메라가 뜨는지 먼저 본다.
3. 우측 또는 상단의 `튜닝` 아이콘으로 `HUD 디버그`를 연다.

### 5.2 디버그 토글 확인

`HUD 디버그`에서 아래를 확인한다.

- `Native AR scene 전송` 켜기
- 필요하면 기존 overlay 디버그는 그대로 둬도 됨

### 5.3 AR scene 상태 확인

`점검` 탭에서 `AR scene 보기`를 누른다.

기대하는 값:

- `nativeViewId`가 숫자로 보임
- `localRoutePoints`가 `0`이 아님
- `localTurnInfo`가 `0`이 아니거나, 적어도 turn cue 관련 summary가 있음
- `localLayoutProfile`이 `idle`이 아님
- `localRenderBudget`가 `0`보다 큼
- `localCalibrationOk=true`
- `[local payload]`가 `null`이 아님
- `[native payload]`가 `null`이 아님
- `[native render summary]`가 `-`가 아님

### 5.4 첫 캡처 저장

scene 이 살아 있으면 바로 `AR 캡처 저장`을 누른다.

기대하는 결과:

- 토스트에 `AR 캡처 저장 완료 (...)`
- 이후 `AR scene 보기`에서 `replayStatus=captures=N`

### 5.5 replay 확인

live scene 이 잠깐 비더라도 테스트를 이어가기 위해 아래를 수행한다.

1. `마지막 캡처 재생` 누르기
2. 다시 `AR scene 보기` 확인

기대하는 결과:

- `replayStatus=replay:...`
- `[native payload]` 또는 `[native render]`가 채워짐
- live 입력이 일시적으로 흔들려도 replay 기준으로 shell/guide 상태를 볼 수 있음

### 5.6 replay 종료

replay 확인 후에는 `AR 재생 종료`를 눌러 다시 live 상태로 돌린다.

## 6. 이렇게 보이면 정상에 가깝다

정상에 가까운 징후:

- route/turn 이 있는 구간에서 `localRoutePoints > 0`
- `localCalibrationOk=true`
- `nativeViewId` 생성됨
- native render summary 에 `budget`, `shellAlpha`, `guideAlpha`, `trailAlpha` 값이 표시됨
- replay 저장 후 언제든 마지막 scene 을 다시 띄울 수 있음

## 7. 이렇게 보이면 원인 후보가 명확하다

### 7.1 `nativeViewId=--`

뜻:

- native camera view 자체가 아직 생성되지 않음

원인 후보:

- stock 원격 카메라 화면이 실제로 안 뜸
- 해당 화면이 아직 native platform view를 만들지 못함

### 7.2 `localCalibrationOk=false`

뜻:

- calibration 입력이 아직 준비되지 않음

원인 후보:

- live model/camera 상태가 충분히 안 들어옴
- `alive`나 sidecar live 경로가 아직 준비되지 않음

### 7.3 `localRoutePoints=0`, `localTurnInfo=0`

뜻:

- AR scene 에 쓸 route/turn 정보가 비어 있음

원인 후보:

- TMap 경로는 있어도 comma/carrotMan/navInstructionCarrot 쪽으로 실제 전달이 안 됨
- phone TMap만 있고 live sidecar nav payload가 없음

### 7.4 `[local payload] null`

뜻:

- Flutter 쪽 scene builder 가 빈 scene 으로 판단함

원인 후보:

- calibration/route/turn/native overlay size 조건 미충족

### 7.5 `[native payload] null`

뜻:

- Flutter 에 local payload 는 있어도 native view로 아직 push 안 됐거나 clear 된 상태

원인 후보:

- `Native AR scene 전송` 꺼짐
- native view 생성 타이밍 이슈
- live/replay 전환 직후

## 8. 내일 꼭 남겨야 할 정보

내일 테스트 후 아래 4개를 남기면 다음 튜닝이 바로 가능하다.

- `AR scene 보기` 스크린샷 2장 이상
- `local payload` 또는 `native render summary` 내용
- `AR 캡처 저장` 성공 여부
- 어떤 장면에서 scene 이 비거나 약해졌는지 짧은 메모

특히 아래 중 하나면 좋다.

- 직진 주행 중
- 분기 직전
- 우회전/좌회전 직전
- live 가 비었을 때

## 9. 내일 현장용 짧은 체크리스트

출발 전:

- comma 연결
- stock road 카메라 확인
- TMap 경로 시작
- `Native AR scene 전송` 켜기

주행 중:

- `AR scene 보기`
- `localRoutePoints`, `localCalibrationOk`, `nativeViewId` 확인
- scene 살아 있으면 `AR 캡처 저장`
- 필요 시 `마지막 캡처 재생`

종료 전:

- `AR scene 보기` 스크린샷 저장
- 문제 장면 메모

## 10. 권장 판단 기준

내일 테스트에서 아래 중 하나만 만족해도 수확이 있다.

- live scene 이 실제로 생성됨
- capture/replay 가 정상 동작함
- 어떤 조건에서 scene 이 비는지 원인을 분리함

즉 내일 목표는 "완성형 AR 품질 확인"이 아니라 "실기기 입력 경로 확인과 캡처 확보"다.

## 11. 관련 문서

- `docs/architecture/STOCK_MODE_REMOTE_AR_FEASIBILITY_2026-03-06_KO.md`
- `docs/architecture/STOCK_MODE_REMOTE_AR_HANDOFF_2026-03-07_KO.md`
- `docs/architecture/STOCK_MODE_REMOTE_AR_MVP_EXECUTION_PLAN_2026-03-06_KO.md`
- `docs/architecture/STOCK_MODE_REMOTE_AR_IMPLEMENTATION_CHECKLIST_2026-03-06_KO.md`
