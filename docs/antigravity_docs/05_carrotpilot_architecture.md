# CarrotPilot (c3-v10-wip) 아키텍처

## 기본 정보

| 항목 | 값 |
|------|-----|
| 베이스 | comma.ai openpilot 포크 |
| 포크 이름 | CarrotPilot |
| 타겟 OS | AGNOS (Linux, Qualcomm SoC) |
| 하드웨어 | comma 3 / 3X |
| 빌드 | SCons |
| 주요 언어 | Python, C++, C |
| 프로세스 관리 | `system/manager/manager.py` |

## 시스템 시작 흐름

```
launch_chffrplus.sh
  ├── AGNOS 초기화 (agnos_init)
  │   ├── abctl --set_success
  │   ├── GPU 권한 설정
  │   └── AGNOS 업데이트 확인
  ├── Overlay 업데이트 확인/적용
  ├── PYTHONPATH 설정
  ├── pip 의존성 설치 (flask, shapely, kaitaistruct)
  ├── 다국어 이벤트 파일 교체 (ko/zh/en)
  ├── C3XL 앰프 파일 교체
  └── system/manager
      ├── build.py (prebuilt 없으면 빌드)
      └── manager.py (메인 프로세스 매니저)
```

## 디렉토리 구조 (최상위)

```
c3-v10-wip/
├── selfdrive/           # 자율주행 핵심 로직
│   ├── car/             # 차량 인터페이스, CAN 통신
│   ├── carrot/          # ★ CarrotPilot 커스텀 확장
│   ├── controls/        # 조향/가감속 제어
│   ├── modeld/          # 딥러닝 모델 추론
│   ├── selfdrived/      # 상태 관리, 이벤트
│   ├── locationd/       # 위치 추정, 보정
│   ├── navd/            # 내비게이션
│   ├── monitoring/      # 운전자 모니터링
│   ├── pandad/          # Panda 디바이스 통신
│   ├── ui/              # Qt C++ UI
│   ├── frogpilot/       # FrogPilot 모듈
│   └── debug/           # 디버그 도구
├── system/              # 시스템 서비스
│   ├── manager/         # 프로세스 매니저
│   ├── camerad/         # 카메라 드라이버
│   ├── hardware/        # 하드웨어 추상화
│   ├── loggerd/         # 데이터 로깅
│   ├── athena/          # 클라우드 통신
│   ├── sensord/         # 센서 드라이버
│   ├── webrtc/          # 원격 스트리밍
│   └── updated/         # OTA 업데이트
├── panda/               # Panda 펌웨어
├── cereal/              # IPC 메시지 (Cap'n Proto)
├── common/              # 공유 유틸리티
├── opendbc/             # 차량 DBC 데이터베이스
├── tinygrad/            # ML 추론 엔진
├── rednose/             # 칼만 필터
├── third_party/         # 서드파티
└── tools/               # 개발/디버그 도구
```

## 프로세스 매니저

`system/manager/process_config.py`에서 모든 데몬 프로세스를 정의하고, `manager.py`가 이를 관리합니다.

## IPC (프로세스 간 통신)

- **cereal (Cap'n Proto)** — 메시지 직렬화/역직렬화
- **SubMaster / PubMaster** — 구독/발행 패턴
- **Params** — 공유 파라미터 저장소 (`/data/params/d/`)
