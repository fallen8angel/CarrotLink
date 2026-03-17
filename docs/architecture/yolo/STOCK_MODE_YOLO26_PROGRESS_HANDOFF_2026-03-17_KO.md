# CarrotLink Stock Mode YOLO26 진행상황 / Handoff (2026-03-17) — LiteRT 전환

최종 분석일: 2026-03-17
최종 업데이트: 2026-03-17
대상 경로: `E:\Carrot\CarrotLink`

이 문서는 ExecuTorch+QNN 경로를 완전히 포기하고 **LiteRT + GPU (Adreno OpenCL)** 로 전환하는 시점을 기록한 handoff 문서다.
이전 QNN bringup 내역은 `STOCK_MODE_YOLO26_QNN_BRINGUP_2026-03-15_KO.md` 참조.

관련 문서:

- `docs/architecture/yolo/STOCK_MODE_YOLO26_OBJECT_DETECTION_FEASIBILITY_2026-03-10_KO.md`
- `docs/architecture/yolo/STOCK_MODE_YOLO26_INTEGRATION_PLAN_2026-03-10_KO.md`
- `docs/architecture/yolo/STOCK_MODE_YOLO26_QNN_BRINGUP_2026-03-15_KO.md`
- `docs/architecture/yolo/STOCK_MODE_YOLO26_PROGRESS_HANDOFF_2026-03-16_KO.md`

---

## 1. QNN HTP 포기 — 최종 확정된 근본 원인

### 1.1 실패 증상

```
QnnDsp <E> Failed to create transport for device, error: 4000
QnnDsp <E> Failed to load skel, error: 4000
QnnDsp <E> Transport layer setup failed: 14001
```

앱 측 blocker: `qnn_dsp_transport_failed`

### 1.2 실제 원인 (확정)

`/dev/fastrpc-cdsp` 는 Samsung Galaxy SM8750 기기에서 아래와 같다.

```
crw-rw-r--  owner=system(1000)  group=system(1000)
```

앱 프로세스:

```
UID=10848  GID=10848  supplementary groups: 1077 1079 3003 9997 20848 50848
```

- 앱 UID/GID는 `system(1000)` 그룹에 속하지 않는다.
- `crw-rw-r--` 기준 others는 read-only다.
- FastRPC는 `/dev/fastrpc-cdsp` 에 write+ioctl이 필요하다.
- 따라서 first `forward()` 시점에 device node open이 막히고, SELinux 없이 순수 Unix DAC 수준에서 차단된다.
- SELinux `avc:` denial은 발견되지 않았다. 문제는 SELinux 이전에 DAC 계층에서 종결된다.

### 1.3 결론

**앱 코드 레벨에서는 해결 불가능하다.**
system 그룹 멤버십이나 `/dev/fastrpc-cdsp` 권한을 앱에서 바꿀 수 없다.
루팅, 커스텀 ROM, OEM 특권 앱 등의 조건이 없으면 일반 서드파티 앱은 Snapdragon DSP(HTP)를 직접 열 수 없다.

이는 **ExecuTorch QNN** 뿐만 아니라, LiteRT + `com.qualcomm.qti:qnn-litert-delegate`, SNPE 등 **FastRPC 경로를 쓰는 모든 방법에 공통 적용된다.**

---

## 2. 새로운 방향: LiteRT + GPU (Adreno OpenCL)

### 2.1 선택 근거

| 방법 | 권한 | 속도 | 결론 |
|------|------|------|------|
| ExecuTorch QNN (HTP/DSP) | `/dev/fastrpc-cdsp` write 필요 → **차단** | ~3-8ms | **포기** |
| LiteRT + qnn-litert-delegate | 동일 fastrpc 경로 → **차단** | ~3-8ms | **포기** |
| NNAPI | Android 15 deprecated, Samsung HAL CPU fallback | slow | 사용 안 함 |
| Samsung Neural SDK | 서드파티 배포 정책 변경으로 미제공 | — | 사용 불가 |
| **LiteRT + GpuDelegate (OpenCL)** | 일반 GPU shader 권한만 필요 → **허용** | ~15-25ms | **선택** |
| LiteRT CPU (XNNPACK) | 권한 불요 | ~100-200ms | CPU 폴백 |

### 2.2 LiteRT GPU (OpenCL) 동작 원리

- **Adreno GPU** (Snapdragon 내 GPU 코어)를 OpenCL로 활용한다.
- `/dev/fastrpc-cdsp` 와 무관하다. OpenCL은 일반 GPU 드라이버 경로다.
- 서드파티 앱 권한으로 사용 가능하다.
- SD888 (Adreno 660) 이상에서 TFLite/LiteRT FP16 모델 실용 속도가 나온다.

### 2.3 의존성

```kotlin
// build.gradle.kts
implementation("com.google.ai.edge.litert:litert:2.1.3")
implementation("com.google.ai.edge.litert:litert-gpu:1.4.2")
```

- ExecuTorch Maven 의존성(`org.pytorch:executorch-android:1.1.0`)은 제거 예정이나,
  로컬 AAR 경로와 XNNPACK 폴백이 필요한 동안은 유지할 수 있다.
- QNN .so 파일 sync task (`syncQnnJniLibs`, `syncQnnSkelAssets`)는 더 이상 필요 없다.

### 2.4 모델 형식 변경

| 항목 | 이전 | 이후 |
|------|------|------|
| 형식 | `.pte` (ExecuTorch) | `.tflite` (LiteRT) |
| 정밀도 | FP32 / QNN INT8 | FP16 (GPU), INT8 (HTP, 미래) |
| export | `executorch export` | `yolo export format=tflite half=True` |
| 입력 | `[1, 3, 416, 416]` NCHW | `[1, 416, 416, 3]` NHWC |
| 출력 | `[1, 84, 3549]` | `[1, 84, 3549]` (동일) |

모델 export 커맨드:

```bash
yolo export model=yolo26n.pt format=tflite imgsz=416 half=True   # GPU용 FP16
yolo export model=yolo26n.pt format=tflite imgsz=416 int8=True   # HTP용 INT8 (미래)
```

---

## 3. 지원 기기 정책

### 3.1 Galaxy + Snapdragon 단독 타게팅

현재 CarrotLink는 **Galaxy + Snapdragon** 조합만 지원한다.
Exynos Galaxy, 타 OEM Android는 현재 범위 밖이다.

### 3.2 최소/권장 스펙

| 기준 | SoC | GPU | 비고 |
|------|-----|-----|------|
| 최소 | Snapdragon 888 | Adreno 660 | Galaxy S21 시리즈 (2021) |
| 권장 | Snapdragon 8 Gen 2 이상 | Adreno 740+ | Galaxy S23 이상 (2023) |
| 타깃 | Snapdragon 8 Elite (SM8750) | Adreno 830 | Galaxy Z Fold 7, S25 시리즈 |

- SD888 미만은 LiteRT GPU 실용 속도가 보장되지 않아 CPU 폴백 기본값 적용.
- SD8 Gen2 이상은 LiteRT GPU로 yolo26n FP16 기준 15-25ms 이내 기대.

### 3.3 런타임 백엔드 우선순위 (새 정책)

```
litert_gpu  →  GPU 미지원 기기에서 litert_cpu 자동 폴백
```

- `litert_gpu`: GpuDelegate(OpenCL) 사용. `CompatibilityList`로 GPU 지원 여부 확인 후 초기화.
- `litert_cpu`: Interpreter + XNNPACK (기본 스레드풀).
- QNN 경로 (`executorch_qnn`, `qnn-litert-delegate`)는 더 이상 시도하지 않는다.
- `executorch_xnnpack`은 구 ExecuTorch 런타임과 함께 deprecated 경로로 유지.

---

## 4. 새 구현 구조

### 4.1 추가된 파일

| 파일 | 역할 |
|------|------|
| `NativeDriveLiteRtRuntime.kt` | LiteRT Interpreter 기반 새 런타임. `NativeDriveYoloRuntime` 구현. |

### 4.2 변경된 파일

| 파일 | 변경 내용 |
|------|-----------|
| `android/app/build.gradle.kts` | `litert:2.1.3`, `litert-gpu:1.4.2` 추가 |
| `NativeDriveYoloModelCatalog.kt` | `litert26n`, `litert26s` family 추가. `.tflite` 확장자 처리. |
| `NativeDriveVideoPlugin.kt` | `createYoloRuntime()` factory 추가. `litert_*` 백엔드 시 `NativeDriveLiteRtRuntime` 사용. |

### 4.3 deprecated 예정

| 파일 | 이유 |
|------|------|
| `NativeDriveQnnRuntimeFiles.kt` | QNN runtime 준비 로직. QNN 포기로 더 이상 필요 없음. |
| `NativeDriveExecuTorchRuntime.kt` | 점진적 대체 예정. `executorch_xnnpack` CPU 경로만 잔류 가능. |

---

## 5. 남은 작업 우선순위

### 5.1 즉시 (이번 세션)

1. [x] `NativeDriveLiteRtRuntime.kt` 신규 작성 (LiteRT Interpreter + GpuDelegate)
2. [x] `build.gradle.kts` LiteRT 의존성 추가
3. [x] `NativeDriveYoloModelCatalog.kt` `.tflite` family 추가
4. [x] `NativeDriveVideoPlugin.kt` factory 패턴 적용

### 5.2 다음 세션

1. `.tflite` 모델 파일 export 및 `assets/models/` 에 추가
   - `yolo26n_fp16.tflite` (GPU용)
   - `yolo26n.tflite` (범용 폴백)
2. Flutter 정책 계층 업데이트
   - `yolo_runtime_policy.dart`: `litert_gpu` / `litert_cpu` 를 새 기본 백엔드로
   - `yolo_device_profile_service.dart`: SoC 감지 기준 `litert_gpu` 또는 `litert_cpu` 추천
3. `yolo_runtime_capability_store.dart`: `litert_*` blocker/fallback 정책 추가
4. GitHub Actions: `.tflite` export workflow 추가

### 5.3 추후

1. 실기기 GPU 추론 속도 벤치마크 (SD8 Elite 기준 목표 < 25ms)
2. INT8 모델 (`yolo26n_int8.tflite`) export 및 검증 (HTP가 허용되는 환경 대비)
3. `NativeDriveExecuTorchRuntime` 완전 제거 (LiteRT 안정화 후)
4. `NativeDriveQnnRuntimeFiles` 완전 제거

---

## 6. 빠른 확인 포인트

재개 시 아래만 먼저 보면 된다.

- **런타임 (신규)**
  - `NativeDriveLiteRtRuntime.kt` — LiteRT GPU/CPU 런타임
- **런타임 (구, 유지)**
  - `NativeDriveExecuTorchRuntime.kt` — XNNPACK 경로 잔류
- **정책**
  - `lib/features/yolo/application/yolo_runtime_policy.dart`
  - `lib/features/yolo/application/yolo_device_profile_service.dart`
- **모델/variant**
  - `NativeDriveYoloModelCatalog.kt` — `litert26n`, `litert26s` 추가됨
- **빌드**
  - `android/app/build.gradle.kts` — LiteRT 의존성

---

## 7. 요약

한 줄 요약:

- **QNN HTP는 `/dev/fastrpc-cdsp` Unix DAC 권한으로 앱 수준에서 영구 차단** → 포기.
- **LiteRT + GpuDelegate(OpenCL)** 로 전환: Adreno GPU는 일반 앱 권한으로 접근 가능.
- 모델 형식: `.pte` → `.tflite` (FP16).
- 지원 기기: Galaxy + Snapdragon SD888 최소, SD8 Gen2 권장.
- 런타임 백엔드: `litert_gpu` → `litert_cpu` 폴백.
