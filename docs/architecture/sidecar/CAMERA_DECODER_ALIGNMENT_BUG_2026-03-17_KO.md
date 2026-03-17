# 카메라 디코더 정렬 버그 분석 및 수정 — 2026-03-17

## 요약

DM2 v6 WIP + C4(Galaxy Z Fold6, SM-F966N) 환경에서 로드카메라 첫 프레임이 영구적으로 대기 상태에 머무는 버그 분석 및 수정 기록.

**근본 원인**: `livestreamRoadEncodeData`의 해상도 1344×**760**에서 높이 760이 16의 배수가 아니어서 Snapdragon 8 Gen 3 하드웨어 H.264 디코더가 무음으로 출력을 거부함.
**수정 위치**: `NativeDriveVideoPlugin.kt` → `configureDecoder()`에서 MediaFormat 생성 시 width/height를 16의 배수로 올림 정렬.

---

## 증상

- 화면에 `"로드카메라 첫 프레임 대기 중입니다."` 메시지가 영구 지속
- 리부팅 후에도 동일 증상
- HUD 데이터(속도, 온도 등)는 정상 작동

---

## 진단 로그 분석

진단 로그 파일: `drive_diag_20260317_191218.ndjson`

### 상태 흐름

| 시간(초) | 네이티브 상태 | 의미 |
|---------|-------------|------|
| 0~2 | `connected` / `socketConnected` | WebSocket 연결 완료 |
| 2 | `decoder_configured_1344x760` | 키프레임 수신, MediaCodec 설정 완료 |
| 3 | `waiting_sync_frame_1519ms` | MediaCodec 출력 없음 |
| 4~8 | `waiting_sync_frame_Nms` 증가 | 출력 없음 지속 |
| ~9 | `waiting_sync_frame_7981ms` (freeze) | 하드 타임아웃 발동, 워치독 정지 |
| 10+ | 상태 frozen, `connectAttempts: 1` | 재연결 불발 (잠재적 데드락) |
| 20+ | `packetBytesWindow: 0`, `sidecar.connected: false` | 사이드카 연결 끊김 |

### 핵심 지표

```json
{
  "state": "decoder_configured_1344x760",
  "codecConfigured": true,
  "waitingKeyFrame": false,
  "packetsWindow": 20,
  "decodedWindow": 20,
  "decodeBacklog": 0,
  "codecBacklog": 0,
  "dropsTotal": 0,
  "connectAttempts": 1,
  "lastError": null
}
```

**해석**:
- `packetsWindow: 20` — 초당 20개 패킷이 MediaCodec에 제출됨 (데이터 흐름 정상)
- `decodedWindow: 20` — 제출된 프레임 처리 시도 중
- `dropsTotal: 0` — 드롭 없음
- `lastError: null` — MediaCodec이 예외를 던지지 않음
- `lastFrameEmitAtMs: 0` (암묵적) — MediaCodec **출력 콜백이 한 번도 호출되지 않음**

---

## 근본 원인 분석

### 1. 해상도 출처

DM2 v6 WIP는 `roadEncodeData` 대신 `livestreamRoadEncodeData` cereal 서비스를 사용(또는 quality 모드 순서상 해당 서비스가 먼저 응답). 이 서비스의 인코딩 해상도가 **1344×760**.

### 2. 16-byte 정렬 요구사항 위반

Qualcomm Snapdragon 계열(및 Samsung Exynos)의 하드웨어 H.264 디코더는 내부 버퍼 레이아웃 상 **width/height가 모두 16의 배수**여야 함.

```
1344 ÷ 16 = 84.0   ✅ (정렬됨)
 760 ÷ 16 = 47.5   ❌ (정렬 안 됨)
```

`MediaCodec.createVideoFormat("video/avc", 1344, 760)` 호출 시:
- `configure()` — 예외 없이 성공 (하드웨어 디코더가 에러 반환 안 함)
- `start()` — 예외 없이 성공
- 이후 프레임 제출 — MediaCodec이 입력은 받지만 **출력 버퍼를 전혀 반환하지 않음**

이는 하드웨어 디코더의 **silent failure** 패턴. 소프트웨어 디코더(OMX.google.h264.decoder)는 이 제한이 없지만, Android는 기본적으로 하드웨어 디코더를 우선 선택함.

### 3. 하드 타임아웃 후 잠재적 데드락

`startupSyncFrameHardTimeoutMs` 초과 → 워치독이 다음을 순차 실행:
```
emitError("startup_sync_frame_timeout_Nms")
stopFrameWatchdog()     ← 워치독 루프 중단 (state frozen 원인)
closeSocket()           ← WebSocket 종료
releaseDecoder()        ← codec.stop() + codec.release() 호출
scheduleReconnect()     ← Handler.postDelayed()
```

`releaseDecoder()` 시점에 MediaCodec이 출력을 기다리는 내부 상태에 있으면, `codec.release()`가 **무기한 블록**될 수 있음. 이로 인해 `scheduleReconnect()` 호출 불발 → `connectAttempts: 1` 유지.

---

## 수정 내용

**파일**: `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
**함수**: `configureDecoder(width: Int, height: Int)`

### 변경 전

```kotlin
val format = MediaFormat.createVideoFormat("video/avc", width, height)
format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
```

### 변경 후

```kotlin
// Hardware H.264 decoders (Snapdragon, Exynos) require dimensions aligned to
// a multiple of 16. Non-aligned heights like 760 cause the decoder to silently
// accept input but produce no output frames. Round up to the nearest 16-byte
// boundary to avoid this issue; the SPS/PPS in the bitstream remains authoritative.
val alignedWidth = (width + 15) and 15.inv()
val alignedHeight = (height + 15) and 15.inv()
val format = MediaFormat.createVideoFormat("video/avc", alignedWidth, alignedHeight)
format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, alignedWidth * alignedHeight)
```

### 정렬 계산 예시

| 원본 해상도 | 정렬 후 | MediaFormat에 전달 |
|-----------|--------|-----------------|
| 1344×760 | 1344×768 | 1344×768 |
| 1928×1208 | 1928×1208 | 변화 없음 |
| 1920×1080 | 1920×1080 | 변화 없음 |
| 1280×720 | 1280×720 | 변화 없음 |

`emitState("decoder_configured_${width}x$height")`는 **원본 해상도** 기준으로 표시 유지 (진단 로그의 실제 스트림 해상도 가독성 보존).

### 안전성

- `alignedWidth × alignedHeight`는 실제 스트림의 SPS/PPS 정보보다 같거나 큼 → MediaCodec이 내부적으로 실제 해상도를 SPS/PPS에서 읽어 크롭 처리
- 기존에 정렬된 해상도(1920×1080, 1928×1208 등)는 수치 변화 없음 → 기존 동작에 영향 없음

---

## 영향 범위

| 항목 | 영향 |
|-----|-----|
| DM2 v6 WIP + C4 | ✅ 직접 수정 대상 |
| 기타 C4 유저 (표준 해상도) | 무영향 (이미 정렬됨) |
| C3 유저 | 무영향 |
| 향후 비표준 해상도 | 자동 보호됨 |

---

## 재현 조건

- **기기**: SM-F966N (Galaxy Z Fold6, Snapdragon 8 Gen 3)
- **openpilot fork**: DM2 v6 WIP (C4 branch)
- **카메라 서비스**: `livestreamRoadEncodeData` → 1344×760 인코딩
- **증상 확인**: `decoder_configured_1344x760` 이후 `waiting_sync_frame_Nms` 영구 지속

---

## 참고: `waiting_sync_frame` vs `waiting_keyframe`

| 상태 | 의미 |
|-----|-----|
| `waiting_keyframe_Nms` | `codecConfigured=true`, `waitingKeyFrame=true` — 키프레임 도착 전 |
| `waiting_sync_frame_Nms` | `codecConfigured=true`, `waitingKeyFrame=false` — 키프레임 이후 MediaCodec 출력 없음 |

이번 케이스는 `waiting_sync_frame` → 키프레임은 수신했으나 디코더 출력이 없는 상황.
