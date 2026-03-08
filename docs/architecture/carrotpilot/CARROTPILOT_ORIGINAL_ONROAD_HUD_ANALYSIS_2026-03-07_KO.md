# CarrotPilot 원본 Onroad HUD 분석 (2026-03-07)

## 문서 목적
- comma 기기 화면의 왼쪽 하단 HUD가 원본 코드에서 어떻게 만들어지는지 정리
- 우리 앱 HUD가 왜 원본과 다르게 보이거나 값이 어긋나는지 원인 정리
- 이후 CarrotLink HUD를 원본 기준으로 다시 구현하거나 보강할 때 기준 문서로 사용

## 분석 대상
- 원본 HUD: `d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc`
- 원본 HUD 입력값: `carState`, `carControl`, `longitudinalPlan`, `carrotMan`, `deviceState`, `peripheralState`, `Params`
- 우리 앱 HUD: `d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart`
- 우리 앱 HUD 입력 경로:
  - `ws://<ip>:7000/ws/carstate`
  - SSH fallback metrics

## 한 줄 결론
- 사진의 왼쪽 하단 HUD는 sidecar Python이 그리는 것이 아니다.
- 원본 openpilot/carrot UI가 `carrot.cc` 안에서 NanoVG로 직접 그린다.
- 현재 우리 앱 HUD는 모양은 비슷하지만, 입력 데이터 의미가 원본과 완전히 같지 않아서 정확도가 떨어진다.

---

## 1. 원본 HUD는 어디서 그려지나

원본 HUD의 핵심 함수는 아래다.
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2301)

여기서 `DrawCarrot::drawHud(UIState *s)`가 실제 왼쪽 하단 카드 HUD를 그린다.

이 HUD는:
- Qt 위젯이 아니다
- 별도 프로세스가 아니다
- HTML/CSS도 아니다
- onroad 프레임을 그릴 때 같은 캔버스 위에 직접 그리는 오버레이다

전체 draw 순서는 아래에서 볼 수 있다.
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2827)

대략 순서는:
1. 상태 갱신
2. path / lane / desire
3. debug plot
4. radar info
5. HUD
6. date/time
7. device info
8. TPMS

즉 왼쪽 하단 HUD는 path/lane보다 위에, 날짜/디버그 텍스트와는 같은 onroad overlay 계층에서 그려진다.

---

## 2. 원본 HUD는 어떤 구조로 동작하나

원본 HUD는 크게 3단계다.

### 2-1. 입력값 수집
아래 함수에서 현재 onroad 상태를 읽는다.
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L1984)

여기서 읽는 주요 소스:
- `carState`
- `carControl`
- `longitudinalPlan`
- `carrotMan`
- `modelV2`
- `radarState`
- `selfdriveState`
- `Params`

여기서 HUD용으로 잡는 핵심 변수:
- `v_cruise`
- `v_ego`
- `active_carrot`
- `apply_speed`
- `apply_source`
- `nRoadLimitSpeed`
- `xSpdLimit`
- `xSignType`
- `cruiseTarget`
- `myDrivingMode`
- `trafficState`
- `trafficState_carrot`

### 2-2. 내부 상태 유지
원본 HUD는 값만 그리지 않고, 이전 값도 기억한다.
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2289)

대표 예시:
- `cruise_speed_last`
- `driving_mode_str_last`
- `gap_last`
- `gear_str_last`
- `blink_timer`
- `disp_timer`

이걸로 하는 일:
- 숫자가 바뀌면 순간 확대/이동 애니메이션
- CAM/LIMIT 깜빡임
- DISK/VOLT 번갈아 보여주기

### 2-3. 화면에 그리기
실제 카드형 HUD를 그리는 곳:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2301)

중요한 점:
- 반응형 레이아웃이 아니다
- 절대좌표 기반이다
- comma 화면 크기에 맞춰 튜닝된 레이아웃이다

대표 기준 좌표:
- `x = 140`
- `y = fb_h - 500`

즉 우리 앱에서 그대로 복제하면 기기별 비율이 틀어질 수 있다.

---

## 3. 왼쪽 하단 HUD에 실제로 어떤 항목이 있나

사진 기준으로 보이는 주요 HUD 항목은 아래다.

### 3-1. 상단 mini metric 3개
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2503)

항목:
- CPU
- MEM
- DISK 또는 VOLT

세부 원리:
- CPU: `deviceState.cpuTempC`
- MEM: `deviceState.memoryUsagePercent`
- DISK: `deviceState.freeSpacePercent`
- VOLT: `peripheralState.voltage`

중요:
- 원본은 DISK와 VOLT를 동시에 보여주지 않고, 타이머로 번갈아 보여준다.
- `ShowDeviceState`가 꺼지면 이 줄 전체가 사라진다.

### 3-2. 메인 속도
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2345)

원리:
- `v_ego = carState.getVEgoCluster()`
- 가장 큰 흰색 숫자
- 뒤에 속도 배경 이미지가 있음

### 3-3. 설정 속도
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2351)

원리:
- `v_cruise = carState.getVCruiseCluster()`
- 초록색 숫자
- 값이 바뀌면 애니메이션이 한번 들어감

### 3-4. 임시 속도 / 이유 텍스트
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2364)

원리:
- 우선순위 1: `carrotMan.desiredSource` + `carrotMan.desiredSpeed`
- 우선순위 2: source가 없고 `cruiseTarget != v_cruise` 이면 `eco + cruiseTarget`

즉 여기 영역은 단순히 `temp speed` 하나가 아니다.
원본은 조건에 따라:
- `source + apply speed`
- 또는 `eco + cruiseTarget`
으로 바뀐다.

### 3-5. 주행 모드 배지
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2384)

원리:
- `myDrivingMode = longitudinalPlan.myDrivingMode`

원본 모드 문자열:
- 1 -> `ECO`
- 2 -> `SAFE`
- 3 -> `NORM`
- 4 -> `FAST`

색도 모드별로 다르다.

### 3-6. GPS 표시
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2403)

원리:
- 실제 GPS fix가 있을 때만 `GPS` 텍스트를 보여준다
- 항상 켜진 고정 라벨이 아니다

### 3-7. gap 숫자 + 오른쪽 초록 막대
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2408)

원리:
- `Params("LongitudinalPersonality") + 1`
- 즉 실시간 센서값이 아니라 사용자가 현재 선택한 personality 설정값이다

오른쪽 세로 막대는 이 값을 시각적으로 다시 보여주는 표현이다.

### 3-8. 기어 박스
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2429)

원리:
- `carState.getGearShifter()`
- `carState.getGearStep()`

표시값:
- `P`, `D`, `N`, `R`, `S`, `L`, `B`, `E`
- 또는 실제 단수 숫자

### 3-9. APN / APM 배지
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2458)

원리:
- `active_carrot = carrotMan.getActiveCarrot()`
- `>= 2` 이면 `APN`
- `>= 1` 이면 `APM`

### 3-10. LIMIT / CAM 박스
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2481)

원리:
- `xSpdLimit`, `xSignType`, `nRoadLimitSpeed`를 사용
- 카메라 속도 제한이 잡히면 `CAM`
- 아니면 일반 도로 제한속도 `LIMIT`

중요:
- CAM은 깜빡임이 들어간다
- 일반 제한속도는 과속 여부에 따라 색이 달라진다

### 3-11. 신호등 아이콘
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2328)

원리:
- `trafficState`
- `trafficState_carrot`

즉 원본 HUD는 신호등 상태도 왼쪽 하단 카드 안에서 그린다.

---

## 4. 왼쪽 하단 HUD 밖에 있지만 같이 보이는 요소

혼동하면 안 되는 항목들:

### 4-1. 상단 디버그 plot
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2854)

이건 별도 `DrawPlot` 모듈이다.
왼쪽 하단 HUD 카드의 일부가 아니다.

### 4-2. 좌상단 시계/날짜
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2534)

이것도 HUD 카드가 아니라 별도 draw 함수다.

### 4-3. 우상단 MEM/DISK/CPU 텍스트
코드:
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2696)

이것도 카드 HUD와 별개다.

---

## 5. 원본 HUD는 터치로 값도 바꾼다

원본 HUD는 보기만 하는 오버레이가 아니다.

터치 처리:
- [onroad_home.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/qt/onroad/onroad_home.cc#L206)

되는 일:
- 날짜/시간 영역 터치 -> `ShowDateTime` 순환
- device info 영역 터치 -> `ShowDeviceState` 토글
- 주행 모드 영역 터치 -> `MyDrivingMode` 순환
- gap 영역 터치 -> `LongitudinalPersonality` 순환

즉 원본 HUD는 onroad 조작 패널 역할도 한다.

---

## 6. 원본 HUD와 관련된 Param

원본에서 자주 연결되는 param:
- [params_keys.h](/d:/CarrotLink/c3-v10-wip/common/params_keys.h#L147)

대표 항목:
- `ShowDebugUI`
- `ShowTpms`
- `ShowDateTime`
- `ShowLaneInfo`
- `ShowRadarInfo`
- `ShowDeviceState`
- `ShowRouteInfo`
- `ShowPathMode`
- `ShowPathColor`
- `ShowPathColorCruiseOff`
- `ShowPathModeLane`
- `ShowPathColorLane`
- `ShowPlotMode`
- `LongitudinalPersonality`
- `LongitudinalPersonalityMax`

---

## 7. 우리 앱 HUD는 지금 어떤 구조인가

현재 우리 앱 HUD 위젯 핵심:
- [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart#L741)

입력 경로:
- ws 수신: [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart#L623)
- snapshot 파싱: [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart#L822)
- SSH fallback: [ssh_service.dart](/d:/CarrotLink/CarrotLink-dev/lib/services/ssh_service.dart#L925)

즉 지금 우리 앱 HUD는:
- 주 데이터: `ws://<ip>:7000/ws/carstate`
- 보조 데이터: SSH로 CPU/MEM/DISK 계산

두 소스를 섞어 쓰는 구조다.

---

## 8. 우리 앱 HUD가 부정확한 이유

이 부분이 가장 중요하다.

### 8-1. CPU 온도 의미가 이미 다르다
원본:
- `deviceState.cpuTempC` 평균값 사용
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2669)

현재 `carrot_server.py`:
- CPU temperature 배열의 max 값을 사용
- [carrot_server.py](/d:/CarrotLink/c3-v10-wip/selfdrive/carrot/carrot_server.py#L949)

결과:
- 같은 기기라도 우리 앱 CPU 숫자가 원본보다 높게 보일 수 있다

### 8-2. temp 영역 의미가 원본과 완전히 같지 않다
원본:
- `desiredSource + desiredSpeed`
- source 없으면 `eco + cruiseTarget`
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2364)

현재 서버 payload:
- `temp = {speed, source, is_decel}` 형태로 평탄화
- [carrot_server.py](/d:/CarrotLink/c3-v10-wip/selfdrive/carrot/carrot_server.py#L933)

현재 Flutter:
- source 비어 있으면 기본 `eco`
- [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart#L825)

결과:
- 화면은 비슷해도 원본과 같은 표시 우선순위가 아니다

### 8-3. GPS가 사실상 정확하지 않다
현재 서버:
- `gps_ok = True`
- [carrot_server.py](/d:/CarrotLink/c3-v10-wip/selfdrive/carrot/carrot_server.py#L947)

결과:
- 우리 앱 GPS 표시는 원본처럼 실제 fix 기반이 아니다

### 8-4. LIMIT / CAM / APN / APM / red dot / tlight가 아직 원본 의미가 아니다
현재 payload:
- `tlight`, `redDot`, `speedLimitKph`, `speedLimitOver`, `apm` 쪽에 placeholder 성격이 남아 있다
- [carrot_server.py](/d:/CarrotLink/c3-v10-wip/selfdrive/carrot/carrot_server.py#L968)

결과:
- 원본 HUD의 하단 영역 의미를 완전히 복제할 수 없다

### 8-5. drive mode 명칭도 원본과 다르다
원본:
- `ECO / SAFE / NORM / FAST`
- [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2389)

현재 서버:
- `Eco / Safe / Normal / Sport`
- [carrot_server.py](/d:/CarrotLink/c3-v10-wip/selfdrive/carrot/carrot_server.py#L936)

결과:
- 비슷해 보이지만 원본 그대로는 아니다

### 8-6. DISK / VOLT 모델이 단순화됐다
원본:
- DISK와 VOLT 각각 가진 뒤 내부 타이머로 번갈아 그림

현재:
- `diskPct` + `diskLabel` 조합으로 하나의 슬롯처럼 전달
- [carrot_server.py](/d:/CarrotLink/c3-v10-wip/selfdrive/carrot/carrot_server.py#L975)

결과:
- 구현은 쉬워졌지만 원본 상태 모델과는 다르다

### 8-7. SSH fallback이 의미값까지 오염시키면 안 된다
현재 fallback:
- CPU / MEM / DISK 값만 SSH로 가져옴
- [ssh_service.dart](/d:/CarrotLink/CarrotLink-dev/lib/services/ssh_service.dart#L925)

이건 괜찮은 편이다.
하지만 앞으로 GPS, drive mode, temp source 같은 의미 필드까지 fallback이 섞이면 더 틀어진다.

---

## 9. 현재 문서에 HUD 필드와 원리를 어디까지 적었나

지금 이 문서에는 아래를 적었다.

### 적은 것
- 원본 HUD가 어디서 그려지는지
- 전체 draw 구조
- 상태 수집 구조
- 내부 animation/state 원리
- 왼쪽 하단 HUD에 들어가는 주요 항목 전부
  - CPU
  - MEM
  - DISK/VOLT
  - 메인 속도
  - 설정 속도
  - temp source/temp speed
  - 주행 모드
  - GPS
  - gap 숫자
  - gap 막대
  - gear
  - APN/APM
  - LIMIT/CAM
  - 신호등
- 원본 HUD 터치 조작 규칙
- 관련 param 목록
- 현재 우리 앱 HUD 데이터 경로
- 우리 앱 HUD가 부정확한 주요 원인

### 아직 완전히 안 한 것
- 원본 C++ 필드와 우리 Flutter 필드의 1:1 매핑표
- 각 항목별 “현재 값 생산 경로 -> 수정해야 할 값 생산 경로” 체크리스트
- `carrot_server.py`를 원본 HUD 전용 snapshot으로 재설계하는 제안서

즉,
`어떤 항목이 있고 원리가 뭔지`는 지금 문서에 들어갔다.
하지만 `필드별 수정 실행표`는 아직 별도 작업이 필요하다.

---

## 10. 내 의견

지금 단계에서 해야 할 일은 UI 리터치가 아니라 데이터 모델 정리다.

정확한 순서는 이게 맞다.

1. 원본 HUD 전용 snapshot 정의
- 원본 의미 그대로의 필드 집합을 먼저 정리

2. `carrot_server.py` 또는 별도 HUD endpoint를 원본 의미 기준으로 정리
- Flutter가 해석하지 말고 source가 의미를 정해야 함

3. Flutter는 draw 전용으로 단순화
- 원본과 같은 우선순위/명칭/색 규칙을 사용

4. SSH fallback은 metric only
- CPU / MEM / DISK만 fallback
- 의미 필드는 fallback 금지

---

## 11. 다음 추천 작업

다음 문서 또는 작업으로 바로 이어져야 하는 건 아래다.

### 추천 1
`원본 C++ HUD 필드 -> carrot_server payload -> Flutter HUD 필드 -> 현재 차이 -> 수정 방향`
이 표를 만든다.

### 추천 2
현재 `ws/carstate`에서 placeholder인 항목을 먼저 정리한다.
- GPS
- APN/APM
- LIMIT/CAM
- traffic light / red dot

### 추천 3
CPU, DISK/VOLT, temp 영역부터 원본 semantics와 맞춘다.

이 3개만 맞춰도 우리 앱 HUD 정확도는 체감상 많이 올라간다.

---

## 12. 필드별 값 수집표

이 섹션이 실제로 가장 중요하다.
adaptive HUD를 새로 만들 때는 “디자인”보다 아래 표의 `원본 값 생산 방식`을 먼저 따라가야 한다.

### 12-1. 속도 / 주행 관련 필드

| HUD 항목 | 원본 값 소스 | 원본 코드 | 현재 우리 앱 입력 | 현재 문제 | 권장 수집 방식 |
|---|---|---|---|---|---|
| 메인 속도 | `carState.getVEgoCluster()` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2009), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2347) | `ws_carstate.vEgo` -> Flutter에서 `*3.6` | 현재 서버는 `vEgoCluster`를 넣지만 키 이름은 `vEgo`라 의미가 모호함 | `vEgoClusterKph` 또는 `vEgoCluster`로 명시 분리 |
| 설정 속도 | `carState.getVCruiseCluster()` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2008), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2355) | `ws_carstate.vSetKph` | 이름은 맞지만 단위가 이름에 박혀 있어 다른 필드와 일관성 없음 | `vCruiseClusterKph` 명시 권장 |
| 임시 속도 숫자 | `carrotMan.getDesiredSpeed()` 또는 `longitudinalPlan.getCruiseTarget()` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2012), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2371) | `ws_carstate.temp.speed` | source에 따라 어떤 속도인지 의미가 섞임 | `applySpeedKph`, `cruiseTargetKph`를 분리해서 보낼 것 |
| 임시 속도 라벨 | `carrotMan.getDesiredSource()` 또는 `"eco"` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2013), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2375) | `ws_carstate.temp.source`, Flutter 기본값 `eco` | 현재는 source 비었을 때 Flutter가 임의 보정 | source에서 최종 라벨을 결정해서 내려보내기 |
| 감속 상태 색 | `apply_speed < v_cruise` 여부가 현재 서버에서 계산 | 원본 draw에서는 색보다 source 우선 | `ws_carstate.temp.is_decel` | 원본 semantics와 직접 1:1은 아님 | 필요하면 유지하되, 원본 parity 항목과 분리 |
| 주행 모드 값 | `longitudinalPlan.getMyDrivingMode()` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2073), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2386) | `ws_carstate.driveMode.{name,kind}` | 이름이 원본과 다름 (`NORM`/`FAST` 손실) | `driveModeCode`, `driveModeNameOriginal`, `driveModeKind` 분리 |
| gap 숫자/막대 | `Params("LongitudinalPersonality")+1` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2409) | `ws_carstate.tfGap`, `tfBars` | 현재는 맞는 편 | 유지 가능. 다만 `tfBars`는 서버에서 계산할 필요 없음 |
| 기어 | `carState.getGearShifter()`, `getGearStep()` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2433) | `ws_carstate.gear` | 현재는 비교적 정확 | 유지 가능 |

### 12-2. 상태 / 보조 표시 필드

| HUD 항목 | 원본 값 소스 | 원본 코드 | 현재 우리 앱 입력 | 현재 문제 | 권장 수집 방식 |
|---|---|---|---|---|---|
| GPS 표시 | `gpsLocationExternal` 또는 `gpsLocation`의 `hasFix` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2403) | `ws_carstate.gpsOk` | 현재 서버는 사실상 `True` 고정 | 실제 GPS fix를 읽어 내려보내기 |
| APN/APM | `carrotMan.getActiveCarrot()` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2011), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2463) | payload에 실필드 없음, `apm` placeholder만 존재 | 현재 우리 앱은 원본과 다르게 사실상 못 그림 | `activeCarrot` 정수값을 그대로 보내기 |
| LIMIT 일반값 | `carrotMan.getNRoadLimitSpeed()` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2016), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2493) | `speedLimitKph` placeholder | 원본 일반 제한속도 경로가 살아있지 않음 | `roadLimitSpeedKph` 별도 필드로 분리 |
| CAM 제한값 | `carrotMan.getXSpdLimit()` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2017), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2487) | `speedLimitKph` placeholder | 일반 제한속도와 카메라 제한속도가 구분 안 됨 | `cameraLimitSpeedKph` 별도 필드 |
| CAM/제한속도 종류 | `carrotMan.getXSpdType()` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2018), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2487) | 없음 | CAM/LIMIT 판정 불가 | `cameraSignType` 별도 필드 |
| 과속 색 판단 | `v_ego * 3.6 > disp_speed + 2` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2495) | `speedLimitOver` placeholder | 현재 서버가 원본 규칙을 반영 안 함 | 서버에서 원본 기준으로 계산 |
| 신호등 상태 | `trafficState`, `trafficState_carrot` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2071), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2021), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2331) | `tlight`, `redDot` placeholder | 현재 원본과 연결 안 됨 | `trafficStateLp`, `trafficStateCarrot`, `signalVisualState` 분리 |

### 12-3. 장치 상태 필드

| HUD 항목 | 원본 값 소스 | 원본 코드 | 현재 우리 앱 입력 | 현재 문제 | 권장 수집 방식 |
|---|---|---|---|---|---|
| CPU | `deviceState.cpuTempC` 평균 | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2674), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2510) | `ws_carstate.cpuTempC`, 없으면 SSH fallback | 현재 서버는 max, fallback은 shell 평균이라 의미가 섞임 | 서버에서 `cpuTempAvgC`로 통일, SSH는 fallback only |
| MEM | `deviceState.memoryUsagePercent` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2673), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2516) | `ws_carstate.memPct`, 없으면 SSH fallback | 비교적 괜찮음 | 유지 가능 |
| DISK | `deviceState.freeSpacePercent`를 사용해 `100-free` 표시 | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2672), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2523) | `ws_carstate.diskPct`, 없으면 SSH fallback | 이름은 diskPct지만 실제론 free 기반 역산 | `diskUsedPct`로 명시 권장 |
| VOLT | `peripheralState.voltage / 1000` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2693), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2529) | `diskPct + diskLabel=VOLT`로 multiplex | DISK/VOLT가 한 필드로 합쳐짐 | `voltV` 별도 필드로 분리 권장 |
| DISK/VOLT 교대 표시 | 내부 `disp_timer` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2304), [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2520) | `carrot_server.py`에서 약 3.2초마다 토글 | 현재는 근사 구현 | 새 adaptive HUD에서는 서버가 아닌 UI가 교대해도 됨 |

### 12-4. 표시 여부 / HUD 토글 관련 필드

| 항목 | 원본 값 소스 | 원본 코드 | 현재 우리 앱 상태 | 권장 방향 |
|---|---|---|---|---|
| 상단 mini metrics 표시 여부 | `Params("ShowDeviceState")` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2302) | 현재 우리 앱은 항상 비슷하게 그림 | 원본 parity가 필요하면 `showDeviceState`도 snapshot에 포함 |
| 날짜/시간 표시 방식 | `Params("ShowDateTime")` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L2537) | 현재 우리 HUD와 분리 | adaptive HUD에 꼭 필요 없으면 제외 가능 |
| debug plot 모드 | `Params("ShowPlotMode")` | [carrot.cc](/d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc#L464) | 우리 앱은 별도 구현 | HUD snapshot과 분리 유지 |

---

## 13. 현재 우리 앱 HUD가 실제로 쓰는 필드 목록

현재 Flutter `_HudSnapshot` 필드는 아래다.
- [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart#L741)

현재 필드:
- `cpuTempC`
- `memPct`
- `diskValue`
- `diskLabel`
- `vEgoKph`
- `vSetKph`
- `gear`
- `gpsOk`
- `tfBars`
- `driveModeName`
- `driveModeKind`
- `tlight`
- `redDot`
- `tempSource`
- `tempSpeedKph`
- `tempIsDecel`
- `speedLimitKph`
- `speedLimitOver`

즉 현재 우리 HUD는 이미 “원본 HUD 전용 필드 모델”이 아니라,
웹/서버 payload를 받아서 Flutter 쪽에서 해석하는 범용 snapshot에 가깝다.

이 구조의 문제는:
- 원본 우선순위가 Flutter에 흩어진다
- placeholder를 UI에서 진짜처럼 다루기 쉽다
- 원본 semantics를 나중에 맞추기 어렵다

---

## 14. adaptive HUD를 새로 만들 때 권장하는 데이터 모델

지금 시점에서 가장 맞는 방향은
`디자인 전용 widget`보다 먼저 `원본 HUD 전용 snapshot`을 정의하는 것이다.

권장 필드 예시:
- `vEgoClusterKph`
- `vCruiseClusterKph`
- `applySpeedKph`
- `applySource`
- `cruiseTargetKph`
- `driveModeCode`
- `driveModeNameOriginal`
- `gpsHasFix`
- `longitudinalPersonality`
- `gearText`
- `activeCarrot`
- `roadLimitSpeedKph`
- `cameraLimitSpeedKph`
- `cameraSignType`
- `speedLimitOverOriginalRule`
- `trafficStateLp`
- `trafficStateCarrot`
- `cpuTempAvgC`
- `memPct`
- `diskUsedPct`
- `voltV`
- `showDeviceState`

이렇게 되면 adaptive UI는:
- mobile
- tablet
- overlay
- preview

어디서든 같은 semantic snapshot을 받아 다른 레이아웃만 그리면 된다.

---

## 15. 실무 의견

지금 네 방향이 맞다.

즉,
- HUD 디자인은 adaptive하게 새로 가고
- 먼저 해야 할 건 `원본 HUD 값 의미 정리`
- 그 다음이 `값 수집 경로 정리`
- 마지막이 `UI 구현`

순서는 무조건 이렇게 가는 게 맞다.

내 판단으로는 다음 작업 우선순위는 이렇다.

1. `원본 HUD 전용 snapshot spec` 문서화
2. `carrot_server.py`에서 placeholder 제거 가능한 필드부터 원본 값으로 교체
3. Flutter HUD는 이 spec 기준으로만 읽도록 분리
4. 그 다음 adaptive 디자인 구현

즉 지금은 디자인보다 데이터 계약이 먼저다.
