# TMAP 7712 포트 / carrotpilot 내비 필드 분석 (2026-03-06)

최종 분석일: 2026-03-06

분석 대상:
- `E:\CarrotLink\C3-v10-wip`
- `E:\CarrotLink\CarrotLink`

주의:
- 이번 턴에서는 예전 분석 문서에 언급된 CarrotMan Android 역컴파일 원본 경로가 로컬에 존재하지 않아, TMAP 앱 측 ContentProvider ingress는 재검증하지 못했다.
- 대신 `c3-v10-wip`의 실제 수신/가공 코드와 `CarrotLink` sidecar/app 코드로 현재 동작을 재확인했다.

## 1. 한 줄 결론

- `7712`는 현재 `c3-v10-wip`에서 외부 내비 데이터를 받는 `TCP JSON line` 입력 포트다.
- 실사용 핵심 입력은 `vrtx`와 `rgdata`다.
- `TMAP -> carrotpilot 직접 통신`이라기보다, `외부 내비/CarrotMan -> 7712 -> carrot_man -> carrot_serv -> carrotMan/navInstructionCarrot -> sidecar -> CarrotLink` 흐름으로 보는 게 맞다.

## 2. 현재 포트 구조 정리

`c3-v10-wip/selfdrive/carrot/carrot_man.py` 기준으로 내비 관련 입력 포트는 세 갈래가 보인다.

### 2.1 `7712` TCP

현재 가장 직접적인 외부 내비 입력 포트다.

- 서버: `carrot_navi_tcp_server(7712)`
- 바인드: `0.0.0.0:7712`
- 프로토콜: `UTF-8` 텍스트, `newline-delimited JSON`
- 처리 방식: 한 줄씩 읽고 `json.loads()` 후 dispatch

실제 분기:
- `vrtx` -> route 처리
- `rgdata` -> 내비/속도/도로/위치 상태 처리
- `sinf` -> 분기 존재하지만 현 스냅샷에는 `handle_signal()` 정의가 보이지 않음

즉, 현 코드 기준으로 `7712`에서 믿고 쓸 수 있는 건 사실상 `vrtx`와 `rgdata`다.

### 2.2 `7706` UDP

기존 carrot 데이터 수신 경로다.

- `carrot_man_thread()`에서 `0.0.0.0:7706` 바인드
- 수신 JSON을 `self.carrot_serv.update(json_obj)`로 전달

이 경로는 예전 문서에서 설명한 CarrotMan UDP 연동과 일치한다.

### 2.3 `7709` TCP

구형 route 전용 서버로 보인다.

- 고정 길이 바이너리 float 좌표를 받는다
- 현재 `7712`의 JSON route 입력에 비해 구식 경로다

실전 기준으로는 `7712`가 우선이다.

## 3. `7712`에서 실제로 받는 정보

### 3.1 `vrtx`: 경로 원본 점열

`carrot_man.py`의 `_dispatch_obj()`는 `obj["vrtx"]`를 `handle_route()`로 넘긴다.

기대 형식:

```json
{
  "vrtx": [
    { "x": 127.1234, "y": 37.1234, "valid": true },
    { "x": 127.1235, "y": 37.1235, "valid": true }
  ]
}
```

의미:
- `x = longitude`
- `y = latitude`
- `valid = optional`, 기본값 `true`

처리 결과:
- invalid 점 제거
- `self.navi_points`에 `(lon, lat)` 저장
- `navRoute` 퍼블리시
- 마지막 점을 `NavDestination`으로 저장

중요:
- `vrtx`는 앱 화면에 바로 쓰는 AR 좌표가 아니다
- 이건 경로 원본 GPS 점열이다

### 3.2 `rgdata`: TBT/속도/도로/위치 메타

`obj["rgdata"]`는 `carrot_serv.update()`로 전달된다.

현 코드에서 직접 파싱하는 필드는 다음과 같다.

### 속도/카메라/SDI 계열

- `nRoadLimitSpeed`
- `nSdiType`
- `nSdiSpeedLimit`
- `nSdiSection`
- `nSdiDist`
- `nSdiBlockType`
- `nSdiBlockSpeed`
- `nSdiBlockDist`
- `nSdiPlusType`
- `nSdiPlusSpeedLimit`
- `nSdiPlusDist`
- `nSdiPlusBlockType`
- `nSdiPlusBlockSpeed`
- `nSdiPlusBlockDist`
- `roadcate`

### 턴 바이 턴 계열

- `nTBTDist`
- `nTBTTurnType`
- `szTBTMainText`
- `szNearDirName`
- `szFarDirName`
- `nTBTNextRoadWidth`
- `nTBTDistNext`
- `nTBTTurnTypeNext`

### 경로/목적지/도로 메타

- `nGoPosDist`
- `nGoPosTime`
- `szPosRoadName`
- `goalPosX`
- `goalPosY`
- `szGoalName`

### 위치/자차 자세 계열

- `vpPosPointLat`
- `vpPosPointLon`
- `nPosAngle`
- `nPosSpeed`

### 폰 GPS 폴백 계열

`carrot_serv.update()`는 아래 필드도 별도 처리한다.

- `latitude`
- `longitude`
- `heading`
- `accuracy`
- `gps_speed`

의미:
- 내비 쪽 GPS가 3초 이상 안 들어오면 폰 GPS를 위치 보정 입력으로 사용한다

### 3.3 `sinf`

분기 자체는 존재한다.

```python
if "sinf" in obj:
  self.handle_signal(obj["sinf"])
```

하지만 현재 스냅샷에서는 `handle_signal()` 정의를 찾지 못했다. 따라서 `sinf`는 현재 미완성, 레거시, 또는 빠진 코드 경로로 보는 게 안전하다.

## 4. `7712` 데이터가 carrotpilot 내부에서 어떻게 바뀌는가

`7712`에서 받은 원본 route는 그대로 앱에 쓰이지 않는다.

실제 변환 흐름:

1. `vrtx`로 받은 `(lon, lat)` 점열 저장
2. 현재 차량 위치와 heading 기준으로 경로 일부를 잘라냄
3. `gps_to_relative_xy()`로 상대 좌표계 변환
4. 일정 간격으로 resample
5. curvature 계산 후 route speed 추정
6. `update_navi()`에서 `carrotMan.naviPaths` 문자열로 직렬화

즉, 앱이 실제로 활용하기 좋은 값은 원본 `vrtx`보다 가공된 `carrotMan` 쪽이다.

## 5. 핵심 출력 필드

`carrot_serv.update_navi()`는 최종적으로 `carrotMan` 메시지를 만든다.

AR/주행 오버레이 관점에서 중요한 출력:
- `xTurnInfo`
- `xDistToTurn`
- `szTBTMainText`
- `szPosRoadName`
- `nRoadLimitSpeed`
- `xSpdType`
- `xSpdLimit`
- `xSpdDist`
- `trafficState`
- `xPosLat`
- `xPosLon`
- `xPosAngle`
- `xPosSpeed`
- `nGoPosDist`
- `nGoPosTime`
- `naviPaths`
- `leftSec`

### `naviPaths`의 의미

포맷:

```text
x,y,d;x,y,d;...
```

의미:
- `x`: 전방 거리축에 가까운 상대 좌표
- `y`: 좌우 오프셋
- `d`: 경로 누적 거리

주의:
- 이 값은 원본 GPS `lat/lng`가 아니다
- 현재 차량과 heading 기준으로 변환된, 화면 투영 친화적인 상대 경로다

## 6. UI에서 실제로 쓰는 방식

`selfdrive/ui/carrot.cc`는 `carrotMan.getNaviPaths()`를 파싱해서:

- `x,y,d`를 읽고
- lane line의 `z`를 참고해
- `mapToScreen()`으로 화면에 투영한다

즉 carrotpilot의 기존 내비 시각화는 이미

- route 원본 GPS를 직접 렌더하는 게 아니라
- `carrotMan.naviPaths`라는 가공된 상대 경로를 렌더하는 구조다

## 7. CarrotLink에서 현재 받을 수 있는가

현재 `CarrotLink` sidecar는 이미 다음 서비스를 `p2/p3/p4` 프로필에 포함한다.

- `carrotMan`
- `navInstructionCarrot`

그리고 실제 payload에도 포함한다.

즉 현재 CarrotLink는 이미 아래 데이터를 받을 수 있다.

- `carrotMan.naviPaths`
- `carrotMan.xTurnInfo`
- `carrotMan.xDistToTurn`
- `carrotMan.szTBTMainText`
- `carrotMan.szPosRoadName`
- `carrotMan.nRoadLimitSpeed`
- `navInstructionCarrot.maneuverType`
- `navInstructionCarrot.maneuverModifier`
- `navInstructionCarrot.maneuverDistance`
- `navInstructionCarrot.distanceRemaining`

## 8. CarrotLink에서 실제 파싱 중인 것

`live_drive_canvas_overlay_models_components.dart` 기준으로 앱은 이미:

- `naviPaths`를 `_parseNaviPathPoints()`로 파싱
- `xTurnInfo`
- `xDistToTurn`
- `szTBTMainText`
- `navInstructionCarrot`의 maneuver 정보

를 snapshot에 반영한다.

또 `live_drive_canvas_overlay_components.dart`에서는:

- nav path ribbon
- chevron
- turn gate
- distance text

같은 AR-like 요소를 이미 그리고 있다.

즉 데이터 관점에서 보면, `7712/TMAP 계열 정보 활용 기반`은 이미 앱 내부에 일부 존재한다.

## 9. AR 구현 관점에서 무엇이 특히 중요하나

stock 모드 원격 카메라 위 3D/AR-like 오버레이 관점에서 우선순위가 높은 필드는 아래다.

### 1순위

- `naviPaths`
- `xTurnInfo`
- `xDistToTurn`
- `szTBTMainText`
- `navInstructionCarrot.allManeuvers`

이 조합이면:
- 경로 리본
- 회전 게이트
- 턴 방향 표지
- 거리 카운트다운

구현이 가능하다.

### 2순위

- `xPosLat`
- `xPosLon`
- `xPosAngle`
- `xPosSpeed`
- `nGoPosDist`
- `nGoPosTime`

이 조합이면:
- 위치/heading 안정화
- route anchor 품질 개선
- ETA/remaining UI

에 활용할 수 있다.

### 3순위

- `nRoadLimitSpeed`
- `xSpdType`
- `xSpdLimit`
- `xSpdDist`
- `trafficState`

이 조합이면:
- 속도카메라 표지
- 감속 유도
- 신호등 상태 표시

같은 보조 AR 레이어를 만들 수 있다.

## 10. 기술 판단

결론:

- `7712`에서 받는 정보는 AR에 활용 가치가 충분하다
- 특히 `naviPaths`는 원본 GPS가 아니라 이미 ego-relative로 가공된 경로라서 모바일 AR-like overlay에 매우 적합하다
- 따라서 새 stock-mode remote AR를 만들 때 1차 데이터 소스는 `carrotMan`과 `navInstructionCarrot`로 잡는 게 맞다
- `vrtx` 원본까지 바로 사용할 필요는 낮다

## 11. 실무상 권장

1. CarrotLink 1차 구현은 `carrotMan + navInstructionCarrot`만 사용
2. `7712` 원본 schema 변경 감지를 위해 앱/sidecar에 필드 missing 로그 추가
3. `sinf`는 현 코드상 불확실하므로 핵심 의존성에서 제외
4. `naviPaths`와 camera frame sync를 먼저 맞추고, 그 다음 3D 표현을 올리는 순서가 맞다
