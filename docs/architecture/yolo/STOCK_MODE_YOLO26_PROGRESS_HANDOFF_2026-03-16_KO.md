# CarrotLink Stock Mode YOLO26 진행상황 / Handoff (2026-03-16)

최종 분석일: 2026-03-16  
최종 업데이트: 2026-03-16  
대상 경로: `E:\Carrot\CarrotLink`

이 문서는 2026-03-16 기준 YOLO/QNN 작업의 실제 상태, 검증된 사실, 남은 작업, 다음 작업 순서를 빠르게 이어받기 위한 최신 handoff 문서다.

관련 문서:

- `docs/architecture/yolo/STOCK_MODE_YOLO26_QNN_BRINGUP_2026-03-15_KO.md`
- `docs/architecture/yolo/STOCK_MODE_YOLO_DEVELOPER_PLAYBACK_2026-03-15_KO.md`
- `docs/architecture/yolo/STOCK_MODE_YOLO26_PROGRESS_HANDOFF_2026-03-10_KO.md`

## 1. 한눈에 보는 현재 상태

진행률을 지금 기준으로 다시 잡으면 아래처럼 보는 게 맞다.

- generic ExecuTorch bring-up / playback 진단 가시화: 약 `80%`
- 실제 QNN-lowered model export + asset 연결 + 기기 inference 검증: 약 `45~50%`

이미 확인된 것:

- route 로그 playback 경로는 실제로 native까지 들어간다.
  - `NativeDriveVideoPlugin.runYoloDebugVideoFrame(...)` 호출 로그로 확인했다.
- playback 상태를 화면 우측 상단 배지로 바로 읽을 수 있다.
  - `QNN 변환 필요`
  - `모델 파일 없음`
  - `실행 확인`
  - `QNN 검증 완료`
- 앱의 모델 selector / native catalog에는 QNN 슬롯이 실제로 연결되어 있다.
  - `yolo26n_qnn`
  - `yolo26s_qnn`
- 현재 앱 번들에는 generic `.pte`만 있다.
  - `assets/models/yolo26n.pte`
  - `assets/models/yolo26s.pte`
- 현재 앱 번들에는 QNN-lowered `.pte`가 없다.
  - `assets/models/yolo26n_qnn.pte` 없음
  - `assets/models/yolo26s_qnn.pte` 없음
- GitHub Actions 기반 QNN export workflow를 repo에 올렸고 `dev` 브랜치에서 수동 실행 가능하다.
  - workflow: `.github/workflows/export-yolo-qnn.yml`
  - helper: `scripts/build_executorch_qnn_host.sh`
  - helper: `scripts/export_yolo_qnn.py`

아직 안 된 것:

- `yolo26n_qnn.pte`, `yolo26s_qnn.pte` 실물 생성
- 생성된 QNN-lowered asset을 앱 번들에 넣고 기기에서 first inference 확인
- QNN-lowered model 기준 `parsedDetectionCount > 0` 또는 zero-detection 원인 분리

## 2. 2026-03-16 기준으로 확인된 사실

### 2.1 developer playback 경로

다음은 실제 로그로 확인된 사실이다.

- route playback을 시작하면 `runYoloDebugVideoFrame` 호출이 주기적으로 올라간다.
- generic 모델(`yolo26s`) + `executorch_qnn` 조합은 playback에서 의도적으로 막힌다.
  - blocker: `offline_video_frame_qnn_model_blocked`
  - 이유: `qnn_model_not_lowered`
- 즉 이전에 "안 보인다" 문제는 frame sync나 overlay draw보다는 `QNN-lowered model 부재`가 핵심 원인이었다.

### 2.2 QNN 슬롯 / asset naming

현재 코드 기준 QNN variant naming은 확정된 상태다.

- Flutter selector wire value
  - `yolo26n_qnn`
  - `yolo26s_qnn`
- native model catalog 후보 basename
  - `yolo26n_qnn.pte`
  - `yolo26s_qnn.pte`
  - 호환 alias 몇 개를 더 허용하지만, 우선 표준 파일명은 위 두 개다.

즉 앞으로 artifact를 앱에 넣을 때는 아래 이름을 우선 기준으로 쓰면 된다.

- `assets/models/yolo26n_qnn.pte`
- `assets/models/yolo26s_qnn.pte`

### 2.3 현재 로컬 자산 상태

입력 weights는 있다.

- `scripts/yolo26n.pt`
- `scripts/yolo26s.pt`

generic ExecuTorch output도 있다.

- `assets/models/yolo26n.pte`
- `assets/models/yolo26s.pte`

하지만 QNN-lowered output은 아직 없다.

- `assets/models/yolo26n_qnn.pte` 없음
- `assets/models/yolo26s_qnn.pte` 없음

### 2.4 GitHub Actions export 상태

QNN export는 GitHub Actions로 옮겨서 시도 중이다.

- workflow 이름: `Export YOLO QNN`
- workflow id: `246501615`
- 대상 브랜치: `dev`

2026-03-16 기준 최근 실행 상태:

1. run #2 / `095ece6`
   - 실패
   - 원인: workflow 파싱 단계에서 `runner.temp`를 job env에서 사용
2. run #3 / `f5bbf38`
   - 실패
   - 원인: `actions/setup-python`의 잘못된 pip cache 설정
3. run #4 / `55ca340`
   - 실패
   - 원인: export 단계에서 `ModuleNotFoundError: No module named 'executorch'`
4. run #5 / `5f490cb`
   - 2026-03-16 문서 작성 시점 기준 `in_progress`
   - 목적: 위 `PYTHONPATH` 경로 문제 수정 반영 후 재시도

중요한 진전:

- GitHub Actions 안에서 `PyQnnManagerAdaptor` build 단계는 이미 통과했다.
- 즉 막혀 있는 핵심은 "host adaptor build" 자체가 아니라, 그 다음 export/runtime import 단계다.

## 3. 지금 남아 있는 핵심 작업

우선순위 기준으로 정리하면 아래 순서다.

1. GitHub Actions run #5 결론 확인
2. 성공 시 artifact 다운로드
3. `yolo26n_qnn.pte`, `yolo26s_qnn.pte`를 `assets/models/`에 배치
4. 앱 재빌드 후 route playback에서 QNN variant 실제 검증
5. detection 결과가 비면 parser/runtime 쪽 원인 분리

세부적으로는:

### 3.1 export 성공 여부 확정

- 성공이면 artifact 안에 아래 파일이 들어와야 한다.
  - `yolo26n_qnn.pte`
  - `yolo26s_qnn.pte`
- 실패면 먼저 `build/qnn_export/logs/export_*` 로그를 보고
  - model load 실패인지
  - ExecuTorch graph lowering 실패인지
  - Qualcomm backend compile spec 문제인지
  를 분리해야 한다.

### 3.2 asset 연결

artifact를 받으면 아래 경로에 넣는다.

- `assets/models/yolo26n_qnn.pte`
- `assets/models/yolo26s_qnn.pte`

현재 `pubspec.yaml`은 `assets/models/` 디렉터리 전체를 이미 잡고 있으므로, 파일만 넣으면 추가 asset 등록 수정은 필요 없다.

### 3.3 기기 검증

기기에서 최소한 아래 순서로 확인해야 한다.

1. QNN variant 선택
2. route 로그 playback 시작
3. 우측 상단 상태 배지 확인
4. `runYoloDebugVideoFrame` 로그 확인
5. `blocker` 값 확인
6. detection count 확인

기대하는 상태 전환:

- 지금: `모델 파일 없음` 또는 `QNN 변환 필요`
- asset 배치 후 1차 기대: `실행 확인`
- inference / detection까지 정상: `QNN 검증 완료`

### 3.4 zero-detection 분리

QNN model이 들어와도 박스가 안 뜰 수 있다. 그때는 아래 순서로 본다.

1. `runtimeReady`
2. `modelPath`
3. `forwardSuccesses`
4. `parsedCandidateCount`
5. `parsedDetectionCount`
6. `lastError`

즉 다음 단계의 blocker는 더 이상 "모델 파일 없음"이 아니라,

- module load 실패
- forward 실패
- parser threshold mismatch
- 실제 detections zero

중 어디인지로 바뀐다.

## 4. 다음에 바로 해야 할 것

다음 세션 시작 직후 할 일은 아래 5개면 충분하다.

1. GitHub Actions run #5 결과 확인
2. 실패면 해당 job 로그 다운로드
3. 성공이면 artifact에서 `*_qnn.pte` 두 개 꺼내기
4. `assets/models/`에 복사 후 앱 빌드
5. route playback에서 `YOLO26n QNN`, `YOLO26s QNN` 둘 다 확인

가장 좋은 완료 조건은 아래다.

- `assets/models/yolo26n_qnn.pte` 존재
- `assets/models/yolo26s_qnn.pte` 존재
- route playback에서 `runYoloDebugVideoFrame backend=executorch_qnn model=yolo26n_qnn` 확인
- 우측 상단 배지가 `실행 확인` 또는 `QNN 검증 완료`로 전환

## 5. 빠른 체크리스트

작업 재개 시 아래만 보면 된다.

- repo: `E:\Carrot\CarrotLink`
- branch: `dev`
- workflow: `.github/workflows/export-yolo-qnn.yml`
- weights:
  - `scripts/yolo26n.pt`
  - `scripts/yolo26s.pt`
- expected outputs:
  - `assets/models/yolo26n_qnn.pte`
  - `assets/models/yolo26s_qnn.pte`
- playback status UI:
  - `lib/widgets/dashcam_player_screen.dart`
- playback native entry:
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
- model slot catalog:
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveYoloModelCatalog.kt`

## 6. 이번 업데이트의 의미

이번 라운드로 달라진 건 "QNN이 아직 안 된다"를 넘어서,

- 어디까지 실제로 연결됐는지
- 왜 안 보이는지
- QNN export를 어디서 만들지
- 다음에 무엇부터 보면 되는지

가 문서와 코드에서 모두 한 단계 선명해졌다는 점이다.

남은 본질은 이제 하나다.

- `QNN-lowered .pte` 두 개를 실제로 생성해서 앱에 넣고, 기기에서 돌려보는 것
