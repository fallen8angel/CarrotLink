# C3/C4 웹당근 + CarrotLink 실시간 WS 통합 리팩토링 계획서

작성일: 2026-03-31  
상태: 초안  
성격: 계속 보강하는 작업 문서

관련 문서:

- 페이즈 문서:
  - `UNIFIED_REALTIME_WS_PHASES_C3_C4_CARROTLINK_2026-03-31_KO.md`
- 개발 작업 문서:
  - `UNIFIED_REALTIME_WS_DEVELOPMENT_GUIDE_C3_C4_CARROTLINK_2026-03-31_KO.md`

## 0. 현재 대화 기준 확정 방향

현재까지 합의된 방향은 다음과 같다.

- `web`과 `CarrotLink`를 **실시간 데이터 consumer 관점에서 구분하지 않는다**
- 실시간 데이터는 **`/ws/live` 하나로 통합**한다
- 영상은 **`/ws/camera/road` 하나로 단일화**한다
- `WebRTC`는 제거 방향으로 본다
- `CarrotLink`는 운영 경로에서 `/health`에 의존하지 않는다
- 내부에서는 당분간 `road + wide` 메타를 유지하되, **유저 노출은 road 중심**으로 간다
- `c3/c4`를 **별도 구현체처럼 나누지 않는다**
- `c3/c4` 차이는 외부에 노출하지 않고, **공통 코드 경로 안의 최소 normalize layer만 흡수**한다
- `c3 전용 파일`, `c4 전용 파일`, `c3.py`, `c4.py` 같은 분리 구조를 만들지 않는다
- 구현은 **같은 상대 경로, 같은 파일명, 같은 코드 구조**를 기준으로 유지한다

한 줄로 요약하면:

> **`SubMaster/Params -> RealtimeBroker -> service-raw semantic payload -> /ws/live + /ws/camera/road -> web + CarrotLink`**

이다.

추가 메모:

> **2026-04-01 기준 최신 결정은 canonical snapshot 확대가 아니라, `/ws/live`를 `meta/runtime/services` 형태의 service-raw semantic payload로 유지하는 것이다.**  
> 아래 문서 본문에 남아 있는 초기 `canonical snapshot` 표현은 역사적 초안으로 보고, 최신 기준은 이 상단 요약을 우선한다.

## 1. 목적

`c3`, `c4`, `웹당근`, `CarrotLink`가 현재 각각 비슷한 실시간 데이터를 **서로 다른 WS 경로와 서로 다른 payload 형태**로 다루고 있다.  
이 문서의 목적은 이를 단계적으로 정리해서:

- 중복 구독 제거
- 중복 payload 생성 제거
- `c3/c4` 차이를 공통 코드 경로 안의 최소 normalize layer가 흡수
- 웹과 앱이 같은 실시간 데이터 경로를 재사용
- 유지보수 비용과 런타임 부하 감소

를 달성하는 것이다.

---

## 2. 현재 문제 요약

### 웹당근

- `/ws/state`
- `/ws/carstate`
- `/ws/terminal`
- `/stream`

즉 **역할이 세분화된 구조**다.

### CarrotLink

- `/ws/camera/road`
- `/ws/camera/wideRoad`
- `/ws/live`
- `/ws/hud` 후보
- `/stream` 후보

즉 **카메라 + overlay** 중심 구조다.

### 문제점

- 비슷한 데이터를 서로 다른 경로에서 따로 조립함
- 웹과 앱이 같은 openpilot 서비스 데이터를 각각 다시 가공함
- `c3/c4` 차이를 여러 군데에서 반복 흡수함
- payload schema가 분산돼 있어 확장 시 수정 지점이 많음
- 일부 경로는 사실상 legacy 성격인데 계속 남아 있음

---

## 3. 리팩토링 목표

### 최종 목표

1. **실시간 데이터 구독은 한 군데**
2. **service-raw semantic payload는 한 종류**
3. **웹과 앱은 같은 실시간 데이터 경로 사용**
4. **`c3/c4`는 같은 코드 경로로 개발하고, 차이는 최소 normalize layer에서만 처리**
5. **영상 경로와 데이터 경로를 명확히 분리**
6. **consumer는 broker 내부 구현이 아니라 broker contract에만 의존**

추가 원칙:

> **`web`과 `CarrotLink`를 실시간 데이터 consumer 관점에서 구분하지 않는다.**

즉:

- `web 전용 payload`
- `CarrotLink 전용 payload`
- `web 전용 실시간 구독 규칙`
- `CarrotLink 전용 실시간 구독 규칙`

을 따로 두지 않고,

> **같은 service-raw payload와 같은 `/ws/live`를 공통 기준으로 사용**한다.

차이는:

- UI 표현
- 렌더링 방식
- 영상 transport

에서만 두고,
**메시지 구독과 실시간 데이터 계약은 하나로 통합**하는 것을 목표로 한다.

추가로 중요한 원칙은:

> **`CarrotLink`나 `web`이 broker 내부 구현에 의존하지 않게 한다.**

즉 consumer가 알아야 할 것은:

- broker가 살아 있는지
- snapshot이 fresh한지
- camera transport가 준비됐는지
- 현재 선택 카메라가 무엇인지

정도여야 한다.

반대로 consumer가:

- 내부 profile 세부 상태
- profile 전환 과정
- HUD/graphics/service별 세부 ready 판정
- flavor별 runtime 예외 처리

를 직접 많이 알수록 결합도가 커지고, 통합 구조의 의미가 줄어든다.

### `c3/c4` 공통분모 개발 원칙

이번 리팩토링에서는:

- `c3 전용 broker`
- `c4 전용 broker`
- `c3 전용 canonical payload`
- `c4 전용 /ws/live`

같은 방향을 피한다.

원칙은 다음과 같다.

1. **코드 경로는 하나**
2. **schema는 하나**
3. **transport 계약은 하나**
4. **파일 구조도 하나**
5. 차이는 **최소 normalize layer**에서만 흡수

즉:

> **`c3/c4`를 지원하되, `c3/c4`를 따로 개발하지 않는다.**

더 직접적으로는:

- `realtime/c3.py`
- `realtime/c4.py`
- `c3 전용 broker`
- `c4 전용 broker`

같은 구조를 만들지 않는다.

허용되는 차이는 오직:

- 서비스 존재 여부
- 필드 형태 차이
- 런타임 capability 차이

를 **같은 코드 안에서 보정하는 작은 normalize layer**뿐이다.

### 목표 아키텍처 한 줄 요약

> `SubMaster/Params -> RealtimeBroker -> service-raw semantic payload -> /ws/live -> web + CarrotLink`

### `service-raw semantic payload` 뜻

이 문서에서 말하는 `service-raw semantic payload`는:

> **openpilot service를 렌더 결과로 가공하지 않고, service 이름 중심으로 얇게 relay한 표준 실시간 상태 묶음**

을 뜻한다.

쉽게 말하면:

- 지금까지 broker는 `camera/model/vehicle/system/...` 같은 섹션형 snapshot을 한 번 더 조립했다
- 최신 방향은 broker가 `services.carState`, `services.modelV2`, `services.roadCameraState`처럼 **service 기준으로 얇게 보내고**
- web/CarrotLink가 그걸 가지고 직접 조립/연산/렌더하는 것이다

비유하면:

- 지금 broker
  - 서버가 큰 현황판을 매번 새로 그려서 보냄
- 바꿀 구조
  - 서버는 service별 원재료를 얇게 보내고, 클라이언트가 필요한 화면을 조립함

즉:

> **서버는 얇게 relay하고, 쓰는 쪽이 여러 개여도 같은 raw semantic 입력을 본다**

가 되게 하는 중간 결과물이 `service-raw semantic payload`이다.

예시 형태:

```json
{
  "meta": {},
  "nav": {},
  "runtime": {},
  "services": {
    "carState": {},
    "selfdriveState": {},
    "controlsState": {},
    "longitudinalPlan": {},
    "modelV2": {},
    "roadCameraState": {}
  }
}
```

즉 한 시점의 service별 semantic data를 **`services.<serviceName>`** 아래에 묶고,
운영 메타만 `meta/runtime`에 공통으로 둔 payload이다.

---

## 4. 범위

### 포함

- `E:\Carrot\c3\openpilot\selfdrive\carrot\server`
- `E:\Carrot\c3\openpilot\selfdrive\carrot\web`
- `E:\Carrot\c4\openpilot\selfdrive\carrot\server`
- `E:\Carrot\c4\openpilot\selfdrive\carrot\web`
- `E:\Carrot\CarrotLink\assets\sidecar\sidecar.py`
- `E:\Carrot\CarrotLink\lib\features\hud`
- `E:\Carrot\CarrotLink\lib\screens\drive`

### 제외

- YOLO 경로
- Git/로그/파일 관리 화면
- 터미널 기능의 세부 동작

### 권장 배치 경로

broker 구현은 openpilot 쪽 공통 상대 경로에 둔다.

- `selfdrive/carrot/realtime/`

즉:

- `E:\Carrot\c3\openpilot\selfdrive\carrot\realtime\`
- `E:\Carrot\c4\openpilot\selfdrive\carrot\realtime\`

를 같은 구조로 유지하고, 파일 책임도 동일하게 맞춘다.

권장 파일 예:

- `broker.py`
- `snapshot.py`
- `contract.py`
- `normalize.py`
- `transports/live_ws.py`
- `transports/camera_ws.py`

핵심은:

> **경로를 두 벌로 나누는 것이 아니라, 같은 상대 경로와 같은 파일 책임을 유지한 채 공통분모로 개발하는 것**이다.

즉 구현 단계에서도:

- `c3에서 먼저 만든 뒤 c4 버전을 따로 만들지 않는다`
- 하나의 공통 파일 구조를 만든 뒤, 동일 구조를 그대로 유지한다

가 원칙이다.

---

## 5. 통합 방향

## 5.1 데이터 경로는 `/ws/live`로 통합

가장 현실적인 방향은:

- 웹당근도 `/ws/live`를 주 실시간 채널로 사용
- CarrotLink도 계속 `/ws/live` 사용
- `/ws/state`, `/ws/carstate`, `/ws/hud`는 단계적으로 축소

여기서 중요한 정책은:

> **web과 CarrotLink가 서로 다른 실시간 메시지 체계를 쓰지 않는 것**

이다.

즉 최종적으로는:

- `web consumer`
- `CarrotLink consumer`

모두가 같은 `/ws/live` snapshot을 읽고,
각자 필요한 필드만 사용한다.

즉:

- **웹당근**
  - 상태/HUD를 `/ws/live`에서 꺼내씀
- **CarrotLink**
  - 기존처럼 `/ws/live` 사용

---

## 5.2 영상은 `ws/camera/road` 기준으로 정리

현재 논의 기준으로는 영상 경로를 이원화하지 않고 다음 방향으로 정리한다.

- 웹당근: `WebRTC` 제거
- CarrotLink: 기존 `ws/camera/*` 기반 유지
- 공통 목표: **`ws/camera/road` + `/ws/live`**

즉:

> **영상은 `road` 카메라의 `ws/camera`를 공통 기준으로 사용하고,  
> 실시간 그래픽/HUD 데이터는 `/ws/live`로 통일**한다.

이 결정을 먼저 두는 이유는:

- 브라우저에서도 stock 그래픽모드를 **프레임 단위로 맞추는 것**이 목표이고
- 그 경우 `frameId` 기준 sync는 `WebRTC`보다 `ws/camera` 쪽이 더 직접적이며
- `CarrotLink`의 기존 sync 구조도 이미 카메라 frame metadata를 중심으로 동작하기 때문이다

즉 현재 1차 목표는:

- **실시간 데이터 구독/전달 통합**
- **영상 transport는 `ws/camera/road` 중심으로 단일화**

이다.

### 카메라 원칙: 메타는 broker, 영상은 별도 경로

여기서 중요한 점은 **카메라 영상과 카메라 메타를 분리**해서 다뤄야 한다는 것이다.

- broker에 포함할 것
  - `roadCameraState`
  - `wideRoadCameraState`
  - `frameId`
  - `timestampSof`
  - 선택 카메라 정보
  - source size / sensor / deviceType
- broker에 포함하지 않을 것
  - H264 video frame
  - raw encoded stream

즉:

> **카메라 메타는 `/ws/live` canonical payload에 포함하고,  
> 실제 영상은 `ws/camera/road` 같은 별도 transport로 유지**한다.

이 방식이 맞는 이유는:

- overlay sync는 camera frame metadata를 필요로 하지만
- actual video transport는 별도 품질/codec/latency 정책을 가지기 때문

### 유저 노출은 road-only, 내부 메타는 road + wide 유지

현재 CarrotLink는 기본적으로 `road` 카메라를 기준으로 시작한다.  
다만 wide 전환 시에는 projection, source size, frame sync가 선택 카메라 기준으로 바뀐다.

즉 정책은 다음이 적절하다.

- **UI/유저 노출**
  - 기본은 `road`만 노출
  - wide 카메라는 숨기거나 선택 UI를 최소화
- **내부 canonical payload**
  - `roadCameraState`와 `wideRoadCameraState`를 둘 다 유지

그 이유는:

- 현재 frame sync가 선택된 카메라의 `frameId`를 기준으로 동작하고
- wide 메타가 road fallback 또는 health 판단에 여전히 쓰일 수 있기 때문이다

즉:

> **유저에게는 road-only가 가능하지만,  
> broker 설계는 당분간 road + wide 메타를 모두 유지하는 것이 안전**하다.

### 가장 중요한 그래픽 원칙: projection/geometry는 CarrotLink 기준 유지

이번 리팩토링에서 가장 중요한 것은 **HUD 장식보다 차선/경로/path/lead radar box의 좌표계와 매핑 원리**다.

즉 다음은 최대한 **현재 CarrotLink 원리**를 기준으로 유지한다.

- lane line
- path polygon
- road edge
- lead / radar box
- nav path
- frame sync

특히 유지해야 하는 것은:

- 카메라 좌표 -> 화면 좌표 projection
- calibration 반영 방식
- smoothing / clamp 원칙
- `modelFrameId / roadFrameId / wideRoadFrameId` 정합 규칙

의미는 다음과 같다.

- `c3` 스타일의 텍스트/HUD 배치는 바꿀 수 있다
- 하지만 **그래픽 위치를 정하는 수학 경로와 sync 원리**는 함부로 바꾸지 않는다
- `web`과 `CarrotLink`가 같은 canonical snapshot을 쓰더라도,
  **projection 엔진의 source-of-truth는 CarrotLink로 둔다**

기준 코드:

- [E:\Carrot\CarrotLink\lib\screens\drive\live_drive_canvas_overlay_components.dart](/E:/Carrot/CarrotLink/lib/screens/drive/live_drive_canvas_overlay_components.dart)
  - `_intrinsicForSource(...)`
  - `_calibTransformForSource(...)`
  - `_buildTransform(...)`
  - `_mapToScreen(...)`
- [E:\Carrot\CarrotLink\lib\screens\drive\live_drive_canvas_overlay_sync_components.dart](/E:/Carrot/CarrotLink/lib/screens/drive/live_drive_canvas_overlay_sync_components.dart)
  - frame sync / frameId 매칭
- [E:\Carrot\CarrotLink\lib\screens\drive\live_drive_canvas_overlay_models_components.dart](/E:/Carrot/CarrotLink/lib/screens/drive/live_drive_canvas_overlay_models_components.dart)
  - canonical overlay snapshot 구성

즉:

> **데이터 계약은 통합하되,  
> 차선/경로패스/리드 레이더 박스 위치를 정하는 projection 원리는 CarrotLink를 기준으로 유지**한다.

---

## 5.3 `c3/c4`는 같은 코드 경로로 두고, 차이는 최소 normalize layer로 숨김

외부 `/ws/live` schema는 동일하게 유지하고, 내부에서만:

- `repoFlavor`
- `deviceType`
- `sensor`
- 서비스 존재 여부
- 필드 형태 차이

를 보고 필요한 최소 차이만 normalize한다.

즉:

> 외부 consumer는 `c3/c4`를 몰라도 되고,  
> broker 내부의 최소 normalize layer만 차이를 알게 한다.

여기서 중요한 것은:

- `c3 전용 transport`
- `c4 전용 snapshot builder`
- `c3/c4 전용 consumer contract`
- `c3 전용 서비스 세트`
- `c4 전용 서비스 세트`

를 만들지 않는 것이다.

즉:

> **공통 코드 경로 하나를 유지하고,  
> `c3/c4` 차이는 작은 호환 계층으로만 가둔다.**

---

## 5.4 broker health는 debug용으로만 축소하고, 운영은 data-plane 기준으로 본다

현재 구조는 앱이 sidecar 내부 상태를 많이 안다.

예:

- profile이 맞는지
- `hudReady`, `graphicsReady`, `vehicleReady`가 각각 어떤지
- 특정 service가 fresh한지
- 기존 flavor별 예외나 내부 특수 규칙이 무엇인지

이 정보는 현재 구조를 디버깅하는 데는 유용하지만,
장기적으로는 consumer와 runtime 구현을 강하게 결합시킨다.

최종 목표에서는 운영 경로에서 `/health`를 직접 쓰지 않는다.

즉 `CarrotLink`와 `web`은 다음만 보면 된다.

- `/ws/live` 연결 성공
- hello/meta 수신
- canonical snapshot이 일정 주기로 갱신됨
- snapshot age가 허용 범위 안임
- `/ws/camera/road` 첫 frame이 오고, frame age가 허용 범위 안임

즉:

> **운영 경로는 health-driven이 아니라 data-driven으로 바뀐다.**

다만 `/health` 자체는 완전히 없애기보다,
초기에는 **debug/개발 진단 전용 최소 contract**로만 남길 수 있다.

예:

```json
{
  "ok": true,
  "snapshotFresh": true,
  "cameraReady": true,
  "lastSnapshotAgeMs": 84,
  "selectedCamera": "road",
  "transport": {
    "live": "ok",
    "camera": "ok"
  }
}
```

의미:

- 앱 운영 경로는 `/health`를 직접 신뢰하지 않는다
- 개발자 도구/디버그에서만 참고한다
- 내부 동작 모드, 세부 freshness 판정, 특수 예외 규칙은 broker 내부에 숨긴다

---

## 6. 목표 payload 구조

`/ws/live` canonical payload는 섹션형으로 고정한다.

```json
{
  "meta": {},
  "camera": {},
  "model": {},
  "radar": {},
  "vehicle": {},
  "system": {},
  "carrot": {},
  "nav": {},
  "runtime": {}
}
```

### 섹션 역할

- `meta`
  - `repoFlavor`, `deviceType`, `sensor`
  - schema version
  - optional capability flags
- `camera`
  - `selectedCamera`
  - `roadCameraState`, `wideRoadCameraState`
  - `roadSourceSize`, `wideRoadSourceSize`
- `model`
  - `modelV2`, path/lane summary
- `radar`
  - `radarState`
- `vehicle`
  - `carState`, `controlsState`, `selfdriveState`, `longitudinalPlan`
- `system`
  - `deviceState`, `peripheralState`
- `carrot`
  - `carrotMan`
- `nav`
  - `navInstructionCarrot`, `gpsLocationExternal`, `lateralPlan`
- `runtime`
  - snapshot freshness, stale reason, debug

### 카메라 기본 기준

canonical payload는 `road`를 기본 카메라 기준으로 간주하되,  
실제 projection/sync는 `selectedCamera` 기준으로 계산 가능해야 한다.

즉:

- 기본 시작점: `road`
- 현재 선택 카메라: `selectedCamera`
- camera sync fallback: `wideRoadFrameId ?? roadFrameId` 또는 그 반대의 선택 규칙

이 규칙을 payload에 명시적으로 담아두는 것이 중요하다.

---

## 7. 단계별 계획

## 7.1 1단계: schema 동결

할 일:

- 현재 웹당근 `/ws/state`, `/ws/carstate`
- 현재 CarrotLink `/ws/live`

가 실제로 쓰는 필드를 목록화

산출물:

- canonical payload field list
- 필드별 출처(service/params) 표
- deprecated field 목록

목표:

- consumer가 어떤 필드를 쓸지 먼저 고정

---

## 7.2 2단계: broker 도입

할 일:

- `SubMaster` 구독을 한 군데로 모으는 `RealtimeBroker` 도입
- 공통 서비스 세트 + 선택 서비스 세트를 broker 내부에서 관리
- 최소 normalize layer를 broker 내부에 둠

초기 형태:

- 우선 기존 sidecar 내부에서 시작할 수는 있지만,
- 최종 목표는 `selfdrive/carrot/realtime/` 공통 경로로 분리

목표:

- **구독 1회**
- **payload 조립 1회**

---

## 7.3 3단계: `/ws/live` 공통화

할 일:

- 웹당근에서 `/ws/state`, `/ws/carstate` 대신 `/ws/live` 소비
- 필요한 경우 웹 전용 얇은 mapper만 유지
- `/ws/state`, `/ws/carstate`는 내부적으로 `/ws/live` snapshot 기반 shim으로만 유지

목표:

- 웹/앱이 같은 실시간 source를 공유

---

## 7.4 4단계: legacy 경로 축소

대상:

- `/ws/state`
- `/ws/carstate`
- `/ws/hud`

방식:

- 바로 삭제하지 않고 호환 계층으로 유지
- 충분히 안정화되면 deprecated 처리

목표:

- 외부 인터페이스 단순화

---

## 7.5 5단계: `ws/camera/road` runtime 정리

영상 방향은 이미 확정으로 본다.

- 공통 transport: `ws/camera/road`
- 제거 대상: `/stream` 기반 WebRTC

이 단계에서 할 일:

- 브라우저 `ws/camera/road` 디코드/렌더 안정화
- 앱 `ws/camera/road` transport 단일화
- multi-client fan-out 시 queue/backpressure 정책 정리
- road-only 영상 정책 검증

즉:

> **영상은 재검토 대상이 아니라, `ws/camera/road` 전제로 runtime을 정리하는 단계**다.

---

## 8. 우선 제거해야 할 중복

### 중복 후보

1. 웹당근용 별도 HUD payload 생성
2. 앱용 별도 live payload 생성
3. `c3/c4` flavor 분기를 consumer 쪽에서 반복 처리
4. 유사한 stale/runtime health 계산 중복
5. `/ws/state`와 `/ws/carstate`의 경계가 불명확한 부분
6. `c3/c4`를 별도 구현체처럼 취급하는 개발 방식

### 가장 먼저 줄일 것

1. **SubMaster 중복**
2. **payload 생성 중복**
3. **field naming 중복**

---

## 9. 부하 절감 포인트

### 확실한 이득이 있는 것

- 구독 1회화
- payload 조립 1회화
- `msgpack` 기본화
- low-rate / high-rate 필드 분리
- changed-fields 또는 delta 전송 검토
- `road` 카메라 단일 transport 기준 정리

### 병목에 대한 정확한 해석

`RealtimeBroker`를 잘 만들면:

- `SubMaster` 중복 구독
- 중복 payload 조립
- 웹/앱별 별도 실시간 계산

은 크게 줄어든다.

즉 기기 자체에서의 **원본 데이터 수집/조립 병목**은 분명히 줄어든다.

다만 이것이:

> **"여러 군데로 뿌려도 기계 쪽 병목이 완전히 없다"**

는 뜻은 아니다.

여전히 남는 병목 후보는:

- client 수가 늘어날수록 증가하는 socket fan-out 비용
- client별 serialization / queue 관리 비용
- 카메라 frame 복사/dispatch 비용
- 무선 네트워크 업링크 대역폭
- 느린 client 때문에 생기는 backpressure

즉 올바른 표현은:

> **RealtimeBroker가 source-side 병목과 중복 연산을 크게 줄여주지만,  
> multi-client fan-out 자체의 비용까지 0으로 만드는 것은 아니다.**

따라서 목표는:

- **원본 구독/조립은 1회**
- **전송 fan-out은 얇게**
- **느린 consumer는 drop/샘플링**

으로 잡는 것이 맞다.

### 주의할 점

- 너무 이른 영상 통합
- 웹/앱 표시 요구를 한 번에 완전히 맞추려는 과설계
- 공통분모를 만들지 않고 기존 브랜치별 예외 로직을 그대로 복제하는 것
- wide 카메라를 너무 일찍 제거해서 sync/health fallback을 잃는 것
- consumer가 broker 내부 health detail까지 다시 직접 알게 만드는 것
- `c3/c4`를 다른 파일/다른 구조로 따로 키우는 것

---

## 10. 예상 이점

### 기능

- 웹과 앱이 같은 데이터 정의를 씀
- 공통 코드 경로에서 `c3/c4` 대응이 일관됨
- stock HUD / 그래픽 / carrot 데이터 확장이 쉬워짐

### 성능

- 불필요한 중복 계산 감소
- 메시지 fan-out 비용 감소
- 실시간 상태 관리 단순화
- `WebRTC` 제거로 transport 복잡도 감소
- `road` 단일 영상 기준으로 카메라 경로 단순화

### 유지보수

- 디버깅 지점 축소
- schema 버전 관리 쉬움
- 새 consumer 추가 시 부담 감소
- 앱과 웹이 broker 내부 구현 변경에 덜 흔들림

---

## 11. 리스크

### 높은 리스크

- normalize layer가 커지면서 공통 코드 경로가 다시 복잡해질 수 있음
- 기존 웹 HUD가 기대하는 field 형식과 어긋날 수 있음
- CarrotLink가 기대하는 `/ws/live` timing/sync에 영향 줄 수 있음

### 대응

- shim 기간 유지
- field contract 문서화
- `c3`, `c4` 각각 최소 1개 대표 기기에서 점검
- normalize layer를 작게 유지하고, feature 분기는 consumer가 아니라 snapshot 단계에서 종료

---

## 12. 현재 권장 전략

현 시점 권장 순서:

1. **문서화**
2. **canonical payload 정의**
3. **broker 도입**
4. **broker 내부 normalize layer / snapshot / transport 완성**
5. **broker 단독 health / freshness / fan-out 검증**
6. **그 다음 web / CarrotLink endpoint 연결**
7. **마지막으로 legacy WS 축소**

즉:

> 먼저 **broker를 독립적으로 완성**하고,  
> 그 다음에 web / CarrotLink가 그 endpoint를 소비하게 연결하는 게 맞다.

### 현재 우선순위 원칙

현재 단계에서는:

- `web` consumer 수정
- `CarrotLink` consumer 수정
- 기존 endpoint와의 호환 shim

을 먼저 하지 않는다.

우선은 openpilot 쪽에서 다음을 완성하는 것이 핵심이다.

- `RealtimeBroker`
- canonical snapshot
- `/ws/live`
- `/ws/camera/road`
- broker 내부 normalize layer
- broker 기준 freshness / fan-out 정책

즉:

> **지금은 consumer가 아니라 producer를 먼저 완성하는 단계**다.

---

## 13. 다음 보강 예정

이 문서에 다음 내용을 이어서 보강한다.

- `/ws/live` 필드별 출처 표
- 웹당근 `/ws/state`, `/ws/carstate` 필드 맵
- CarrotLink consumer별 실제 사용 필드 목록
- 공통 서비스 세트와 선택 서비스 세트 표
- migration 순서와 호환성 체크리스트

---

## 14. 한 줄 결론

가장 좋은 통합 방향은:

> **`SubMaster/Params -> RealtimeBroker -> canonical /ws/live -> web + CarrotLink`**

구조로 정리하고,  
**영상은 `ws/camera/road` 기준으로 단일화하고, 데이터는 `/ws/live`로 통합**하는 것이다.

---

## 15. 최종 구조 요약

### 15.1 최종적으로 살아 있는 것

#### openpilot 기기 내부

- `RealtimeBroker`
  - 유일한 실시간 데이터 구독자
  - `SubMaster`와 `Params`를 읽어 canonical snapshot 생성
- `camera relay`
  - `road` 카메라 영상만 송출
- optional debug health
  - 개발/진단 용도로만 최소 유지 가능

#### 외부 공개 인터페이스

- `/ws/live`
  - web + CarrotLink 공통 실시간 데이터 채널
- `/ws/camera/road`
  - web + CarrotLink 공통 road 영상 채널
- `/ws/terminal`
  - 웹 터미널 기능 때문에 별도 유지
- `/health`
  - 가능하면 debug/개발 진단 전용으로만 축소

### 15.2 최종적으로 축소/제거 대상

- `/ws/state`
- `/ws/carstate`
- `/ws/hud`
- `/stream` 기반 WebRTC 경로
- `/profile`
- `/camera_quality`
- consumer가 직접 아는 내부 동작 모드/세부 freshness detail
- wide 카메라의 사용자 노출 경로

---

### 15.3 최종 구독 구조

#### 1. 기기 내부 구독

`RealtimeBroker`만 다음을 구독한다.

- `SubMaster` 서비스
  - `selfdriveState`
  - `carState`
  - `controlsState`
  - `longitudinalPlan`
  - `liveCalibration`
  - `modelV2`
  - `roadCameraState`
  - `wideRoadCameraState`
  - `deviceState`
  - 필요 시 `radarState`, `carrotMan`, `gpsLocationExternal`, `lateralPlan`, `navInstructionCarrot`
- `Params`
  - path/HUD 관련 표시 옵션
  - selected camera / transport 정책

즉:

> **원본 구독은 broker 1곳만 수행**

#### 2. web consumer

web은:

- `/ws/live` 구독
  - HUD
  - stock 그래픽
  - 상태 표시
- `/ws/camera/road` 구독
  - road 영상
- `/ws/terminal` 구독
  - 웹 터미널

#### 3. CarrotLink consumer

CarrotLink는:

- `/ws/live` 구독
  - HUD
  - stock 그래픽
  - sync metadata
  - 진단용 상태
- `/ws/camera/road` 구독
  - road 영상

즉:

> **web과 CarrotLink는 같은 실시간 메시지 계약을 사용하고,  
> 차이는 UI와 렌더 방식만 가진다.**

단, 예외가 하나 있다.

- `web`의 터미널은 `/ws/terminal`을 계속 사용한다
- CarrotLink의 터미널/TMUX 로그/기기 로그 화면은 이 실시간 WS 통합 범위에 포함하지 않는다

즉 CarrotLink 쪽:

- 터미널 탭은 SSH 기반 interactive stream
- TMUX 로그/기기 로그는 SSH 명령 실행 + 파일/출력 캡처

구조로 유지하고,
`RealtimeBroker`, `/ws/live`, `/ws/camera/road`와는 분리한다.

---

### 15.4 한눈에 보는 최종 흐름

```text
SubMaster + Params
        ->
  RealtimeBroker
        ->
  canonical snapshot
        ->
      /ws/live  -----------------> web
        |                         CarrotLink
        |
      /ws/camera/road ----------> web
                                  CarrotLink
```

### 15.5 최종 상태 한 줄 요약

> **기기 내부에서는 `RealtimeBroker` 하나만 실시간 원본을 구독하고,  
> 외부에는 `/ws/live`와 `/ws/camera/road`만 공통으로 내보내는 구조**가 최종 목표다.

---

### 15.6 `health`를 앱 운영 경로에서 제거하는 경우

CarrotLink와 web은 더 이상 `/health`를 직접 신뢰하지 않고,
실제 데이터 평면만 보고 동작한다.

#### 운영 기준

- `/ws/live`
  - 연결 성공
  - hello/meta 수신
  - canonical snapshot 주기적 수신
  - snapshot age 허용 범위 내 유지
- `/ws/camera/road`
  - 첫 frame 수신
  - 마지막 frame age 허용 범위 내 유지

즉:

> **앱은 broker 내부 상태가 아니라 실제 데이터 흐름이 살아 있는지만 본다.**

---

### 15.7 현재 CarrotLink 렌더 범위와 잔여 후보

#### 이미 표기되는 핵심 범위

- openpilot/stock 계열
  - path / lane lines / road edges
  - `pathMode`, `pathColor`, `activeLaneLine`, `useLaneLineSpeed` 기반 path 스타일 분기
  - brake lights에 따른 path stroke/강조 변화
  - lead / radar 계열
  - `leadOne`, `leadTwo` 뿐 아니라 `leadLeft`, `leadRight` 보조 lead 정보
  - radar badge / radar vector / state text
  - calibration 기반 projection
  - `modelFrameId`, `roadFrameId`, `wideRoadFrameId` 기반 sync
  - nav path / turn / main text
  - stop-distance / TF marker
  - lane metrics / 상단 우측 debug 텍스트
- carrot 계열
  - `xState`, `trafficState`, `tFollow`, `desiredDistance`
  - lane change state / direction
  - blindspot
  - `stockDebugTopRightText`
  - `sidecarOverlay2d`
  - `activeCarrot`, `desiredSpeed`, `desiredSource`

즉 현재도:

> **핵심 주행 그래픽과 carrot 주행 의미 정보는 대부분 이미 전달/매핑되고 있다.**

#### 아직 명시적으로 완전 표기된 것을 확인하지 못한 후보

- c3 스타일의 좌상단 날짜/시계 블록
- c4 HUD의 richer traffic-light 표현
  - 현재는 신호 상태/점/문구 중심이고, 원본과 동일한 lamp/countdown 스타일은 아님
- c4 HUD의 일부 미세 텍스트 군
  - 예: SR/road-name/보조 상태 텍스트의 원본형 배치
- carrot 원본 HUD와 완전히 동일한 desired source/activeCarrot 타이포그래피
- debug plot의 최종 product 노출 여부
  - 현재 snapshot/renderer엔 경로가 있으나, 최종 사용자 표기 범위로 고정할지는 별도 결정 필요

정리하면:

> **핵심 주행 그래픽은 대부분 들어와 있지만, 일부 HUD 장식/마이크로 텍스트/원본형 표현은 아직 1:1로 다 옮겨진 상태는 아니다.**

---

### 15.8 구현 원칙 최종 정리

이번 리팩토링의 최종 구현 원칙은 다음과 같다.

- `c3`용 구현과 `c4`용 구현을 따로 만들지 않는다
- `c3 전용 파일`, `c4 전용 파일`, `c3.py`, `c4.py` 같은 분리 파일을 만들지 않는다
- `web`용 실시간 데이터와 `CarrotLink`용 실시간 데이터를 따로 만들지 않는다
- openpilot 쪽 공통 경로인 `selfdrive/carrot/realtime/`를 중심으로 개발한다
- `SubMaster + Params` 원본 구독은 `RealtimeBroker` 한 곳만 수행한다
- semantic realtime data는 `/ws/live` 하나로만 배포한다
- 영상은 `/ws/camera/road` 하나로만 배포한다
- consumer는 broker 내부 구현을 모르고, 공통 contract만 사용한다
- 그래픽 좌표/맵핑/리드 박스 원리는 CarrotLink를 source-of-truth로 유지한다
- 텍스트/HUD 배치는 `c3` 스타일을 기준으로 가져간다

즉:

> **브랜치별 구현을 늘리는 방식이 아니라,  
> 공통분모를 먼저 완성하고 차이는 최소 normalize layer 안에만 가두는 방식으로 개발한다.**

---

## 16. 개발 로드맵 / 페이즈

이 로드맵은 앞으로 계속 참고하는 작업 기준이다.

### Phase 1. 공통 realtime 골격 만들기

목표:

- `selfdrive/carrot/realtime/` 공통 경로 확정
- `broker.py`
- `snapshot.py`
- `contract.py`
- `normalize.py`
- `transports/live_ws.py`
- `transports/camera_ws.py`

원칙:

- `c3`용/`c4`용 파일을 따로 만들지 않는다
- 같은 상대 경로, 같은 파일명, 같은 코드 구조로만 개발한다
- 이 단계에서는 `web`, `CarrotLink` consumer 연결을 하지 않는다

완료 기준:

- broker 프로세스가 단독으로 뜬다
- 내부에서 `SubMaster + Params`를 한 번만 읽는다
- canonical snapshot을 메모리에서 생성할 수 있다

### Phase 2. canonical snapshot 고정

목표:

- `/ws/live` 공통 schema 고정
- HUD / stock 그래픽 / sync 메타 필드 고정
- `road` 카메라 기준 정책 고정

원칙:

- 문자열 포맷보다 semantic field 우선
- HUD 배치는 `c3` 스타일 기준
- 그래픽 좌표/맵핑 원리는 CarrotLink 기준

완료 기준:

- snapshot 필드 표가 문서와 코드에 대응된다
- `web`, `CarrotLink` 모두 같은 필드 계약을 쓸 수 있다

### Phase 3. broker 단독 검증

목표:

- TMUX 로그
- stdout/stderr 로그
- `/ws/live`
- `/ws/camera/road`

만으로 broker 동작 검증

원칙:

- 아직 consumer UI 연결은 하지 않는다
- `/health`에 의존하지 않는다
- 실제 data-plane freshness로만 본다

완료 기준:

- snapshot 주기 정상
- stale 판정 정상
- road camera frame 송출 정상
- fan-out 정책 정상

### Phase 4. legacy 경로 축소 준비

목표:

- 기존 `/ws/state`
- 기존 `/ws/carstate`
- 기존 `/ws/hud`
- `/stream`

의존 구간을 정리할 준비를 한다.

원칙:

- 바로 삭제하지 않는다
- 새 broker 경로가 안정화될 때까지 참조만 남긴다

완료 기준:

- legacy 경로가 새 공통 contract로 치환 가능한 상태가 된다

### Phase 5. consumer 연결

목표:

- `web`
- `CarrotLink`

가 공통 broker endpoint를 소비하도록 연결

원칙:

- 둘을 다른 consumer로 설계하지 않는다
- 같은 `/ws/live`, 같은 `/ws/camera/road`를 본다
- 차이는 렌더/UI에서만 둔다

완료 기준:

- `web`, `CarrotLink` 모두 같은 contract로 표시된다
- consumer가 broker 내부 구현을 모른다

### Phase 6. 정리와 제거

목표:

- legacy WS 제거
- debug 전용 경로 최소화
- 문서와 코드 contract 최종 동기화

원칙:

- `c3/c4` 분리 구현이 새로 생기면 안 된다
- 공통 코드 경로 원칙을 끝까지 유지한다

완료 기준:

- 실시간 데이터 경로는 `/ws/live` 하나
- 영상 경로는 `/ws/camera/road` 하나
- 터미널은 `/ws/terminal`만 별도 유지

### 로드맵 한 줄 요약

> **브로커를 먼저 완성하고, 그다음 snapshot을 고정하고, TMUX/WS 로그로 검증한 뒤, 마지막에 web과 CarrotLink를 같은 contract로 붙인다.**

## 16.1 현재 상태 요약

현재까지 확인된 상태:

- `realtime broker` 공통 골격 구현 완료
- broker standalone runner 검증 완료
- alive/onroad 상태에서 core/optional 서비스 수집 정상 확인
- `/ws/live` endpoint 연결 완료
- `/ws/live` raw 테스트에서 `hello -> snapshot -> snapshot` 전달 확인

현재 남은 큰 축:

1. `msgpack`을 브랜치 기본 포함으로 정리
2. `web`을 `/ws/live`에 먼저 연결
3. 이후 `/ws/camera/road`와 stock graphics sync로 확장

현재 해석:

> producer 기준으론 1차 동작 검증이 끝났고, 이제 consumer 연결을 시작해도 되는 상태다.

## 16.2 브라우저 렌더 원칙

브라우저도 `CarrotLink`와 같은 방향으로 간다.

즉:

- `RealtimeBroker`는 **데이터와 sync 메타**를 보낸다
- `web` consumer는 그 데이터를 받아 **브라우저 디바이스에서 직접 HUD/stock 그래픽을 그린다**
- 서버가 lane/path/lead box를 미리 그린 bitmap을 보내는 구조로 가지 않는다

이 원칙의 이유:

- `CarrotLink`도 이미 클라이언트 쪽에서 projection/overlay를 렌더한다
- 브라우저도 같은 방식으로 가야 `web`과 `CarrotLink`가 같은 canonical snapshot을 공유할 수 있다
- 데이터 채널 부하는 상대적으로 작고, 실제 최적화 포인트는 브라우저의 video decode와 canvas overlay 렌더 쪽이다

한 줄 원칙:

> **`RealtimeBroker`는 그릴 데이터를 보내고, 실제 HUD/stock 그래픽은 브라우저/앱 클라이언트가 직접 그린다.**

---

## 17. 권장 파일별 책임표

브로커는 하나의 파일에 전부 몰아넣지 않고, **최소한의 책임 분리**를 유지한다.

### `broker.py`

역할:

- 메인 루프
- 갱신 주기 관리
- `SubMaster`/`Params` polling orchestration
- snapshot 생성 호출
- fan-out 호출

넣지 말 것:

- 필드별 세부 매핑 로직
- transport별 저수준 구현
- 브랜치별 전용 분기

### `services.py`

역할:

- 공통 서비스 세트 정의
- 선택 서비스 세트 정의
- 서비스 추가/삭제 지점 단일화

넣지 말 것:

- snapshot 조립 로직
- transport 로직

### `snapshot.py`

역할:

- canonical snapshot 조립
- 섹션별 payload 작성
  - `meta`
  - `camera`
  - `model`
  - `radar`
  - `vehicle`
  - `system`
  - `carrot`
  - `nav`
  - `runtime`

넣지 말 것:

- socket 전송 로직
- 브로커 루프 제어

### `normalize.py`

역할:

- 값 형태 보정
- 서비스 유무 차이 흡수
- 공통 snapshot에 맞는 최소 normalize

원칙:

- 크게 만들지 않는다
- `c3 전용`, `c4 전용` 분기 파일로 키우지 않는다
- 공통 코드 경로 안의 얇은 보정층으로만 유지한다

### `contract.py`

역할:

- `/ws/live` schema 정의
- 필드 이름 기준 문서화
- schema version 관리

### `transports/live_ws.py`

역할:

- `/ws/live` 송출
- `msgpack` 직렬화
- client queue / drop policy / fan-out

### `transports/camera_ws.py`

역할:

- `/ws/camera/road` 송출
- road 영상 frame dispatch
- video transport queue / fan-out

### 파일 구조 한 줄 원칙

> **구독 목록은 `services.py`, payload 조립은 `snapshot.py`, 전송은 `transports/*`로 분리하고, `broker.py`는 전체 흐름만 관리한다.**

---

## 18. SubMaster 항목 주석 규칙

`SubMaster` 항목은 나중에 쉽게 추가/삭제할 수 있게 **항목별 설명 주석**을 남긴다.

### 기본 원칙

각 항목 옆에는 최소한 다음을 적는다.

- 무엇에 쓰는지
- 필수인지 선택인지
- 누가 소비하는지
- 제거 시 영향이 무엇인지

### 서비스 세트 구분

서비스는 최소한 다음 두 그룹으로 구분한다.

- `COMMON_SERVICES`
  - 거의 모든 snapshot에 필요
  - 제거 시 `/ws/live` 기본 contract가 흔들릴 수 있음
- `OPTIONAL_SERVICES`
  - 특정 HUD/stock graphics/carrot/nav 기능용
  - 제거 시 일부 기능만 비활성

### 주석 예시

```python
# COMMON_SERVICES:
# - 거의 모든 snapshot에서 필요
# - 제거 시 /ws/live 기본 contract가 깨질 수 있음
COMMON_SERVICES = [
  "selfdriveState",   # 주행 상태/HUD 기본 상태
  "carState",         # 속도/기어/브레이크 등 차량 상태
  "controlsState",    # 제어 상태/HUD 보조 상태
  "modelV2",          # 차선/path/lead 그래픽 원본
  "roadCameraState",  # road frameId / timestamp / sync 기준
]

# OPTIONAL_SERVICES:
# - 기능 확장용
# - 없으면 일부 HUD/보조 기능만 비활성
OPTIONAL_SERVICES = [
  "radarState",           # lead/radar badge/vector
  "carrotMan",            # carrot 전용 HUD/상태
  "gpsLocationExternal",  # 위치/시간/보조 정보
  "lateralPlan",          # lane-less / lateral 보조 정보
  "navInstructionCarrot", # nav 문구/안내
]
```

### snapshot 매핑 주석 규칙

`snapshot.py`에는 각 필드가 어디서 오는지도 간단히 남긴다.

예:

```python
# camera.roadFrameId:
# - source: roadCameraState.frameId
# - used by: frame sync / overlay matching
# - fallback: None
```

### 추가/삭제 절차

새 서비스를 추가할 때는:

1. `services.py`에 추가
2. 주석에 용도/영향 기록
3. `snapshot.py`에 매핑 추가
4. `contract.py`에 노출 필드 반영

서비스를 제거할 때는:

1. 실제 consumer 사용 여부 확인
2. `snapshot.py` 매핑 제거
3. `contract.py` deprecated 여부 반영
4. 주석과 문서 동기화

### 한 줄 원칙

> **`SubMaster` 항목은 그냥 나열하지 말고, 왜 필요한지와 빼면 뭐가 깨지는지를 코드 주석으로 바로 알 수 있게 적어둔다.**
