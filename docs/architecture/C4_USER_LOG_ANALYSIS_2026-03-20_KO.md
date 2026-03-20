# C4 유저 사용 로그 분석 (2026-03-20)

> **분석 일자**: 2026-03-20
> **로그 출처**: `E:\Carrot\logs\` (camera_error, drive_diag_export 3건) + `E:\Carrot\logs\A\` (C3 비교 로그)
> **브랜치**: CarrotLink `dev` / C4 `c4-v5-wip` / C3 비교
> **대상 디바이스**: C4 2대 (10.105.194.172, 10.24.118.45) + C3 1대 (10.246.207.166)

## 유저 피드백 원문

- "오늘은 그래픽이 죽었네요"
- "시간 지나니 다시 살아나긴 했습니다"
- "로드카메라가 검은화면"
- "그래픽이 간혹 끊기는 거 같음"

---

## 1. 로그 개요

| 파일 | 디바이스 IP | 시간 | 내용 |
|---|---|---|---|
| `drive_diag_export_20260320_070447.json` | 10.105.194.172 | 07:04 | 정상 동작, frameId null |
| `drive_diag_export_20260320_070618.json` | 10.105.194.172 | 07:06 | 정상 동작, frameId null |
| `drive_diag_export_20260320_071027.json` | 10.24.118.45 | 07:10 | 카메라 사망 상태 |
| `camera_error_20260320_070956_561.log` | 10.24.118.45 | 07:09 | 카메라 에러 + tmux 로그 |

### 디바이스별 상태 요약

| 항목 | 디바이스 A (10.105.194.172) | 디바이스 B (10.24.118.45) |
|---|---|---|
| 프로파일 | p2c4 / c4_safe | p1c4 / c4_safe |
| 카메라 상태 | 동작 (synthetic sync) | **완전 사망** (프레임 0) |
| 오버레이 FPS | 17.5 fps | 17.4 fps |
| 드롭 카운트 | 400 → 758 (2분간) | 228 |
| selfdriveState | enabled / active | **disabled** |
| cameraReady (사이드카) | 동작 중 | **false** |
| c4ReaderPressureRisk | true | true |

---

## 2. 확실한 근거 (로그에서 직접 확인)

### 2.1 디바이스 B — 카메라 프레임 수신 0개 (검은화면 원인)

```json
// drive_diag_export_20260320_071027.json → nativeCameraDiag
"state": "stalling_pkt_20307ms_dec_20307ms",
"packetAgeMs": 21064,
"decodeAgeMs": 21064,
"packetsWindow": 0,
"decodedWindow": 0,
"connectAttempts": 26,
"codecConfigured": false,
"waitingKeyFrame": true,
"currentWidth": 0,
"currentHeight": 0
```

```json
// 같은 파일 → sidecar.cameraRelay.road
"frames": 0,
"lastFrameId": -1,
"nullFrameIdCount": 0,
"lastFrameAgeMs": null,
"rawFrame": {},
"packedMeta": {}
```

**결론**: 사이드카 카메라 릴레이가 프레임을 한 개도 전달하지 못했음. 코덱 초기화가 안 되어 디코딩 자체가 불가능. 26회 연결 시도 후에도 실패. 이것이 "로드카메라 검은화면"의 직접적 원인.

### 2.2 디바이스 B — openpilot 부팅 미완료 상태에서 접속

```json
// drive_diag_export_20260320_071027.json → sidecar health
"cameraReady": false,
"vehicleReady": false,
"fullReady": false,
"selfdriveState": { "enabled": false, "active": false, "engageable": false, "state": "disabled" },
"carState": { "subscribed": true, "alive": true, "isFresh": true },
"controlsState": { "subscribed": true, "alive": true, "isFresh": true }
```

```json
// camera_error_20260320_070956_561.log → 사이드카 health 비교
"carState": { "subscribed": false, "alive": false },
"controlsState": { "subscribed": false, "alive": false }
```

**결론**: 카메라 에러 시점(07:09)에는 carState/controlsState 미구독, 약 1분 뒤 diag export(07:10) 시점에는 구독됨. openpilot이 부팅 중이었고 카메라 파이프라인이 아직 준비되지 않은 상태에서 사이드카가 연결을 시도함.

### 2.3 디바이스 B — 포트 불일치

```
// camera_error_20260320_070956_561.log
"sidecarHealthError": "Connection refused ... port = 33784"
"cameraHealthError": "Connection refused ... port = 33788"
```

**결론**: 앱이 사이드카 health(33784)와 카메라 health(33788)에 접근 시도했으나 connection refused. 사이드카 프로세스는 port 7766에서 동작 중이나 health/camera 전용 포트가 아직 열리지 않음.

### 2.4 디바이스 A — frameId 전부 null

```json
// drive_diag_export_20260320_070447.json → sidecar.cameraRelay.road
"frames": 41,
"lastFrameId": -1,
"nullFrameIdCount": 41,
"rawFrame": {
  "frameId": null,
  "timestampSof": null,
  "timestampEof": null,
  "width": 1344,
  "height": 760,
  "encodeId": 1423
}
```

```json
// 같은 파일 → sidecar.serviceHealth
"roadCameraState": { "frameId": 1425, "isFresh": true },
"modelV2": { "frameId": 1424, "isFresh": true }
```

**결론**: openpilot의 `roadCameraState`에는 frameId 1425가 존재하지만, `livestreamRoadEncodeData` 스트림에서는 41개 프레임 연속 frameId=null. 카메라 프레임 자체는 수신되고 있으나 (1344x760, encodeId 있음), frameId만 누락.

### 2.5 디바이스 A — Synthetic Sync 모드 동작

```json
// drive_diag_export_20260320_070447.json → nativeCameraDiag
"syntheticSyncActive": true,
"syntheticFrameEmits": 1304,
"missingSourceFrameIds": 1333,
"lastSourceFrameId": -1
```

```json
// 같은 파일 → summary.camera
"syncMode": "synthetic"
```

**결론**: frameId null로 인해 정상적인 frame sync 불가 → CarrotLink가 synthetic sync fallback으로 동작. 시간 기반으로 오버레이를 합성하고 있음.

### 2.6 디바이스 A — 자체 진단 힌트 확인

```json
"frameIdRootCauseHint": "roadCameraState.frameId는 있으나 cameraRelay raw frame 샘플과 lastFrameId가 비어 있습니다. relay producer가 받는 frame 객체 경계에서 frameId가 빠지는 쪽이 가장 유력합니다."
```

**결론**: CarrotLink 앱 자체 진단 로직이 이미 문제 지점을 "relay producer 경계"로 좁힘 (단, 이 힌트 자체도 추정임).

### 2.7 디바이스 A — 오버레이 프레임 드롭 누적

```
dropCountTotal: 400 (07:04:47) → 758 (07:06:18)
```

**결론**: 91초 동안 358프레임 추가 드롭 (약 3.9 drops/sec). 오버레이 FPS 17.5는 유지되고 있으나 상당한 프레임 손실.

### 2.8 디바이스 B — FPS 지속 하락 추세

```
// camera_error_20260320_070956_561.log → tmux tail
FPS dropped below 60: 53
FPS dropped below 60: 40
FPS dropped below 60: 43
FPS dropped below 60: 44
FPS dropped below 60: 41
FPS dropped below 60: 41
FPS dropped below 60: 39
FPS dropped below 60: 39
FPS dropped below 60: 41
FPS dropped below 60: 43
FPS dropped below 60: 39
FPS dropped below 60: 41
```

**결론**: openpilot UI FPS가 60 미달 상태가 지속. 초기 53에서 39까지 하락 추세. 단순 순간 스파이크가 아닌 지속적 성능 저하.

### 2.9 디바이스 B — 메모리 지속 증가 (5분간 스냅샷)

```
프로세스        시작      →   종료      (증가량)
ui            364.2MB   →  379.5MB   (+15.3MB, ~3MB/분)
card           93.0MB   →  114.3MB   (+21.3MB, ~4.3MB/분)
controlsd      89.7MB   →  103.9MB   (+14.2MB, ~2.8MB/분)
selfdrived     88.3MB   →  104.6MB   (+16.3MB, ~3.3MB/분)
modeld        353.0MB   →  364.8MB   (+11.8MB, ~2.4MB/분)
plannerd       91.6MB   →  105.1MB   (+13.5MB, ~2.7MB/분)
radard         87.5MB   →   97.9MB   (+10.4MB, ~2.1MB/분)
carrot_man     88.9MB   →  102.9MB   (+14.0MB, ~2.8MB/분)
```

**결론**: 거의 모든 주요 프로세스에서 메모리가 단조 증가. 5분간 한 번도 줄지 않음. 단, 이것이 부팅 초기 워밍업인지 진짜 누수인지는 이 구간만으로 단정 불가.

### 2.10 기타 확인 사항

```
// camera_error_20260320_070956_561.log
"skipping model eval. Dropped 209 frames"   ← 모델 초기화 중 209프레임 드롭
"skipping model eval. Dropped 29 frames"
"skipping model eval. Dropped 3 frames"     ← 점차 안정화
"time jumped: 1773958066... 1752259975..."   ← 시스템 시간 점프 감지
```

**결론**: openpilot 부팅 초기에 모델 평가가 밀리면서 대량 프레임 드롭. 시간 점프는 NTP 동기화로 추정.

---

## 3. 추측 (로그에서 직접 증명되지 않음)

### 3.1 "frameId null의 원인이 C4 encoderd" — 추측 (유력)

**추론 근거**:
- openpilot `roadCameraState`에는 frameId 있음 (확실)
- `livestreamRoadEncodeData` 스트림에는 frameId null (확실)
- C4 코드의 `system/loggerd/encoder/encoder.cc`에서 `edata.setFrameId(extra.frame_id)` 설정
- `VisionIpcBufExtra.frame_id`가 livestream 인코더 경로에서 제대로 채워지지 않을 가능성

**불확실한 점**:
- sidecar Python 측의 cereal 디시리얼라이제이션 문제일 수도 있음
- capnp 스키마 버전 불일치 가능성도 존재
- livestream 인코더가 일반 인코더와 다른 `VisionIpcBufExtra` 경로를 탈 수 있음

**확인 방법**: C4 디바이스에서 `livestreamRoadEncodeData` 메시지를 직접 덤프하여 cereal 레벨에서 frameId 필드 확인

### 3.2 "메모리 증가가 그래픽 사망을 유발" — 추측

**추론 근거**:
- 메모리 단조 증가 (확실)
- FPS 하락 추세 (확실)
- C4 코드의 `application.py`에서 `self._textures` dict가 unbounded (코드상 확인)
- `cameraview.py`의 `self.egl_images` dict가 프레임 인덱스마다 증가 (코드상 확인)

**불확실한 점**:
- 5분 구간의 메모리 증가가 부팅 초기 워밍업(정상)일 가능성
- 실제 OOM kill이 발생했다는 증거 없음 (dmesg/logcat 미확인)
- GPU 메모리 고갈, EGL context loss 등 다른 원인 가능
- ui 외에 card, controlsd 등도 동일하게 증가하므로 UI 텍스처만의 문제가 아닐 수 있음

**확인 방법**:
- 장시간(30분+) PROC_MEM 로그로 메모리 증가 추세 확인 (워밍업 후 안정화 여부)
- `dmesg | grep -i oom` 또는 `logcat | grep -i kill`로 OOM kill 이력 확인
- GPU 메모리 사용량 모니터링

### 3.3 "시간 지나니 살아났다 = openpilot 부팅 완료" — 추측

**추론 근거**:
- 07:09 시점에 selfdriveState=disabled, carState 미구독 (확실)
- 07:10 시점에 carState 구독됨, alive, fresh (확실)
- 부팅 초기 "skipping model eval. Dropped 209 frames" 등 초기화 과정 확인 (확실)

**불확실한 점**:
- 유저가 앱을 재시작했을 수 있음
- 사이드카가 자동 재연결되면서 살아났을 수 있음
- openpilot 자체가 프로세스를 재시작했을 수 있음
- "살아났다"가 정확히 어떤 시점인지 알 수 없음 (로그 구간 이후)

**확인 방법**: 유저에게 "앱을 재시작했는지, 아니면 그냥 기다렸더니 된 건지" 확인

### 3.4 "그래픽 끊김 = synthetic sync 때문" — 부분 추측

**추론 근거**:
- synthetic sync 모드 동작 중 (확실)
- 프레임 드롭 358개/91초 (확실)
- synthetic sync는 시간 기반이므로 정확한 frame 매칭 불가 (설계상 사실)

**불확실한 점**:
- 유저가 느끼는 "끊김"이 오버레이 sync 문제인지, 카메라 프레임 자체의 끊김인지, UI FPS(39)로 인한 것인지 구분 불가
- 오버레이 FPS 17.5는 합리적인 수준이므로 오버레이 자체는 비교적 매끄러울 수 있음
- C4 디바이스의 WiFi 상태나 네트워크 지연이 원인일 수도 있음

**확인 방법**: 오버레이 없이 카메라만 표시했을 때도 끊기는지 확인

### 3.5 "c4ReaderPressureRisk가 실제 성능 문제를 반영" — 오해 소지

**사실**: 코드상 `repoFlavor == 'c4'`이면 무조건 true
```dart
// live_drive_canvas_diag_logging_components.dart:564
'c4ReaderPressureRisk': repoFlavor == SidecarService.repoFlavorC4,
```

**결론**: 실제 리소스 압력 측정이 아닌 정적 플래그. C4 디바이스라는 것 자체가 리소스 제약이 있다는 표식이지만, 현재 실시간 상태를 반영하지는 않음.

---

## 4. C3 비교 분석 (E:\Carrot\logs\A)

> C3 디바이스 10.246.207.166의 `drive_diag_export_20260320_071027.json` (실제 캡처 2026-03-19 20:05)

### C3 vs C4 비교표

| 항목 | C3 (A) - 10.246.207.166 | C4 (A) - 10.105.194.172 | C4 (B) - 10.24.118.45 |
|---|---|---|---|
| **frameId** | **null** (전부) | **null** (41개 전부) | 데이터 없음 |
| codec | `avc1.640032` | `avc1.640020` | - |
| 해상도 | 1928x1208 | 1344x760 | 1928x1208 |
| syntheticSync | **true** | **true** | - |
| 사이드카 phase | **starting** (복구 중) | **running** (정상) | running |
| serviceHealth | **비어있음** `{}` | **상세 데이터** | 상세 데이터 |
| cameraRelay 통계 | **전부 null** | frames=41, 상세 | frames=0 |
| 오버레이 FPS | **8.12** | **17.5** | 17.4 |
| 드롭 | 27 | 400~758 | 228 |
| 카메라 연결 | 1회 성공→5초 뒤 끊김 | 6회 성공 유지 | 26회 실패 |

### 핵심 발견

1. **frameId null은 C3/C4 공통 문제**: C3에서도 `parsedFrameIdRaw: "null"`, `syntheticSyncActive: true` 확인. C4 encoderd만의 문제가 아닌 사이드카 파싱 버그 (→ 5.1에서 수정 완료).

2. **C3 사이드카가 더 불안정**: 5초 로그 전체가 `phase: "starting"`, serviceHealth 비어있음. 사이드카 재배포/복구 중이었음.

3. **C3 오버레이 FPS가 C4보다 오히려 낮음**: 8.12 vs 17.5. 단, C3는 사이드카 복구 중이므로 정상 상태 비교 아님.

4. **C3도 4초 후 카메라 소켓 끊김**: 사이드카 재시작 시 port 7766 일시 닫힘.

5. **C3 frameIdRootCauseHint**: `"camera service 자체에서 frameId가 비어 들어올 가능성이 있습니다."` — C4보다 덜 구체적 (serviceHealth가 비어있어서).

### 비교 불가능한 항목

- **메모리 누수**: C3 로그에 PROC_MEM 데이터 없음
- **FPS 추세**: C3 로그 5초, UI FPS 데이터 없음
- **장시간 안정성**: C3 로그 구간이 너무 짧음

---

## 5. 근거 수준 요약

### 확실 (Confirmed)

| # | 결론 | 로그 근거 |
|---|---|---|
| 1 | 검은화면 = 카메라 릴레이 프레임 0개 | cameraRelay.road.frames=0, codecConfigured=false |
| 2 | openpilot 부팅 미완료 상태에서 접속 | selfdriveState=disabled, carState 미구독 |
| 3 | frameId가 null로 전달됨 (41개 연속) | nullFrameIdCount=41, rawFrame.frameId=null |
| 4 | roadCameraState에는 frameId 정상 존재 | roadCameraState.frameId=1425 |
| 5 | synthetic sync fallback 동작 중 | syntheticSyncActive=true, syncMode=synthetic |
| 6 | FPS 하락 추세 (53→39) | PROC_MEM 로그 12회 연속 60미만 |
| 7 | 메모리 단조 증가 (5분간) | PROC_MEM 스냅샷 6회 비교 |
| 8 | 오버레이 프레임 드롭 누적 | dropCountTotal 400→758 |

### 확인됨 — 근본 원인 (Root Cause Found)

| # | 결론 | 근거 |
|---|---|---|
| 1 | **frameId null = 사이드카 파싱 버그** | capnp 스키마: `EncodeData.idx.frameId`에 있으나, sidecar.py가 `frame.frameId` (top-level)을 읽어서 항상 null. C3/C4 로그 비교로 공통 문제 확인 |

> **상세**: `EncodeData` 구조는 `idx @0 :EncodeIndex` 안에 `frameId @0 :UInt32`를 가짐.
> 사이드카 `_build_frame_sample()`에서 `getattr(frame, "frameId", None)` → None (top-level에 없음).
> 같은 함수에서 `getattr(idx, "encodeId", None)` 등은 올바르게 idx에서 읽지만 frameId만 누락.
> C3 로그(`E:\Carrot\logs\A`)에서도 동일한 `frameId=null` 확인 → C4 고유가 아닌 공통 버그.

### 추측 — 유력 (Likely)

| # | 추측 | 근거 | 미확인 |
|---|---|---|---|
| 1 | 부팅 완료 후 카메라 자연 복구 | 1분 사이에 서비스 구독 상태 변화 확인 | 앱 재시작 가능성 |

### 추측 — 가능성 (Possible)

| # | 추측 | 근거 | 미확인 |
|---|---|---|---|
| 2 | 메모리 누수 → 그래픽 사망 | 단조 증가 + FPS 하락 상관관계 | OOM kill 증거 없음, 워밍업 가능성 |
| 3 | 끊김 = synthetic sync 한계 | frame sync 없이 시간 기반 합성 | 네트워크/카메라/UI 복합 가능성 |
| 4 | 텍스처/EGL 캐시 unbounded 성장 | 코드 리뷰로 확인 | 실제 메모리 기여도 미측정 |

---

## 5. 적용된 수정 사항 (2026-03-20)

> 아래 수정은 모두 `assets/sidecar/sidecar.py`에 적용됨 (c3/c4 openpilot 브랜치 미수정).

### 5.1 [핵심] idx.frameId fallback 추가

**파일**: `assets/sidecar/sidecar.py` — `_build_frame_sample()`

**문제**: `frame.frameId`를 읽었으나, `EncodeData`에는 top-level `frameId`가 없음. `EncodeIndex` (`frame.idx`) 안에 있음.

**수정**: `idx` 파싱 블록에서 `frame_id`가 None이면 `idx.frameId`로 fallback:

```python
if frame_id is None:
    frame_id = _safe_int(getattr(idx, "frameId", None))
```

**기대 효과**: C3/C4 모두 frameId가 정상 전달되어 synthetic sync 대신 정상 frame sync 동작. 오버레이 끊김 대폭 감소.

### 5.2 roadCameraState.frameId 2차 fallback

**파일**: `assets/sidecar/sidecar.py` — `CameraRelayHub`, `SidecarBroker._refresh_sm_if_needed()`

**문제**: `idx.frameId`도 0이거나 없을 가능성에 대한 안전망 부재.

**수정**:
1. `CameraRelayHub`에 `_sm_frame_id` dict와 `update_sm_frame_id()` 메서드 추가
2. `SidecarBroker._refresh_sm_if_needed()`에서 SM 업데이트 시 `roadCameraState.frameId` / `wideRoadCameraState.frameId`를 허브에 push
3. `_camera_producer_loop`에서 frameId가 null이면 SM의 최신 frameId로 대체

**기대 효과**: idx에서도 frameId를 얻지 못하는 극단적 상황에서도 카메라 프레임에 frameId 삽입.

### 5.3 카메라 릴레이 부트 게이팅

**파일**: `assets/sidecar/sidecar.py` — `CameraRelayHub._camera_producer_loop()`

**문제**: openpilot 부팅 미완료 상태에서 카메라 릴레이가 소켓을 열고 빈 스트림 전달. 앱이 26회 무의미한 연결 시도.

**수정**: `_camera_service_ready()` 메서드 추가. `roadCameraState` / `wideRoadCameraState`의 SM frameId가 유효해질 때까지 카메라 프로듀서 루프 대기 (0.3초 간격 폴링).

```python
def _camera_service_ready(self, camera: str) -> bool:
    fid = self._sm_frame_id.get(camera)
    return fid is not None and fid > 0
```

**기대 효과**: openpilot 카메라 파이프라인 준비 전에는 프레임 전달 안 함. "검은화면 후 자동 복구" 대신 "준비되면 즉시 시작".

---

## 6. 잔존 확인 사항

### 유저 확인 필요

1. **유저 확인**: "시간 지나니 살아났다"가 앱 재시작 없이 자동 복구였는지 확인

### C4 openpilot 측 (향후 검토)

2. **장시간 메모리 로그**: 30분+ 구간의 PROC_MEM을 수집하여 워밍업 후 안정화 vs 지속 증가 판별
3. **C4 UI 메모리 관리**: `application.py`의 텍스처 캐시에 eviction 정책, `cameraview.py`의 `egl_images` dict 정리 로직 검토

---

## 6. 참조 파일 인덱스

### 로그 파일

| 파일 | 내용 |
|---|---|
| `E:\Carrot\logs\camera_error_20260320_070956_561.log` | 디바이스 B 카메라 에러 + tmux 로그 350줄 |
| `E:\Carrot\logs\drive_diag_export_20260320_070447.json` | 디바이스 A 진단 스냅샷 (07:04) |
| `E:\Carrot\logs\drive_diag_export_20260320_070618.json` | 디바이스 A 진단 스냅샷 (07:06) |
| `E:\Carrot\logs\drive_diag_export_20260320_071027.json` | 디바이스 B 진단 스냅샷 (07:10) |
| `E:\Carrot\logs\drive_diag_20260320_070333.ndjson` | 디바이스 A 실시간 진단 이벤트 로그 (대용량) |

### CarrotLink 관련 코드

| 파일 | 역할 |
|---|---|
| `lib/screens/drive/live_drive_canvas_camera_components.dart` | 카메라 attach, synthetic sync, diag recovery |
| `lib/screens/drive/live_drive_canvas_diag_logging_components.dart` | 진단 로깅, c4ReaderPressureRisk 플래그 |
| `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart` | 프레임 동기화, stale 감지 |
| `assets/sidecar/sidecar.py` | 사이드카 카메라 릴레이, frameId 처리 |

### C4 관련 코드

| 파일 | 역할 |
|---|---|
| `system/loggerd/encoder/encoder.cc` | frameId 설정 (`edata.setFrameId(extra.frame_id)`) |
| `system/loggerd/encoderd.cc` | 인코더 스레드, frame ID 불일치 감지 |
| `system/ui/lib/application.py` | UI FPS 관리, 텍스처 캐시 (unbounded) |
| `selfdrive/ui/onroad/cameraview.py` | EGL 이미지 관리 (unbounded dict) |
