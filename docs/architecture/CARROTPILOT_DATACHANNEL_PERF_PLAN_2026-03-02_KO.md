# CarrotPilot 데이터채널(정합성 우선) 성능 최소화 계획서 (2026-03-02)

최종 분석일: 2026-03-02  
분석 기준:
- 앱: `d:/CarrotLink/CarrotLink-dev`
- 기기측: `d:/CarrotLink/c3-v10-wip`

## 1. 목적

요구사항을 동시에 만족하는 설계를 확정한다.

1. HUD 탭 신규 주행화면에서 영상+그래픽 정합성을 높일 것  
2. 기기 성능 마진(CPU/발열/RAM) 소모를 최소화할 것  
3. `carrot/openpilot` 기본 코드/파일은 수정하지 않을 것  
4. 별도 프로세스(분리 실행 단위) 구조로 운영할 것

## 2. 현재 코드 기준 사실관계

### 2.1 현재 앱 경로

- 홈 HUD 탭 -> `WebRtcDriveScreen` 진입  
  `lib/screens/tabs/home_tab.dart`
- 주행화면은 `http://<ip>:7000` 웹뷰 로드  
  `lib/widgets/webrtc_drive_screen.dart`

### 2.2 현재 7000 서버 경로

- `/stream`은 `webrtcd(5001)`로 프록시  
  `selfdrive/carrot/carrot_server.py`
- 현재 웹앱 offer body는 `bridge_services_out: []`  
  `selfdrive/carrot/web/app.js`
- 즉, 현재는 영상(WebRTC) + 별도 WS(`/ws/carstate`) 구조

### 2.3 webrtcd 데이터채널 브리지 가능 상태

`webrtcd`는 이미 브리지 기능을 내장한다.

- `StreamRequestBody`에 `bridge_services_in/out` 존재  
  `system/webrtc/webrtcd.py`
- `bridge_services_out` 지정 시 `SubMaster` -> DataChannel JSON 송신  
  `system/webrtc/webrtcd.py`
- 메시징 데이터채널 라벨은 `data`를 기대  
  `teleoprtc_repo/teleoprtc/stream.py`

결론: 기본 코드 무수정으로도, 앱이 `data` 채널 + `bridge_services_out`를 사용하면 같은 PeerConnection에서 텔레메트리 수신이 가능하다.

## 3. 성능 영향 분석 (핵심)

성능 비용은 "수집"보다 "직렬화/전송/렌더"에서 크게 증가한다.

### 3.1 부담이 큰 구간

1. 고빈도 서비스(예: `modelV2`)의 대형 JSON 직렬화  
2. UI isolate에서 원시 payload를 직접 파싱/렌더  
3. 필요 없는 서비스까지 항상 구독/전송

### 3.2 부담이 작은 구간

1. 저빈도/소형 상태값(`carState`, `selfdriveState` 일부)  
2. 화면 비활성 시 스트림 중단  
3. 파싱/투영/렌더를 분리 프로세스로 분산

## 4. 권장 아키텍처 (무수정 + 분리 프로세스)

## 4.1 분리 단위 정의

별도 프로세스는 앱 내부에서 분리 실행한다.

- `UI 프로세스(메인 isolate)`: 화면 렌더만 담당
- `DriveRealtimeWorker(별도 isolate/service)`:  
  WebRTC 연결, datachannel 수신, 파싱/다운샘플, 좌표 전처리 담당

장점:
- 기본 `carrot/openpilot` 파일 무수정
- 정합성(동일 PeerConnection) 유지
- UI 프레임 드랍 격리

## 4.2 전송 경로

1. 앱 Worker가 `POST /stream` 호출  
2. `cameras=["road"]` + `bridge_services_out=[...]` 지정  
3. RTCPeerConnection에 `data` 채널 생성  
4. 영상 track + datachannel을 동일 세션에서 수신  
5. Worker가 UI에 정제된 스냅샷만 전달

## 5. 성능 마진 최소화 전략

## 5.1 서비스 레벨 프로파일

프로파일을 고정하지 않고 단계적으로 사용한다.

- `P0 (기본)`  
  `carState`, `selfdriveState`, `deviceState`
- `P1 (주행 오버레이 기본)`  
  `P0 + liveCalibration`
- `P2 (차선/레인리스 오버레이)`  
  `P1 + modelV2`
- `P3 (디버그 확장, 필요시만)`  
  `P2 + radarState` (또는 별도 토글)

원칙:
- 기본 진입은 `P0/P1`  
- 레인 그래픽 기능을 켠 경우에만 `P2` 활성화  
- 화면 이탈 즉시 스트림/파서 정지

## 5.2 다운샘플/백프레셔

Worker에서 강제 규칙을 둔다.

1. UI 반영 주기 상한: 10Hz (기본), 6Hz(부하 시)  
2. 큐 길이 > 2이면 오래된 메시지 즉시 드롭  
3. `modelV2`는 필요한 포인트만 추출 후 전달  
4. 부하 감지 시 자동 강등: `P2 -> P1 -> P0`

## 5.3 저전력/백그라운드 규칙

앱이 전면이 아닐 때:

1. 영상 + datachannel 세션 종료  
2. 기존 탐색/연결 유지 주기만 사용(20~30초)

즉, 백그라운드 상태에서 onroad 렌더 데이터 파이프는 유지하지 않는다.

## 6. 예상 부하 범위 (보수적 추정)

아래 수치는 코드 구조 기반 추정치이며, 실제 측정으로 보정한다.

- `P0`: CPU +1~3%, RAM +10~25MB  
- `P1`: CPU +2~4%, RAM +15~35MB  
- `P2`: CPU +4~8%, RAM +25~70MB (기기/주행상황 의존 큼)  

핵심: `modelV2`를 항상 켜두지 않으면 열/성능 리스크를 크게 줄일 수 있다.

## 7. 구현 단계 계획

## 7.1 Phase A (기반)

1. HUD 탭 기존 WebView 진입 코드 제거 대상 확정  
2. 신규 가로 주행 화면 shell 배치(좌 메뉴/우 영상 캔버스)  
3. `DriveRealtimeWorker` 골격 추가

## 7.2 Phase B (정합성 파이프)

1. Worker에서 단일 PeerConnection 수립  
2. `data` 채널 + `bridge_services_out` 수신 연결  
3. `P0/P1` 데이터만 먼저 반영

## 7.3 Phase C (오버레이 확장)

1. `P2(modelV2)` 선택 토글 도입  
2. 좌표 전처리/투영/렌더 파이프 추가  
3. 부하 강등(자동 QoS) 적용

## 7.4 Phase D (검증)

1. CPU/메모리/온도/프레임드랍 측정  
2. 주행 중 네트워크 변동/재연결/복구 테스트  
3. 실패 시 `P1` 자동 폴백 검증

## 8. 수용 기준 (Acceptance)

1. 기본 코드 무수정: `c3-v10-wip/selfdrive`와 `system` 원본 파일 직접 수정 없음  
2. 앱 전면에서만 고부하 채널 동작  
3. 평균 UI 프레임 저하가 체감되지 않을 것  
4. 연결 실패 시 영상 단독 모드로 자동 전환될 것  
5. 진단 로그로 `프로파일(P0~P3)`과 강등 이력을 추적 가능할 것

## 9. 결정 사항(요약)

1. 정합성 우선 경로는 "같은 PeerConnection의 datachannel"을 사용한다.  
2. 성능 마진은 프로파일 + 다운샘플 + 자동강등으로 관리한다.  
3. 별도 프로세스는 앱 내부 Worker(isolate/service)로 분리한다.  
4. 기기측 `carrot/openpilot` 기본 파일은 수정하지 않는다.
