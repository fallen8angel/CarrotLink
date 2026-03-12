# CarrotPilot 커스텀 확장 모듈 (selfdrive/carrot/)

## 모듈 전체 구조

```
selfdrive/carrot/
├── carrot_man.py          # 40KB  종합 관리자
├── carrot_serv.py         # 53KB  서버 통신/원격 제어
├── carrot_server.py       # 40KB  Flask 웹 서버
├── carrot_speed.py        # 13KB  속도 제어
├── carrot_functions.py    # 25KB  공통 함수
├── carrot_controls.py     # 1KB   제어 인터페이스
├── xiaoge_data.py         # 42KB  중국 차량 데이터
└── web/                   #       웹 HUD 인터페이스
    ├── index.html         # 17KB  메인 웹 페이지
    ├── app.js             # 45KB  JavaScript 앱
    ├── hud_card.js        # 6KB   HUD 카드 컴포넌트
    ├── hud_card.css       # 5KB   HUD 카드 스타일
    ├── speed_bg.png       #       속도계 배경
    └── webrtc_test.html   # 7KB   WebRTC 테스트
```

## 핵심 모듈 상세

### carrot_man.py (40KB) — CarrotMan 관리자

- openpilot 주행 상태에 맞춘 **CarrotPilot 고유 기능 총괄**
- 속도 제한, 턴 정보, 내비 경로 등 `carrotMan` 메시지 발행
- 교통 신호 상태, 구간단속 감지
- 도로 이름, TBT(Turn-by-Turn) 텍스트 생성
- APN/APM 연결 상태 관리

### carrot_serv.py (53KB) — 서버 통신

- 외부 서버(카카오내비 등)와 실시간 데이터 교환
- 원격 제어 명령 수신/실행
- GPS 위치 전송
- 속도 카메라/구간단속 정보 수신

### carrot_server.py (40KB) — Flask 웹 서버

- 기기 내 HTTP API 서버 (`/health`, `/status`, `/settings` 등)
- 웹 HUD 페이지 서빙 (`web/index.html`)
- WebSocket 기반 실시간 데이터 스트리밍
- 설정 조회/변경 REST API

### carrot_speed.py (13KB) — 속도 제어

- 속도 제한 카메라 연동
- 구간단속 속도 제어
- 커브 감속 로직
- 도로 제한 속도 적용

### carrot_functions.py (25KB) — 공통 함수

- 좌표 변환, 거리 계산
- 도로 정보 파싱
- 설정 값 읽기/쓰기 유틸리티

### xiaoge_data.py (42KB) — 중국 차량 데이터

- 중국 시장 차량 지원
- 중국 도로 데이터 처리
- 속도 카메라 정보 변환

## 웹 HUD (web/)

### app.js (45KB)
- WebSocket 기반 실시간 주행 데이터 수신
- 속도계, 신호등, 내비게이션 UI 렌더링
- 터치/제스처 이벤트 처리
- 카메라 스트리밍 표시

### index.html (17KB)
- 모바일 최적화 레이아웃
- 속도계, 운전 모드, 신호등, 내비 정보 표시
- CSS 애니메이션 기반 동적 UI

## Params 연동 (CarrotPilot 설정 키)

carrot 모듈은 `common/params`를 통해 다음과 같은 설정을 읽고 씁니다:

| Param 키 | 용도 |
|----------|------|
| `ShowPathMode` | 경로 표시 모드 |
| `ShowPathColor` | 경로 색상 |
| `ShowPathModeLane` | 차선 모드 경로 |
| `ShowPathColorLane` | 차선 모드 경로 색상 |
| `ShowPathColorCruiseOff` | 크루즈 꺼짐 시 경로 색상 |
| `ShowPathWidth` | 경로 너비 |
| `ShowRadarInfo` | 레이더 정보 표시 |
| `RadarLatFactor` | 레이더 횡방향 팩터 |
| `ShowPlotMode` | 디버그 그래프 모드 (1~8) |
| `LongitudinalPersonality` | 차간거리 성향 |
| `ShowDeviceState` | 기기 상태 표시 |
| `ShowDateTime` | 날짜/시간 표시 모드 |
| `LanguageSetting` | 언어 (main_ko/main_en/main_zh-CHS) |
| `HardwareC3xLite` | C3XL 하드웨어 플래그 |
