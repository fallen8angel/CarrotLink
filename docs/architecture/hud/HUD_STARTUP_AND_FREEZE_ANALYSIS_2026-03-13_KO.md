# HUD 시작 경로 / 멈춤 현상 분석 (2026-03-13)

## 문서 목적
- 앱 초기 실행 시 `Home HUD`가 어떤 경로로 값을 받는지 정리한다.
- `Stock` 주행모드 진입 후 `Home HUD`와 주행 HUD가 같이 멈춰 보이는 이유를 코드 기준으로 정리한다.

## 결론 요약
- 앱 초기 `Home HUD`는 주로 `ws://<host>:7766/ws/hud` 경로로 값을 받는다.
- `Stock` 주행모드에 들어가면 여기에 더해 `ws://<host>:7766/ws/live`와 `ws://<host>:7766/ws/camera/road`를 추가로 사용한다.
- 즉, 초기 홈 HUD는 상대적으로 가벼운 `HUD semantic snapshot`만 받지만, 주행모드는 같은 `7766` 쪽에 HUD, live overlay, camera를 동시에 붙인다.
- 이 상태에서 `7766` sidecar/broker가 멈추거나 과부하가 나면 `Home HUD`와 `Stock 주행 HUD`가 같이 멈춘 것처럼 보일 수 있다.

---

## 1. 앱 초기 `Home HUD` 수신 경로

### 1-1. 앱이 HUD 런타임을 먼저 예열
- [lib/screens/dashboard_screen.dart](/E:/Carrot/CarrotLink/lib/screens/dashboard_screen.dart)
  - `initState()`에서 `SharedRuntimeManager.prewarm()` 호출
- [lib/features/hud/application/hud_runtime_manager.dart](/E:/Carrot/CarrotLink/lib/features/hud/application/hud_runtime_manager.dart)
  - `prewarm() -> _ensureBound(forceEnsureRunning: true)`

의미:
- 대시보드가 열리면 앱은 홈 화면에 HUD가 실제로 그려지기 전부터 HUD 연결을 미리 준비한다.

### 1-2. Home HUD 위젯은 앱 공용 HUD 런타임을 재사용
- [lib/screens/tabs/home_tab.dart](/E:/Carrot/CarrotLink/lib/screens/tabs/home_tab.dart)
  - `AdaptiveHudHost`로 `HudSurfaceVariant.homePreview` 렌더링
- [lib/features/hud/presentation/widgets/adaptive_hud_host.dart](/E:/Carrot/CarrotLink/lib/features/hud/presentation/widgets/adaptive_hud_host.dart)
  - `SharedRuntimeManager`를 찾아 이미 살아 있는 HUD 컨트롤러를 재사용

의미:
- Home HUD는 화면마다 따로 연결을 새로 만드는 방식이 아니라, 앱 안에서 공유하는 HUD 세션을 본다.

### 1-3. 실제 HUD payload는 `/ws/hud`에서 수신
- [lib/features/hud/data/datasources/hud_remote_stream_data_source.dart](/E:/Carrot/CarrotLink/lib/features/hud/data/datasources/hud_remote_stream_data_source.dart)
  - 우선 순위 후보:
    - `ws://<host>:7766/ws/hud`
    - `ws://<host>:7767/ws/hud`
- [lib/features/hud/data/repositories/hud_repository_impl.dart](/E:/Carrot/CarrotLink/lib/features/hud/data/repositories/hud_repository_impl.dart)
  - 수신한 raw payload를 semantic snapshot으로 바꿔 UI로 전달

의미:
- 앱 시작 직후 Home HUD가 "잘 받아오는 것처럼" 보이는 경로는 기본적으로 `/ws/hud`다.
- 여기서는 카메라 영상이 아니라 HUD용 요약 데이터만 받는다.

### 1-4. Home HUD가 보여 주는 값
- 속도
- 제한속도
- 신호/연결 상태
- 일부 fallback metric

의미:
- Home HUD는 `주행 AR 정합`이나 `카메라 프레임 동기화`가 없다.
- 그래서 초기에는 더 안정적으로 보일 수 있다.

---

## 2. `Stock` 주행모드 진입 시 추가되는 경로

### 2-1. 주행 화면 진입
- [lib/screens/tabs/home_tab.dart](/E:/Carrot/CarrotLink/lib/screens/tabs/home_tab.dart)
  - `_openDriveView()`에서 `LiveDriveCanvasScreen` push

### 2-2. 주행 화면은 HUD 외에 live overlay와 camera를 추가 사용
- [lib/screens/drive/live_drive_canvas_screen.dart](/E:/Carrot/CarrotLink/lib/screens/drive/live_drive_canvas_screen.dart)
  - camera:
    - `ws://<host>:7766/ws/camera/road`
- [lib/features/hud/application/hud_runtime_manager.dart](/E:/Carrot/CarrotLink/lib/features/hud/application/hud_runtime_manager.dart)
  - live overlay:
    - `ws://<host>:7766/ws/live?encoding=json&camera=road&role=drive_overlay...`
- [lib/screens/drive/live_drive_canvas_sidecar_runtime_components.dart](/E:/Carrot/CarrotLink/lib/screens/drive/live_drive_canvas_sidecar_runtime_components.dart)
  - sidecar 프로세스 자체가 실행 중인지 확인하고 필요하면 시작

의미:
- `Stock` 주행모드는 Home HUD 위에 다음이 더 붙는다.
  - HUD semantic stream
  - live overlay stream
  - camera stream

즉, 초기 Home HUD보다 `7766` 쪽 의존도가 훨씬 높다.

---

## 3. 왜 처음엔 되다가 나중에 같이 멈춰 보이는가

## 3-1. Home HUD와 주행 HUD는 완전히 별개가 아니다
- [lib/features/hud/presentation/widgets/adaptive_hud_host.dart](/E:/Carrot/CarrotLink/lib/features/hud/presentation/widgets/adaptive_hud_host.dart)
  - 앱 내부 HUD는 `app_hud` 공용 transport를 공유
- [lib/features/hud/application/hud_module.dart](/E:/Carrot/CarrotLink/lib/features/hud/application/hud_module.dart)
  - shared controller / repository pool 사용

의미:
- Home HUD와 주행 화면 안 HUD는 다른 그림처럼 보여도, 내부적으로는 같은 HUD source를 공유한다.

## 3-2. 주행 진입 후 `7766`에 부하가 몰린다
주행 진입 후 동시에 붙는 것:
- `/ws/hud`
- `/ws/live`
- `/ws/camera/road`

추가로:
- sidecar 상태 확인
- native camera view
- overlay sync
- camera-ready probe

의미:
- 초기 Home HUD만 볼 때는 `/ws/hud` 하나만 잘 살아 있으면 된다.
- 하지만 주행모드에 들어가면 같은 sidecar/broker에 여러 consumer가 몰린다.

## 3-3. `HUD stream`은 한번 7766에 성공하면 그 포트에 고정되려는 성향이 있다
- [lib/features/hud/data/datasources/hud_remote_stream_data_source.dart](/E:/Carrot/CarrotLink/lib/features/hud/data/datasources/hud_remote_stream_data_source.dart)
  - `stickToPrimaryAfterSuccess = true`
  - `primaryDeliveredOnce == true`가 되면 이후 active candidate를 primary로만 좁힘

의미:
- 앱 초기에 `7766/ws/hud`가 한번 성공하면 이후에는 7767 fallback로 잘 넘어가지 못할 수 있다.
- 즉, "처음엔 잘 됨 -> 주행 중 7766이 흔들림 -> 이후 Home HUD도 freeze" 패턴이 가능하다.

## 3-4. UI는 즉시 비우지 않고 마지막 정상값을 붙잡는다
- [lib/features/hud/application/hud_controller.dart](/E:/Carrot/CarrotLink/lib/features/hud/application/hud_controller.dart)
  - stream error가 나도 마지막 snapshot은 state에 남음
- [lib/screens/drive/live_drive_canvas_overlay_sync_components.dart](/E:/Carrot/CarrotLink/lib/screens/drive/live_drive_canvas_overlay_sync_components.dart)
  - 마지막 정상 overlay snapshot을 잠시 유지

의미:
- 사용자 눈에는 "끊김"보다 "그대로 멈춤"으로 보인다.

---

## 4. 제공된 로그의 의미

### 4-1. HUD semantic stream 쪽
로그:
- `HudRemoteStreamDataSource.watch.run ...:74`

의미:
- `/ws/hud` 연결/재연결 경로에서 실패가 발생한 것

### 4-2. camera stream 쪽
로그:
- `socket_failure:Failed to connect to /172.30.1.11:7766`

의미:
- 주행 카메라가 `ws://172.30.1.11:7766/ws/camera/road`에 붙지 못한 것

### 4-3. overlay sync 쪽
로그:
- `modelFrame=null roadFrame=null`

의미:
- overlay loop는 돌고 있지만, 실제 model/camera frame 기준 데이터가 안 들어오고 있음
- 즉 "렌더러가 멈춘 것"보다 "업데이트 재료가 더 이상 안 들어오는 상태"에 가깝다

---

## 5. 현재 가장 가능성 높은 원인

코드 기준 추정:
- `7766` sidecar broker 자체가 멈춤
- `7766`은 살아 있지만 `ws/hud`, `ws/live`, `ws/camera` 중 일부가 응답 정지
- 주행 진입 후 camera/live relay가 sidecar를 압박해 HUD stream까지 같이 stall
- HUD data source가 primary `7766`에 고정된 뒤 fallback `7767`로 잘 넘어가지 못함

주의:
- 이 문서는 앱 코드 기준 분석 문서다.
- 실제 root cause를 확정하려면 sidecar 서버 쪽 `/health`, `/profile`, process log, port listener 상태를 같이 봐야 한다.

---

## 6. 정리
- 앱 초기 Home HUD 수신 경로는 주로 `ws://<host>:7766/ws/hud`다.
- 초기에는 이 경로 하나만 살아 있어도 Home HUD가 잘 보일 수 있다.
- `Stock` 주행모드에 들어가면 같은 `7766`에 live overlay와 camera가 추가로 붙는다.
- 그 결과 `7766` 경로가 흔들리면 Home HUD와 주행 HUD가 같이 멈춘 것처럼 보일 수 있다.

## 7. 후속 확인 포인트
- failure 시점에 `sidecar /health`가 살아 있는지
- failure 시점에 `/ws/hud`만 죽는지, `/ws/live`와 `/ws/camera`도 같이 죽는지
- `7767/ws/hud`가 실제로 살아 있는데 앱이 primary stickiness 때문에 못 넘어가는지
