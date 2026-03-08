# CarrotLink Stock Mode Remote AR 구현 검토 (2026-03-06)

최종 분석일: 2026-03-06
최종 업데이트: 2026-03-07
분석 대상 경로: `E:\CarrotLink\CarrotLink`

이 문서는 CarrotLink의 `stock` 모드에서 표시되는 원격 주행카메라 화면 위에, 기존 `nav ar` 및 carrotpilot AR과 무관한 완전히 새로운 AR 기능을 추가할 수 있는지 검토한 결과를 정리한다.

전제:
- 기존 `CarrotLink nav ar` 코드는 설계 기준에서 제외한다.
- carrotpilot 내부 AR 구현은 설계 기준에서 제외한다.
- 목표는 `휴대폰 카메라 AR`이 아니라 `stock 모드 원격 주행카메라 위 AR`이다.

## 0. 2026-03-07 현재 구현 상태

2026-03-07 기준 코드 상태는 단순 설계 검토 단계를 넘었다.

현재 구현된 것:

- semantic AR scene builder
- Flutter -> native AR scene bridge
- native scene renderer
- render policy / smoother / stabilizer / retainer
- anchor smoothing
- road/wide layout profile 분리
- AR scene 진단 팝업
- AR scene capture / replay
- AR replay/session 자동 저장
- 주행 후 분석용 `session_meta.json`, `timeline.ndjson`, `session_latest.json` export
- 기존 overlay 대비 AR layer 시각 강조
- guide ribbon / trail / shell card / status pill / cue chip 시각 강화
- trail 시간 기반 움직임 추가

현재 아직 실기기에서 최종 튜닝이 필요한 것:

- `road` / `wideRoad`별 threshold 미세 조정
- anchor quality / stability 임계값 조정
- clutter / retention / degrade 규칙 실주행 튜닝
- 장시간 주행에서 flicker / thermal / fps 관찰
- 현재 사진 기준으로는 "보이긴 하지만 AR 체감이 약함" 문제를 더 개선해야 함

주의:

- 현재 live AR scene 은 `sidecar/comma` live payload를 기준으로 만들어진다
- `폰 TMap 화면 + fake GPS`만으로는 현재 live scene 이 생성되지 않는다
- 이 경우 `AR Scene` 팝업에서 `local payload = null`, `native payload = null`, `nativeViewId = --`가 나올 수 있다

실기기 테스트 절차는 아래 별도 문서를 따른다.

- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_ON_DEVICE_TEST_2026-03-07_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_HANDOFF_2026-03-07_KO.md`

### 0.1 현재 평가

2026-03-07 현재 구현은 아래처럼 평가한다.

- 구조/모듈화: 높은 수준까지 완료
- capture/replay/debug: 실사용 가능한 수준
- 자동 저장/사후 분석: 가능
- AR 체감 품질: 아직 최종 전

즉, 지금 병목은 "구조가 없음"이 아니라 "실제 화면에서 얼마나 AR답게 보이느냐"다.

### 0.2 현재 우선순위

지금부터의 우선순위는 아래 순서다.

1. 실주행 로그/세션 확보
2. `session_meta.json`, `timeline.ndjson` 기반 사후 분석
3. AR layer 존재감 강화 및 clutter/fallback 조정
4. `road` / `wideRoad` preset 미세 조정
5. 장시간 안정화

### 0.3 사용자가 지금 해야 하는 것

현재 사용자는 별도 수동 로그 조작을 거의 하지 않아도 된다.

- 최신 빌드 설치
- 주행 중 `Native AR scene 전송` 유지
- 평소처럼 stock 화면으로 주행
- 주행 후 `logs/ar_scene/session_<...>/` 폴더 또는 스크린샷만 전달

즉, 지금부터는 "주행 후 데이터 전달 -> 사후 분석 -> 튜닝" 루프가 기본 개발 방식이다.

## 1. 결론

- 구현 가능: `예`
- 단, 권장 방식: `ARCore 기반 폰 카메라 AR`이 아니라 `원격 카메라 정합형 AR overlay`
- 현재 코드베이스 적합도: `높음`
- Unity 사용 가능성: `가능하나 1순위 권장안은 아님`

핵심 이유는 현재 stock 모드가 휴대폰 카메라를 쓰지 않기 때문이다. CarrotLink는 원격 장치의 road/wideRoad 카메라 스트림을 앱으로 받아 디코드해서 보여준다. 따라서 ARCore가 기대하는 "device camera + device pose" 입력과 구조가 다르다.

## 2. 현재 stock 모드 렌더링 구조

현재 stock 모드 카메라 렌더링은 다음 흐름으로 동작한다.

1. Flutter가 stock 모드 여부를 판단한다.
2. stock 모드에서는 원격 카메라 WebSocket URL을 만든다.
3. Android native `PlatformView`가 `MediaCodec`으로 H.264를 디코드한다.
4. 별도 overlay view가 카메라 surface 위에 2D 요소를 그린다.

주요 코드:
- `lib/screens/drive/live_drive_canvas_screen.dart`
- `lib/screens/drive/live_drive_canvas_hud_components.dart`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
- `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`
- `lib/screens/drive/live_drive_canvas_overlay_components.dart`

핵심 포인트:
- 카메라 입력은 휴대폰 로컬 카메라가 아니라 `ws://<host>:7766/ws/camera/<road|wideRoad>`
- 현재 native overlay는 `polygon`, `label` 위주 2D 렌더링
- 이미 `frameId`, `roadCameraState`, `wideRoadCameraState`, intrinsics, calibration 데이터를 사용 중
- 즉, "원격 카메라 위에 좌표를 맞춰 그리는 구조"는 이미 일부 존재한다

### 2.1 현재 활용 가능한 내비 데이터 소스

현재 CarrotLink는 카메라/모델 계열 데이터만 받는 상태가 아니다. sidecar 기준으로 이미 다음 서비스가 포함된다.

- `carrotMan`
- `navInstructionCarrot`

즉 앱은 현재도 다음 내비 입력을 받을 수 있다.

- `carrotMan.naviPaths`
- `carrotMan.xTurnInfo`
- `carrotMan.xDistToTurn`
- `carrotMan.szTBTMainText`
- `carrotMan.nRoadLimitSpeed`
- `navInstructionCarrot.maneuverType`
- `navInstructionCarrot.maneuverModifier`
- `navInstructionCarrot.maneuverDistance`

이 데이터는 carrotpilot 쪽 외부 내비 입력 포트(`7712`) 또는 관련 가공 파이프라인에서 올라온 결과물일 수 있다. 즉 stock 모드 remote AR를 새로 만들 때, 별도 TMap API를 앱에서 직접 붙이지 않아도 route/turn source를 확보할 수 있는 기반이 이미 있다.

## 3. 왜 ARCore를 그대로 붙이기 어렵나

2026-03 기준 공식 Android/ARCore 문서 관점에서 보면, ARCore는 여전히 다음 전제를 가진다.

- 기기의 실제 카메라를 사용한다
- `Google Play Services for AR`를 사용한다
- Geospatial은 카메라와 위치 권한이 필요하다
- camera sharing도 `Camera2` 기반 공유 세션 문맥이다

즉, 현재 CarrotLink stock 모드처럼 "원격 장치에서 온 H.264 비디오 스트림"을 ARCore의 추적 카메라로 직접 쓰는 공식 경로는 없다.

따라서 아래 두 개는 구분해야 한다.

- 가능한 것: 원격 카메라 위에 3D처럼 보이는 AR overlay를 정합해서 그리기
- 권장되지 않는 것: stock 모드 비디오를 ARCore 세션의 camera input처럼 취급하기

## 4. 구현 아키텍처 선택지

### A안. 원격 카메라 정합형 AR overlay

가장 현실적이고 현재 코드와 잘 맞는 방식이다.

원리:
- 원격 장치가 route path, turn cue, anchor point, ego pose, frame timestamp를 보낸다
- 1차 데이터 소스는 `carrotMan.naviPaths`, `xTurnInfo`, `xDistToTurn`, `navInstructionCarrot`로 잡는 것이 가장 현실적이다
- CarrotLink가 현재 사용 중인 camera calibration과 frame sync를 이용해 3D/2.5D 객체를 화면 좌표로 투영한다
- native renderer가 카메라 영상 위에 화살표, 경로 리본, 게이트, 거리 마커를 그린다

장점:
- stock 모드 카메라를 그대로 유지한다
- ARCore 필수 아님
- 현재 코드 재사용 폭이 크다
- 성능/지연 관리가 상대적으로 쉽다

단점:
- "실제 공간을 스캔하는 폰 카메라 AR"은 아니다
- 정확도는 원격 카메라 캘리브레이션과 입력 데이터 품질에 크게 의존한다

### B안. Android native 3D renderer

권장되는 확장 방향이다.

원리:
- 지금 `SurfaceView + overlay View` 구조를 `TextureView + OpenGL ES` 또는 유사한 3D 렌더러 구조로 올린다
- 원격 비디오는 texture로 표시하고, 3D 메시/빌보드/리본은 동일 렌더러에서 그린다

장점:
- Flutter보다 3D 표현력이 좋다
- Unity보다 앱 통합이 쉽다
- stock 모드와 UX를 거의 유지할 수 있다

단점:
- native 그래픽 구현 난이도가 올라간다

### C안. Unity 사용

기술적으로 가능하지만, 같은 앱 안에서 안정적으로 굴리려면 제약이 많다.

가능한 방식:
- 별도 full-screen Unity Activity로 전환
- Unity가 원격 카메라 영상 텍스처와 AR 객체를 같이 렌더링

문제:
- Flutter + PlatformView + Unity + 원격 video surface 조합은 합성이 까다롭다
- 현재 앱 구조와 lifecycle이 복잡해진다
- 빌드/용량/메모리/디버깅 비용이 커진다

따라서 "실제 3D처럼 보이게"가 목표라면, 1차 권장안은 Unity보다 Android native 3D renderer다. Unity는 full-screen 전용 주행 모드를 따로 만들 때만 검토할 가치가 있다.

## 5. 실기기에서 보이는 방식

실기기에서 보이는 모습은 구현 선택지에 따라 달라진다.

### A안 또는 B안일 때

- 사용자는 여전히 stock 모드의 원격 주행카메라를 본다
- 차이는 "영상 위에 덧그리는 방식"이 현재의 단순 2D overlay에서 더 정교한 2.5D/3D overlay로 바뀐다는 점이다
- 겉보기 UX는 기존 LiveDriveCanvas와 비슷하게 유지할 수 있다

즉, 사용자 입장에서는 "기존 뷰가 완전히 다른 앱처럼 바뀐다"기보다 "기존 stock 화면이 더 입체적이고 정합된 AR 형태로 강화된다"에 가깝다.

### Unity full-screen 방식일 때

- 별도 Unity 화면으로 전환될 가능성이 크다
- 같은 기능이라도 뷰 계층과 lifecycle이 달라진다
- 사용자는 현재 CarrotLink stock 뷰와 다른 모드로 느낄 가능성이 높다

## 6. 실제 3D처럼 보이게 할 수 있나

가능하다. 다만 "무엇을 실제 3D처럼 보이게 하려는지"를 분리해야 한다.

가능한 표현:
- 진행 경로를 도로 위 리본처럼 보이게 만들기
- 다음 회전 지점을 실제 공간 앞쪽 표지판처럼 띄우기
- 거리 마커를 원근감 있게 배치하기
- lane/guide gate를 도로 폭에 맞춰 3D처럼 보이게 만들기

이건 반드시 ARCore가 있어야 되는 게 아니다. 원격 카메라의 intrinsics/extrinsics, 차량 기준 좌표, 경로 점들의 3D 좌표만 있으면 perspective projection으로 상당히 설득력 있게 만들 수 있다.

## 7. 고도, 경로 위치, 실제 AR 위치감

가능 여부는 데이터 품질에 따라 세 단계로 나뉜다.

### 1단계. 도로 평면 기준 pseudo-AR

가장 구현이 쉽다.

- 경로를 "도로 평면 위"에 붙인다고 가정
- turn arrow, gate, marker를 차량 기준 좌표계에서 배치
- 시각적으로는 충분히 AR처럼 보일 수 있다

이 단계는 고도가 정밀하지 않아도 된다.

### 2단계. 고도 포함 3D overlay

가능하다. 하지만 추가 데이터가 필요하다.

필수에 가까운 입력:
- 경로 점별 `x/y/z` 또는 `lat/lng/alt`
- 차량 ego pose
- 카메라 extrinsic / intrinsic
- 프레임 시각 동기화

이 단계가 되면 오르막, 내리막, 높은 구조물, 멀리 떠 있는 표지 등을 더 자연스럽게 표현할 수 있다.

### 3단계. 실제 world anchor처럼 보이는 정합

이건 가장 어렵다.

필요 조건:
- 매우 안정적인 카메라 캘리브레이션
- route geometry와 차량 pose의 정밀도
- 프레임 단위 timestamp 정합
- overpass, tunnel, 분기 구조를 반영할 수 있는 지도/고도 데이터

즉 "실제로 거기 존재하는 것처럼 보이는 AR"은 가능하지만, 정확도는 데이터 파이프라인이 결정한다. 데이터가 `lat/lng` 수준만 있으면 고도와 실제 위치감은 제한적이고, `3D world coordinate + sync`가 있으면 훨씬 좋아진다.

## 8. 성능 부하

성능은 구현 방식별로 다르다.

### 현재 구조 + 2D/2.5D 확장

- 부하: 낮음~중간
- 이유:
  - 비디오 디코드는 이미 `MediaCodec` 하드웨어 디코드를 사용 중
  - overlay만 추가 계산하면 됨
  - 현재 frame sync 구조 재사용 가능

주요 리스크:
- overlay payload가 너무 커질 때 Flutter <-> native 채널 비용 증가
- frameId sync miss
- draw object 수 증가

### native 3D renderer

- 부하: 중간
- 이유:
  - GPU 사용량은 늘지만 구조가 효율적이다
  - 비디오와 3D 오브젝트를 한 렌더 경로에서 처리 가능하다

주요 리스크:
- 열 관리
- wide/road 카메라 전환 시 재초기화 비용
- 저사양 기기에서 frame pacing 흔들림

### Unity

- 부하: 중간~높음
- 이유:
  - 엔진 오버헤드가 크다
  - 메모리 사용량과 앱 용량이 크게 증가한다
  - Flutter와 병행 시 lifecycle/composition 비용이 커진다

주요 리스크:
- 메모리 압박
- 검은 화면/합성 문제
- 앱 전환 시 안정성

### ARCore까지 포함한 폰 카메라 AR

- 부하: 높음
- 이유:
  - 카메라, 위치, 센서, 추적, 렌더링이 모두 추가된다
  - 그러나 stock 원격 카메라 목표와도 맞지 않는다

## 9. 필요한 코드 변경

### CarrotLink 앱

- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
  - overlay payload 확장
  - 3D renderer 또는 richer primitive 지원
- `lib/screens/drive/live_drive_canvas_overlay_models_components.dart`
  - AR anchor / route geometry / z 값 모델 추가
- `lib/screens/drive/live_drive_canvas_overlay_components.dart`
  - 3D 투영 계산 및 primitive encode
- `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`
  - frameId 기준 payload sync 고도화
- `lib/screens/drive/live_drive_canvas_screen.dart`
  - 모드 토글, 디버그 토글, 성능 모드 설정

### remote sidecar / 장치 측

- route geometry, cue, distance, ego pose, timestamp 공급
- 필요하면 전용 AR payload 또는 기존 live payload 확장

## 10. 권장 단계

### 1차

- 현재 native overlay 구조를 유지
- path ribbon, turn gate, distance marker만 추가
- frame sync 안정화

### 2차

- native 3D renderer로 올리기
- 원근감 있는 marker와 billboard arrow 도입
- z 값과 고도 지원

### 3차

- Unity는 full-screen driving mode가 정말 필요할 때만 별도 검토

## 11. 사용자 질문에 대한 직접 답변

### Q1. 실기기에서는 기존의 저장소와 다른 원리나 뷰로 보일까?

- 원리는 달라진다
- 하지만 A안/B안이면 뷰는 크게 바꾸지 않고 현재 stock 모드 위에서 자연스럽게 확장할 수 있다
- Unity full-screen이면 뷰도 꽤 달라진다

### Q2. Flutter 말고 Unity나 실제 3D로 보이게 만들고 싶어

- 가능하다
- 다만 1순위는 Unity보다 Android native 3D renderer가 맞다
- Unity는 전용 전체화면 모드라면 가능하지만, 현재 CarrotLink 구조 안에 매끄럽게 넣는 난이도와 비용이 높다

### Q3. 고도나 경로 위치 등 여러가지를 실제로 AR 위치로 보이는 것처럼 만드는 거야?

- 가능하다
- 단, 정확도는 입력 좌표와 캘리브레이션 품질이 결정한다
- 1차는 "도로 위에 붙는 것처럼 보이는 pseudo-AR", 2차는 "고도 포함 3D overlay", 3차는 "실제 world anchor 수준 정합"으로 보는 게 맞다

### Q4. 성능 부하는 어떨까?

- 현재 구조 확장형은 상대적으로 감당 가능하다
- native 3D는 중간 수준 부하로 현실적이다
- Unity는 가장 무겁고 통합 비용도 크다
- 따라서 성능과 안정성까지 보면 1차 권장안은 native 3D renderer다

## 12. 외부 참고

좌표/맵핑/최적화 내부 참고:
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_MVP_EXECUTION_PLAN_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_IMPLEMENTATION_CHECKLIST_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_MAPPING_OPTIMIZATION_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_ON_DEVICE_TEST_2026-03-07_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_HANDOFF_2026-03-07_KO.md`

- Flutter Android Platform Views
  - https://docs.flutter.dev/platform-integration/android/platform-views
- ARCore enable AR
  - https://developers.google.com/ar/develop/java/enable-arcore
- ARCore shared camera
  - https://developers.google.com/ar/develop/java/camera-sharing
- ARCore Geospatial enable
  - https://developers.google.com/ar/develop/java/geospatial/enable
- ARCore Geospatial overview
  - https://developers.google.com/ar/develop/geospatial

