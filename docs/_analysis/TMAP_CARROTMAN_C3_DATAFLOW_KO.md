# TMAP-CarrotMan-c3(v10) 연동 원리/로직 상세 문서

## 1) 한 줄 결론
- `c3-v10`이 TMAP 데이터를 직접 받는 구조가 아니라, **CarrotMan 앱이 TMAP 이벤트를 수신/파싱한 뒤 UDP JSON으로 c3에 전달**하는 구조다.

## 2) 분석 범위(원본 코드)
- TMAP 수신/가공(안드로이드, 역컴파일)
  - `d:\CarrotLink\CarrotMan(R)\decompiled\jadx_full\resources\AndroidManifest.xml`
  - `d:\CarrotLink\CarrotMan(R)\decompiled\jadx_full\sources\com\ajouatom\carrotman\event\provider\TMapEventProvider.java`
  - `d:\CarrotLink\CarrotMan(R)\decompiled\jadx_full\sources\com\ajouatom\carrotman\event\provider\TMapEventProvider$insert$1.java`
  - `d:\CarrotLink\CarrotMan(R)\decompiled\jadx_full\sources\com\ajouatom\carrotman\service\CarrotService.java`
  - `d:\CarrotLink\CarrotMan(R)\decompiled\jadx_full\sources\com\ajouatom\carrotman\service\CarrotService$sendRgdata$1.java`
  - `d:\CarrotLink\CarrotMan(R)\decompiled\jadx_full\sources\com\ajouatom\carrotman\service\CarrotService$postCarrotData$2.java`
- c3 수신/적용/배포
  - `d:\CarrotLink\c3-v10-wip\selfdrive\carrot\carrot_man.py`
  - `d:\CarrotLink\c3-v10-wip\selfdrive\carrot\carrot_serv.py`
  - `d:\CarrotLink\c3-v10-wip\cereal\custom.capnp`
  - `d:\CarrotLink\c3-v10-wip\selfdrive\controls\controlsd.py`
  - `d:\CarrotLink\c3-v10-wip\selfdrive\controls\lib\lateral_planner.py`
  - `d:\CarrotLink\c3-v10-wip\selfdrive\ui\ui.cc`
  - `d:\CarrotLink\c3-v10-wip\selfdrive\ui\qt\maps\map.cc`

## 3) End-to-End 흐름
1. TMAP 계열 앱이 ContentProvider(`com.ajouatom.carrotman.provider`)로 데이터 insert
2. CarrotMan `TMapEventProvider`가 `opakr-*` 키를 읽고 유효 데이터만 LiveData에 반영
3. CarrotService가 LiveData를 queue로 옮겨 비동기 처리
4. `sendRgdata`가 `OpakrRgdata -> CarrotData`로 매핑
5. `postCarrotData`가 UDP(JSON)로 c3 IP:PORT에 송신
6. c3 `carrot_man_thread`가 UDP 수신 후 `carrot_serv.update(json)` 호출
7. c3 내부 `carrotMan`/`navInstructionCarrot` 메시지로 변환해 controls/UI에 배포

## 4) TMAP 쪽 ingress(무엇을 받는가)

### 4.1 ContentProvider 진입점
- Provider 등록
  - `AndroidManifest.xml:29`
  - `android:authorities="com.ajouatom.carrotman.provider"`
- insert 엔트리
  - `TMapEventProvider.java:35`
- HUD 테스트 트리거
  - `TMapEventProvider.java:41`

### 4.2 insert에서 읽는 키(실제)
- `TMapEventProvider$insert$1.java`
  - `opakr-sinf` (`:72`)
  - `opakr-route` (`:82`)
  - `opakr-vrtx` (`:91`)
  - `opakr-rgdata` (`:102`)
- 공통 처리
  - 공백/`{}`/`null` 문자열은 무시
  - 유효하면 `hudTest()` 호출 (`:79`, `:88`, `:99`, `:110`)
  - `opakr-vrtx`는 `LiveData.getOpakrVrtx().postValue(...)` (`:97`)
  - `opakr-rgdata`는 `LiveData.getOpakrRgdata().postValue(...)` (`:108`)

## 5) CarrotMan 내부 전달(중간 버스)
- LiveData observer 등록
  - `CarrotService.java:146-151`
- queue 적재
  - `OpakrSinf` -> `sinfQueue.put` (`:204`)
  - `OpakrRoute` -> `routeQueue.put` (`:228`)
  - `OpakrVrtx` -> `vrtxQueue.put` (`:252`)
  - `OpakrRgdata` -> `rgdataQueue.put` (`:276`)
- 재연결 시 최신값 재적재
  - `setLatestData()`에서 각 LiveData 현재값을 queue에 put (`:340-358`)
- 단절 시 queue clear
  - `disconnected()`에서 queue clear (`CarrotService.java` 본문)

## 6) CarrotMan -> c3 UDP 송신 로직

### 6.1 송신 스레드
- 초기화 시 실행
  - `CarrotService.java:61` (`sendRgdata()`)
- 본 함수
  - `CarrotService.java:405`
  - 실제 구현 `CarrotService$sendRgdata$1.java`

### 6.2 `OpakrRgdata -> CarrotData` 핵심 매핑
- SDI
  - `nSdiType` -> `setNSdiType` (`sendRgdata$1.java:102`)
  - `nSdiSpeedLimit` -> `setNSdiSpeedLimit` (`:106`)
- 턴
  - `nTBTDist` -> `setNTBTDist` (`:136`)
  - `nTBTTurnType` -> `setNTBTTurnType` (`:140`)
  - next turn -> `setNTBTDistNext`, `setNTBTTurnTypeNext` (`:159`, `:160`)
- 속도/도로
  - `nRoadLimitSpeed` -> `setNRoadLimitSpeed` (`:164`)
  - `szPosRoadName` -> `setSzPosRoadName` (`:176`)
- 위치/목적지
  - `vpPosPointLat` -> `setVpPosPointLat` (`:209`)
  - `vpPosPointLon` -> `setVpPosPointLon` (`:213`)
  - `goalPosX/Y` -> `setGoalPosX/Y` (`:225`, `:229`)
- 최종 송신 호출
  - `postCarrotData(...)` (`:237`)

### 6.3 UDP 전송 세부
- 메타 필드 추가
  - `setCarrotIndex` (`postCarrotData$2.java:64`)
  - `setEpochTime` (`:65`)
  - `setTimezone` (`:66`)
- 소켓/전송
  - `DatagramSocket` (`:69`)
  - `setSoTimeout(5000)` (`:72`)
  - 대상 `ip/port` (`:76`, `:77`)
  - `socket.send(DatagramPacket...)` (`:79`)

## 7) c3 측 수신/적용/배포

### 7.1 포트/브로드캐스트/수신
- 포트
  - `broadcast_port = 7705` (`carrot_man.py:203`)
  - `carrot_man_port = 7706` (`:204`)
- 브로드캐스트 루프
  - 시작 `broadcast_version_info()` (`:265`)
  - 주기 제어 `Ratekeeper(20)` (`:274`)
  - 브로드캐스트 조건 `frame % 20 == 0` (`:310`)
  - 실전송 `sock.sendto(..., (broadcast_ip, 7705))` (`:325`)
  - 즉 대략 1초마다(20Hz 루프에서 20프레임 간격) 기본 브로드캐스트
- 수신 루프
  - `carrot_man_thread()` (`:593`)
  - `sock.bind(('0.0.0.0', 7706))` (`:598`)
  - 수신 JSON -> `self.carrot_serv.update(json_obj)` (`:617`)

### 7.2 c3 update 적용 핵심
- 엔트리
  - `carrot_serv.py:1183` `def update(self, json):`
- 파싱 예
  - `nRoadLimitSpeed` (`:1214`)
  - `nSdiType` (`:1235`)
  - `nTBTDist`, `nTBTTurnType` (`:1252`, `:1253`)
  - `szPosRoadName` (`:1265`)
  - `vpPosPointLat/Lon` (`:1269`, `:1270`)

### 7.3 내부 메시지 배포
- `carrotMan` 퍼블리시
  - 생성 `new_message('carrotMan')` (`:1049`)
  - 필드 예
    - `nRoadLimitSpeed` (`:1052`)
    - `xSpdType/Limit/Dist` (`:1054-1056`)
    - `xTurnInfo/xDistToTurn` (`:1058-1059`)
    - `szPosRoadName` (`:1063`)
    - `naviPaths` (`:1083`)
- `navInstructionCarrot` 퍼블리시
  - 생성 (`:1088`)
  - carrot inactive 시 기본 `navInstruction` 폴백 (`:1129`)
  - send (`:1131`)

## 8) c3에서 실제 사용하는 지점

### 8.1 스키마
- `custom.capnp`
  - `struct CarrotMan` (`:14`)
  - 주요 필드
    - `nRoadLimitSpeed` (`:16`)
    - `xSpdType/Limit/Dist` (`:18-20`)
    - `xTurnInfo/xDistToTurn` (`:22-23`)
    - `szPosRoadName` (`:27`)
    - `naviPaths` (`:42`)
    - `leftSec` (`:43`)

### 8.2 Controls
- `controlsd.py`
  - `self.sm['carrotMan'].vTurnSpeed` 사용 (`:151`)
  - `desiredSpeed` 반영 (`:213`)
  - HUD 제어 `activeCarrot`, `atcDistance` (`:223-224`)
- `lateral_planner.py`
  - `curve_speed = sm['carrotMan'].vTurnSpeed` (`:101`)

### 8.3 UI/지도
- `ui.cc`
  - SubMaster에 `carrotMan`, `navInstructionCarrot` 등록 (`:108-109`)
- `map.cc`
  - carrot 좌표 사용 (`:225-229`)
  - `navInstruction`/`navInstructionCarrot` 업데이트 처리 (`:367`, `:372`, `:374`)

## 9) TMAP에서 받아서 실제 활용되는 정보 카테고리
- 제한속도/과속카메라 계열: `nSdiType`, `nSdiSpeedLimit`, `nSdiDist`, block/plus 계열
- 턴 안내 계열: `nTBTDist`, `nTBTTurnType`, next turn
- 도로/목적지 메타: `szPosRoadName`, `nGoPosDist`, `nGoPosTime`, `szGoalName`
- 위치/자차 추정 보정: `vpPosPointLat/Lon`, `nPosAngle`, `nPosSpeed`

## 10) 안정성/폴백 관점 핵심 포인트
- UDP는 기본적으로 무연결/무보장이라 ACK 기반 보장 전송이 아님.
- c3는 broadcast(7705) + 수신(7706) 분리 구조라 IP 변경 시 재발견 가능성은 높지만, 네트워크 상황/방화벽 영향은 받음.
- `nRoadLimitSpeed`는 즉시 반영이 아니라 카운터 조건(`>5`)을 두고 반영 (`carrot_serv.py:1227-1232`).
- carrot 내비가 비활성일 때 `navInstructionCarrot`는 기본 `navInstruction`로 폴백 (`:1129`).

## 11) 참고: 데이터 직결 여부
- `carrotpilot(c3)`가 TMAP 프로세스와 직접 통신하는 코드 경로는 본 분석 범위에서 확인되지 않았다.
- 관찰된 구조는 **TMAP -> CarrotMan(ContentProvider) -> CarrotService(UDP) -> c3(carrot_man_thread)** 단일 파이프라인이다.
