# CarrotPilot selfdrive 모듈

## controls/ — 차량 제어

| 파일 | 크기 | 역할 |
|------|------|------|
| `controlsd.py` | 15KB | 메인 제어 루프 (조향/가감속) |
| `plannerd.py` | 2KB | 경로 플래너 데몬 |
| `radard.py` | 30KB | 레이더 데이터 처리, 리드 차량 추적 |
| `beep.py` | 5KB | 경고음 생성 |
| `lib/` | — | 제어 라이브러리 (PID, 이벤트 등) |

## car/ — 차량 인터페이스

| 파일 | 크기 | 역할 |
|------|------|------|
| `card.py` | 12KB | CAN 메시지 파서/생성 |
| `cruise.py` | 35KB | 크루즈 제어 로직 |
| `car_specific.py` | 12KB | 차종별 특성 처리 |

## modeld/ — 딥러닝 모델

| 파일 | 크기 | 역할 |
|------|------|------|
| `modeld.py` | 22KB | 주행 모델 추론 데몬 |
| `dmonitoringmodeld.py` | 7KB | 운전자 모니터링 모델 |
| `fill_model_msg.py` | 11KB | 모델 출력 → 메시지 변환 |
| `parse_model_outputs.py` | 6KB | 모델 출력 파싱 |
| `constants.py` | 2KB | 모델 상수 |
| `models/` | — | ONNX/tinygrad 모델 파일 |
| `runners/` | — | 모델 실행기 (tinygrad/ONNX) |
| `transforms/` | — | 입력 전처리 변환 |

## selfdrived/ — 상태 관리

| 파일 | 크기 | 역할 |
|------|------|------|
| `selfdrived.py` | 25KB | 메인 상태 머신 |
| `events.py` | 43KB | 이벤트/알림 정의 (다국어) |
| `state.py` | 5KB | 상태 전이 로직 |
| `alertmanager.py` | 2KB | 알림 관리자 |

## locationd/ — 위치/보정

| 파일 | 크기 | 역할 |
|------|------|------|
| `locationd.py` | 15KB | 위치 추정 (EKF) |
| `calibrationd.py` | 12KB | 카메라 보정 |
| `paramsd.py` | 14KB | 파라미터 추정 |
| `torqued.py` | 12KB | 토크 학습 |
| `lagd.py` | 16KB | 응답 지연 추정 |

## navd/ — 내비게이션

| 파일 | 크기 | 역할 |
|------|------|------|
| `navd.py` | 14KB | 내비게이션 데몬 |
| `map_renderer.cc/h` | 14KB | 지도 렌더링 (C++) |

## monitoring/ — 운전자 모니터링

| 파일 | 크기 | 역할 |
|------|------|------|
| `dmonitoringd.py` | 2KB | 모니터링 데몬 |
| `helpers.py` | 22KB | 졸음/주시 감지 로직 |

## pandad/ — Panda 통신

| 파일 | 크기 | 역할 |
|------|------|------|
| `pandad.cc` | 18KB | CAN 버스 메인 데몬 (C++) |
| `panda.cc/h` | 12KB | Panda 하드웨어 추상화 |
| `panda_comms.cc/h` | 10KB | 통신 프로토콜 |
| `panda_safety.cc` | 3KB | 안전 모듈 |
| `spi.cc` | 11KB | SPI 통신 |

## ui/ — 온스크린 UI

| 파일 | 크기 | 역할 |
|------|------|------|
| `carrot.cc` | **132KB** | CarrotPilot 커스텀 주행 화면 |
| `ui.cc/h` | 11KB | UI 상태 관리 |
| `soundd.py` | 10KB | 사운드 재생 |
| `qt/` | — | Qt 위젯 (사이드바, 설정, 온로드 등) |
