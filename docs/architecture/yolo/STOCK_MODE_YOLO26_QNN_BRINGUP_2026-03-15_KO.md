# CarrotLink Stock Mode YOLO26 QNN Bring-up Notes (2026-03-15)

## 2026-03-16 최신 메모

- 앱 쪽 QNN 슬롯 연결은 끝났다.
  - Flutter selector: `yolo26n_qnn`, `yolo26s_qnn`
  - native model catalog도 같은 이름으로 lookup 한다.
- route playback 경로는 실제로 native `runYoloDebugVideoFrame(...)`까지 들어가는 것이 로그로 확인됐다.
- generic `.pte`를 `executorch_qnn` backend로 playback에 태우는 경우는 여전히 의도적으로 blocker 처리된다.
  - 대표 blocker: `qnn_model_not_lowered`
- 현재 앱 번들에는 generic `.pte`만 있고 QNN-lowered `.pte`는 아직 없다.
  - 있음: `assets/models/yolo26n.pte`, `assets/models/yolo26s.pte`
  - 없음: `assets/models/yolo26n_qnn.pte`, `assets/models/yolo26s_qnn.pte`
- GitHub Actions 기반 QNN export workflow를 `dev`에 올려두었고, 2026-03-16 기준 최근 run #5가 `in_progress` 상태다.
  - workflow: `.github/workflows/export-yolo-qnn.yml`
  - 최신 handoff: `docs/architecture/yolo/STOCK_MODE_YOLO26_PROGRESS_HANDOFF_2026-03-16_KO.md`

## 목적

- 최종 목표 runtime은 `YOLO26n + ExecuTorch + QNN backend`다.
- 현재 앱은 generic ExecuTorch AAR 기준으로 동작한다.
- 따라서 QNN bring-up은 `로컬 ExecuTorch AAR + QNN runtime libs`를 앱에 실제 패키징하는 단계가 먼저다.

## 현재 앱 상태

- 기본 Android 의존성은 `org.pytorch:executorch-android:1.1.0`이다.
- 이 경로는 generic ExecuTorch bring-up 기준이다.
- `runtimeBackend=executorch_qnn`은 목표 문자열이지만, QNN native가 없으면 런타임은 `backend_unavailable`로 fail-open 된다.

## 로컬 AAR 경로

앱은 이제 아래 경로를 지원한다.

- local AAR 파일:
  - `android/app/libs/executorch.aar`
- 활성화 build flag:
  - `-PuseLocalAar=true`

local AAR는 두 경로 중 하나로 준비할 수 있다.

- 공식 Android AAR 문서의 backend별 AAR
- Qualcomm backend 문서 기준 source build 결과물

예:

```powershell
cd E:\Carrot\CarrotLink\android
.\gradlew.bat :app:assembleDebug
```

동작 규칙:

- `android/app/libs/executorch.aar` 가 있으면 기본으로 local AAR 모드 사용
- 강제로 Maven 경로를 쓰고 싶으면:
  - `-PuseLocalAar=false`
- local AAR 파일이 없으면 Maven `executorch-android:1.1.0` 사용

## 로컬 QNN SDK 경로

local AAR 모드일 때는 QNN SDK도 같이 찾는다.

- Gradle property:
  - `-PqnnSdkRoot=...`
- 환경변수:
  - `QNN_SDK_ROOT`
- 로컬 기본값:
  - `E:\Carrot\yolo\2.32.6.250402`

현재 앱은 위 SDK에서 필요한 QNN 파일을 자동으로 패키징한다.

- Android runtime lib:
  - `libQnnHtp.so`
  - `libQnnSystem.so`
  - `libQnnHtpPrepare.so`
  - `libQnnHtpNetRunExtensions.so`
  - `libQnnHtpV##Stub.so`
- Hexagon skel asset:
  - `libQnnHtpV68Skel.so`
  - `libQnnHtpV69Skel.so`
  - `libQnnHtpV73Skel.so`
  - `libQnnHtpV75Skel.so`
  - `libQnnHtpV79Skel.so`

빌드 시점에는 아래 generated 경로로 동기화된다.

- JNI libs:
  - `android/app/build/generated/qnnJni/main/arm64-v8a`
- skel assets:
  - `android/app/build/generated/qnnAssets/main/qnn/skels`

## QNN runtime libs

QNN backend가 실제로 동작하려면 APK 안에 아래 두 종류가 같이 들어가야 한다.

- ExecuTorch QNN bridge
  - 예: `libqnn_executorch_backend.so`
- QNN runtime lib
  - 예: `libQnnHtp.so`, `libQnnSystem.so`, 기타 `libQnn*.so`
- QNN skel asset
  - 예: `libQnnHtpV79Skel.so`

런타임은 현재 `nativeLibraryDir` 안의 `.so` 목록을 보고 아래처럼 판정한다.

- bridge와 runtime lib, stub, skel asset가 모두 있으면 `backendAvailable=true`
- bridge가 없으면:
  - Maven mode: `qnn_backend_not_packaged`
  - local AAR mode: `qnn_backend_bridge_missing`
- `libQnnHtp.so`가 없으면:
  - `qnn_htp_runtime_missing`
- `libQnnSystem.so`가 없으면:
  - `qnn_system_runtime_missing`
- `libQnnHtpV##Stub.so`가 없으면:
  - `qnn_htp_stub_missing`
- skel asset가 없으면:
  - `qnn_skel_assets_missing`
- runtime dir 준비/환경 변수 구성이 실패하면:
  - `backend_environment_unavailable`
  - `qnn_runtime_dir_unavailable`
  - `qnn_skel_extract_failed`
  - `qnn_env_config_failed`

## 개발자 도구에서 확인할 값

- `backend`
- `backendAvailable`
- `backendPackaging`
- `backendReason`
- `backendNativeLibDir`
- `backendNativeLibs`
- `backendAssetFiles`
- `backendRuntimeDir`
- `backendEnvReady`

정상적인 QNN bring-up 직전/직후 기대값:

- local AAR만 있고 QNN bridge 없음
  - `backendPackaging=local_aar`
  - `backendReason=qnn_backend_bridge_missing`
- local AAR + QNN SDK sync 전
  - `backendPackaging=local_aar`
  - `backendReason=qnn_htp_runtime_missing` 또는 `qnn_system_runtime_missing`
- local AAR + QNN SDK sync 후
  - `backendPackaging=local_aar`
  - `backendAvailable=true`
- module load 전 환경 준비 단계
  - `backendRuntimeDir` 채워짐
  - `backendEnvReady=true`

## 현재 단계의 의미

- 지금 코드 변경은 QNN을 완성한 것이 아니다.
- QNN bring-up을 위한 build/runtime slot과 local SDK packaging 경로를 프로젝트에 먼저 만든 단계다.
- 다음 단계는:
  1. QNN-enabled ExecuTorch AAR 유지/검증
  2. 실제 기기에서 `backendAvailable=true`, `backendEnvReady=true` 확인
  3. 그 뒤에 first inference 확인
  4. 마지막으로 QNN-lowered model 호환성 확인

## 공식 문서 참고

- Android AAR 사용:
  - [Using ExecuTorch on Android](https://docs.pytorch.org/executorch/stable/using-executorch-android.html)
- Qualcomm backend:
  - [Qualcomm AI Engine Backend](https://docs.pytorch.org/executorch/stable/backends-qualcomm.html)
