# CarrotPilot system 모듈

## system/ 디렉토리 구조

```
system/
├── manager/          # 프로세스 매니저
│   ├── manager.py        # 9KB  메인 매니저
│   ├── process.py        # 9KB  프로세스 추상화
│   ├── process_config.py # 8KB  프로세스 목록 정의
│   ├── build.py          # 3KB  빌드 스크립트
│   └── helpers.py        # 2KB  헬퍼 함수
├── camerad/          # 카메라 드라이버
├── hardware/         # 하드웨어 추상화
├── loggerd/          # 주행 데이터 로깅
├── athena/           # 클라우드 통신
├── sensord/          # 센서 드라이버 (IMU, 가속도 등)
├── ubloxd/           # GPS (u-blox)
├── qcomgpsd/         # Qualcomm GPS
├── logcatd/          # Android logcat
├── proclogd/         # 프로세스 로그
├── webrtc/           # 원격 영상 스트리밍
├── updated/          # OTA 업데이트 시스템
└── ui/               # 시스템 UI
    └── installer/    # 설치 마법사
```

## common/ — 공유 유틸리티 (50개 파일)

| 파일 | 역할 |
|------|------|
| `params.py/cc/h` | 공유 파라미터 저장소 (`/data/params/d/`) |
| `params_keys.h` | 전체 파라미터 키 정의 (16KB) |
| `realtime.py` | 실시간 스케줄링 |
| `pid.py` | PID 컨트롤러 |
| `filter_simple.py` | 간단한 필터 |
| `simple_kalman.py` | 칼만 필터 |
| `swaglog.py/cc` | 구조화 로깅 (cloudlog) |
| `gpio.py` | GPIO 제어 |
| `api.py` | Comma API 클라이언트 |
| `spinner.py` | 로딩 표시 |
| `transformations/` | 좌표 변환 행렬 |
| `conversions.py` | 단위 변환 |
| `timeout.py` | 타임아웃 유틸 |

## panda/ — CAN 인터페이스

```
panda/
├── board/          # STM32 펌웨어 (C)
├── python/         # Python API
├── drivers/        # USB/SPI 드라이버
├── certs/          # 인증서
├── crypto/         # 암호화
├── tests/          # 안전 테스트
└── release/        # 릴리스 빌드
```

## 외부 모듈 (git submodule)

| 모듈 | 역할 |
|------|------|
| `cereal/` | IPC 메시지 스키마 (Cap'n Proto) |
| `opendbc/` | 차량 CAN DBC 데이터베이스 |
| `tinygrad/` | 경량 ML 추론 프레임워크 |
| `rednose/` | 칼만 필터 라이브러리 |
| `msgq/` | 메시지 큐 |
| `teleoprtc/` | 원격 RTC 통신 |
