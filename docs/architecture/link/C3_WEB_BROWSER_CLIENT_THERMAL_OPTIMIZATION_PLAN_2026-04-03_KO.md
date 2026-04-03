# C3 Web 브라우저 클라이언트 발열 최적화 계획 (2026-04-03)

## 목적

- `c3/openpilot/selfdrive/carrot/web/` 주행 페이지를 여는 **브라우저 클라이언트 기기**의 발열과 배터리 소모를 줄인다.
- 1차 목표는 서버 프로토콜을 크게 바꾸지 않고, 현재 코드 기준에서 체감 온도와 메인 스레드 부하를 낮추는 것이다.
- stock 스타일 parity, lane/path/lead 정합, HUD 의미는 유지한다.

## 범위

이 문서는 **클라이언트 브라우저 발열**이 주제다.  
다만 현재 구조상 서버 전송 정책이 클라이언트 wakeup/decode 빈도에 직접 영향을 주므로, 관련 서버 경로도 함께 본다.

- 클라이언트 포함:
  - `selfdrive/carrot/web/js/home_drive.js`
  - `selfdrive/carrot/web/js/app_realtime.js`
  - `selfdrive/carrot/web/js/raw_capnp.js`
  - `selfdrive/carrot/web/index.html`
  - `selfdrive/carrot/web/css/app.css`
- 서버 포함:
  - `selfdrive/carrot/server/core.py`
  - `selfdrive/carrot/server/live_compat/broker.py`
  - `selfdrive/carrot/realtime/transports/raw_ws.py`
  - `selfdrive/carrot/realtime/transports/camera_ws.py`
- 제외:
  - comma 디바이스 자체 발열
  - openpilot producer 내부 연산 최적화

## 2026-04-03 구현 상태

1차 브라우저 발열 대응은 코드에 반영했다.

- 적용 완료:
  - `app_realtime.js`
    - realtime 연결을 `page + vision + hidden` 상태기로 통합
    - `주행 비전 시작` 전 eager raw websocket / live_runtime poll 제거
    - hidden / page inactive / vision off 시 raw HUD, raw overlay, live runtime poll, RTC를 함께 정지
    - HUD perpetual RAF 제거, dirty 기반 one-shot RAF로 전환
    - `RTCPeerConnection.getStats()` + `HTMLVideoElement.getVideoPlaybackQuality()` 기반 WebRTC/video 계측 추가
    - raw CAPNP decode를 Worker 우선, main-thread fallback 구조로 전환
  - `home_drive.js`
    - overlay perpetual RAF 제거, event-driven one-shot render + 20fps cap 구조로 전환
    - overlay dirty / HUD dirty signature 분리
    - `roadCameraState.frameId`를 overlay redraw trigger에서 제거
    - canvas DPR cap 추가
      - phone portrait `1.0`
      - mobile/tablet `1.25`
      - desktop `1.5`
    - plot ring buffer를 직접 그리도록 바꿔 compatibility 배열 복사 제거
    - overlay scheduling에 `requestVideoFrameCallback` 기반 정렬 경로 추가
    - `mergeRuntimeState()` 결과 캐시로 불필요한 shallow merge churn 완화
  - `raw_ws.py`
    - `roadCameraState`, `deviceState`, `peripheralState`, `gpsLocationExternal`, `selfdriveState` 전송 주기 추가 완화

- 아직 남은 2차 항목:
  - raw 서비스 목록 자체 축소
  - websocket multiplex 구조 검토
  - WebRTC codec / resolution / fps 정책 튜닝
  - OffscreenCanvas full worker render 실험

## 결론 요약

현재 코드는 1차 발열 대응이 이미 들어간 상태다.  
따라서 다음 단계의 초점은 "기본 루프 정리"가 아니라, **WebRTC decode + main-thread CAPNP decode + canvas draw + websocket fan-out**의 누적 비용을 더 줄이는 쪽이다.

핵심 판단은 아래와 같다.

- 1차 반영 후에도 **추가 최적화 여지는 충분히 있다**
- 다만 다음 phase는 **HUD/debug 의미를 유지하는 방향**으로 가야 한다
- 즉 "업데이트 빈도 희생"보다
  - decode를 Worker로 분리
  - video frame 기준 render 정렬
  - websocket fan-out 감소
  - object churn 감소
  쪽이 우선이다

이 문서 기준의 최종 방향은 다음과 같다.

- 권장:
  - 계측 추가
  - Worker decode
  - `requestVideoFrameCallback` 검토
  - raw websocket multiplex 검토
  - object churn 정리
- 비권장:
  - debug/HUD 서비스 추가 축소를 기본값으로 넣는 것
  - ThorVG 또는 WebGPU로 바로 갈아타는 것
  - 저전력 모드랍시고 HUD 의미나 갱신 의미를 바꾸는 것

## 현재 end-to-end 구조

현재 주행 페이지의 실제 경로는 아래와 같다.

```text
브라우저
  ├─ WebRTC: /stream -> webrtcd(5001) -> rtcVideo
  ├─ 화면 video: carrotRoadVideo <= rtcVideo.srcObject 복사
  ├─ raw HUD websocket x 8
  ├─ raw overlay websocket x 9
  ├─ /api/live_runtime poll
  ├─ overlay canvas (lane/path/radar/lead)
  ├─ HUD canvas (plot/debug/text)
  └─ DOM HUD card

서버
  ├─ /stream proxy -> WEBRTCD_URL(127.0.0.1:5001)
  ├─ /api/live_runtime -> RealtimeBroker snapshot
  ├─ /ws/raw/{service} -> RawWsHub
  └─ /ws/camera/{camera} -> CameraWsHub
```

중요한 점:

- 현재 주행 페이지의 실제 video 경로는 `camera_ws.py`가 아니라 **WebRTC `/stream`** 이다
- 따라서 현재 발열 관점의 본체는:
  - `home_drive.js`
  - `app_realtime.js`
  - `raw_capnp.js`
  - `raw_ws.py`
- `camera_ws.py`는 존재하지만, 현재 페이지의 주 경로는 아니다

## 2026-04 공식 검토 결과

Gemini 공유 대화와 2026년 기준 브라우저/WebRTC API를 대조해 보면, 방향성은 일부 맞고 일부는 과하다.

### 맞는 판단

- 현재 workload는 **SVG/Lottie형 정적 벡터 엔진**보다 **실시간 Canvas/WebRTC telemetry renderer**에 가깝다
- `Canvas 2D + Worker/OffscreenCanvas` 계열 검토는 타당하다
- DPR 관리, render scheduling 정렬, partial invalidation은 유효한 축이다

### 과한 판단

- ThorVG를 1순위로 도입하는 것은 현재 병목과 직접 맞지 않는다
- WebGPU는 2026년에도 브라우저 지원/복잡도 대비 1차 대응책으로 과하다
- `dirty rect`는 현재 full-screen transparent overlay 구조에서는 ROI가 제한적일 수 있다
- `Path2D`는 일부 정적 도형에는 유효하지만, 매 프레임 geometry가 크게 바뀌는 path 전체에 만능은 아니다

## 현재 상태에서 남아 있는 실제 비용

### 1. WebRTC decode 비용

현재 페이지는 브라우저가 `RTCPeerConnection`으로 road video를 직접 수신한다.  
이 비용은 JS flame chart에서 크게 안 보여도, 실제 모바일 발열에는 크게 기여할 수 있다.

의미:

- "명확한 병목 함수가 안 보이는데 뜨거움"이 가능한 구조다
- 따라서 다음 phase는 JS 최적화만이 아니라 **실제 codec / dropped frame / decode 상태**를 함께 봐야 한다

### 2. raw CAPNP decode가 전부 메인 스레드

현재 raw 메시지는 `Blob/ArrayBuffer -> decodeHudEvent/decodeOverlayEvent`로 메인 스레드에서 바로 decode된다.

의미:

- draw와 decode가 같은 스레드에서 경쟁한다
- HUD/debug 의미를 그대로 유지하면서도 줄일 수 있는 가장 좋은 다음 후보다

### 3. websocket fan-out 비용

서비스별 websocket 구조는 구현은 단순하지만, 브라우저 입장에서는:

- socket 수
- event callback 수
- queue/dispatch 수

가 함께 늘어난다.

즉 서비스 갱신 주기를 줄이지 않아도, **fan-out 구조 자체를 줄이면 전력 효율 개선 여지**가 있다.

### 4. 상태 merge / allocation churn

`mergeRuntimeState()`는 여전히 frame 단위 object churn을 만든다.

이건 최상위 병목은 아니지만:

- 장시간 주행 시 GC pressure
- 누적적 main-thread noise

로 이어질 수 있다.

### 5. video element 이중 경로

현재는 hidden `rtcVideo`와 visible `carrotRoadVideo`를 같이 쓴다.

장점:

- 공용 stream source 분리와 UI 구성은 단순하다

단점:

- 브라우저별 media pipeline 비용이 불필요하게 커질 가능성이 있다

이 항목은 반드시 수정해야 할 P0는 아니지만, 다음 phase에서 계측 후 판단할 가치가 있다.

## 다음 phase 후보와 손익 비교

아래 항목은 "유저 경험을 해치지 않는 방향"을 우선으로 정리한다.

### Phase 2-1. WebRTC / video 계측 추가

내용:

- `RTCPeerConnection.getStats()` 추가
- `HTMLVideoElement.getVideoPlaybackQuality()` 추가
- codec, fps, dropped frame, presented frame, jitter를 dev/debug 모드에서 기록

장점:

- 실제 발열 원인이 decode인지 draw인지 구분 가능
- codec 변경이나 해상도 조정 전 판단 정확도가 올라감
- UX 변화가 사실상 없다

단점:

- 개발용 계측 코드가 늘어난다
- 로그를 과하게 남기면 자체 오버헤드가 생길 수 있다

이득:

- 이후 모든 최적화 판단 정확도 상승
- 잘못된 튜닝으로 UX를 해칠 가능성 감소

손해:

- 개발 복잡도 소폭 증가

판단:

- **무조건 권장**

### Phase 2-2. raw CAPNP decode를 Worker로 이동

내용:

- `ArrayBuffer`를 Worker로 transfer
- CAPNP decode만 Worker에서 수행
- draw는 우선 main thread에 유지

장점:

- HUD/debug 의미를 줄이지 않고 main-thread 부하를 낮출 수 있다
- 장시간 사용 시 발열 완화 가능성이 크다
- 현재 구조에서 ROI가 높다

단점:

- Worker/메시지 경계 관리가 필요하다
- 디버깅이 조금 어려워진다
- structured clone 또는 transfer 설계 실수가 있으면 역효과가 날 수 있다

이득:

- 유저 경험 손상 없이 성능/발열 개선 가능

손해:

- 코드 복잡도 증가

판단:

- **다음 phase 최우선 후보**

### Phase 2-3. overlay render를 `requestVideoFrameCallback` 기준으로 정렬

내용:

- overlay render scheduling을 video frame present 기준으로 맞춘다
- 현재 20fps cap은 유지할 수 있다

장점:

- video 없는 idle wakeup을 더 줄일 수 있다
- 영상과 overlay 타이밍 정렬이 더 자연스러워질 수 있다
- 품질 저하 없이 효율 개선 가능성이 있다

단점:

- 브라우저별 fallback 처리가 필요하다
- 현재 event-driven scheduling과 충돌하지 않게 설계해야 한다

이득:

- overlay scheduling 효율 개선
- 렌더 타이밍 정합성 향상 가능

손해:

- 구현 난이도 중간

판단:

- **Worker decode 다음 우선순위**

### Phase 2-4. raw websocket multiplex 구조 검토

내용:

- 서비스별 websocket 여러 개 대신
- 1개 또는 소수의 multiplex websocket으로 합치는 방안 검토

장점:

- websocket fan-out 오버헤드 감소
- callback/dispatch 수 감소
- 서비스 의미와 갱신 의미를 유지한 채 전력 효율 개선 가능

단점:

- 서버/클라이언트 프로토콜을 함께 손봐야 한다
- 디버깅 단순성이 줄 수 있다

이득:

- 서비스 빈도 희생 없이 구조 효율 개선

손해:

- 구현 범위가 커진다

판단:

- **유의미하지만 Worker decode 뒤**

### Phase 2-5. `mergeRuntimeState()` churn 축소

내용:

- merged state 재사용
- 필요한 필드만 얕게 갱신
- 문자열/배열 formatting을 dirty 기반으로 최소화

장점:

- GC pressure 완화
- 누적적 소모 감소

단점:

- 잘못 건드리면 상태 동기화 버그가 생길 수 있다
- 이득이 다른 항목보다 작을 수 있다

이득:

- 장시간 안정성 개선

손해:

- 코드 가독성이 다소 떨어질 수 있다

판단:

- **중간 우선순위**

### Phase 2-6. WebRTC codec / resolution / fps 정책 튜닝

내용:

- 실제 수신 codec 확인 후 codec preference 실험
- 필요 시 resolution / fps 정책 조정 검토

장점:

- decode 비용을 크게 줄일 잠재력이 있다
- 네트워크와 발열을 함께 줄일 가능성이 있다

단점:

- 화질과 지연에 직접 영향이 갈 수 있다
- 브라우저/기기별 결과 편차가 크다
- 측정 없이 하면 오히려 UX를 망칠 수 있다

이득:

- 맞으면 큰 효과

손해:

- 틀리면 바로 체감 품질 저하

판단:

- **계측 후에만 진행**

### Phase 2-7. OffscreenCanvas 전체 render worker화

내용:

- decode뿐 아니라 overlay render 자체를 OffscreenCanvas + Worker로 이동

장점:

- main-thread 부하를 더 크게 줄일 수 있다
- 장기적으로 가장 공격적인 구조 개선이다

단점:

- 호환성/fallback 설계가 필요하다
- 디버깅이 어려워진다
- 현재 draw 코드 이식 비용이 크다

이득:

- 맞으면 가장 큰 구조 개선

손해:

- 구현 복잡도와 리스크가 높다

판단:

- **2차 후반 또는 실험 트랙**

### Phase 2-8. ThorVG / WebGPU 도입

내용:

- 렌더러를 크게 바꾸는 접근

장점:

- 장기적으로 특정 유형의 workload에는 유리할 수 있다

단점:

- 현재 병목의 본체를 직접 해결하지 않는다
- 구현량과 검증량이 과하다
- WebGPU는 2026년 기준도 브라우저 지원/운영 부담이 있다

이득:

- 장기 실험 가치 정도

손해:

- 현재 문제 대비 ROI가 낮다

판단:

- **현 시점 비권장**

## 유저 경험 기준 가드레일

다음 phase에서는 아래 원칙을 유지한다.

- core HUD 의미는 바꾸지 않는다
- debug/HUD 필드를 기본값에서 더 줄이지 않는다
- 저전력 모드를 넣더라도 기본 모드와 의미 차이를 만들지 않는다
- 품질/지연 tradeoff가 있는 변경은 계측 후에만 적용한다

특히 다음 항목은 **직접 확인 전 기본값으로 넣지 않는다**.

- debug/HUD 서비스 추가 축소
- 해상도/FPS 강제 하향
- codec 강제 변경

## 2026-04 기준 권장 실행 순서

1. WebRTC / video 계측 추가
2. raw CAPNP decode Worker 이동
3. `requestVideoFrameCallback` 기반 overlay scheduling 검토
4. `mergeRuntimeState()` churn 축소
5. websocket multiplex 구조 검토
6. 필요 시 codec / resolution / fps 정책 실험
7. OffscreenCanvas full worker render 실험

## 수용 기준

- lane/path/lead box 정합이 기존과 동일하다
- 속도, 설정속도, gap, drive mode, 제한속도, debug 의미가 기존과 동일하다
- 장시간 주행 시 main-thread busy time 또는 dropped frame 지표가 개선된다
- 정차/주행/백그라운드 복귀에서 회귀가 없다
- 사용자가 체감하는 지연 증가가 없다
- "발열은 줄었지만 HUD 의미가 변했다" 같은 회귀가 없다

## 메모

- 이 문서는 구현 전후를 함께 관리하는 기준 문서다
- 2026-04-03 기준 1차 브라우저 발열 대응은 이미 반영되어 있다
- 현재까지 반영한 다음 phase는 `계측`, `Worker decode`, `video-frame aligned scheduling`, `merge churn 완화`다
- 다음 phase는 "데이터 축소"보다 "구조 효율화"가 중심이다
- 핵심 원칙은 **유저 경험을 해치지 않고 발열을 낮추는 것**이다
