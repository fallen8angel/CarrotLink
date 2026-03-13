# c4 radarFault 분석과 CarrotLink `c4_safe` 현황 (2026-03-14)

## 문서 목적
- `c3`에서는 문제가 잘 보이지 않는데 `c4`에서만 `Stock` 주행 활성화 시 `radarFault`가 더 쉽게 보이는 현상을 코드 기준으로 정리한다.
- `E:\Carrot\radarFault_analysis.md`의 가설을 참고하되 그대로 단정하지 않고, `c3`/`c4` 클론 코드와 `CarrotLink` sidecar를 교차 검토한 현재 판단을 남긴다.
- `CarrotLink`에 실제로 넣은 `c4_safe` 보완책과 그 의도를 문서화한다.

---

## 결론 요약
- `radard.py`, `hyundai/radar_interface.py`, `card.py`의 핵심 레이더 경로는 `c3`와 `c4`가 사실상 같다.
- 따라서 현상 중심축은 "`c4`만의 완전히 다른 레이더 로직"보다 `EnableRadarTracks > 0` 구간의 초기 liveness 취약점과 `c4`의 상대적으로 무거운 startup 환경이 겹치는 쪽이 더 설득력 있다.
- `CarrotLink` sidecar는 `radarFault`를 직접 발생시키는 주체는 아니지만, `Stock` 주행 진입 직후 `p2` 런타임을 너무 빨리 요구하면 `c4`의 좁은 startup 창을 더 민감하게 만들 수 있다.
- 그래서 `CarrotLink` 쪽 대응은 "상시 성능 하향"이 아니라 "`c4`에서만 startup을 보수적으로 다루는 `c4_safe` soft-start"로 잡는 것이 맞다.

---

## 1. `c3` / `c4` 교차검증 결과

### 1-1. 레이더 핵심 경로는 동일
- `selfdrive/controls/radard.py`
  - `c3`와 `c4` hash 동일
- `opendbc_repo/opendbc/car/hyundai/radar_interface.py`
  - `c3`와 `c4` hash 동일
- `selfdrive/car/card.py`
  - 파일 전체는 다르지만 `liveTracks` publish 경로는 동등

의미:
- 현대 radar tracks 경로에서 `trigger_msg`가 올 때만 `RadarData`가 만들어지고, 그렇지 않으면 `None`이 나가 `liveTracks` 공백이 생길 수 있다는 기본 가설은 `c3`/`c4` 공통으로 유효하다.

### 1-2. `selfdrived`는 다르지만 `radarFault` 자체 논리는 같다
- `c4`는 `userBookmark`, `audioFeedback` 구독과 `feedbackd` 연동이 추가돼 있다.
- 하지만 `selfdrived`의 초기화 timeout 경로와 `radarFault` event 생성 경로 자체는 `c3`와 본질적으로 같다.

의미:
- `c4` 차이는 "레이더 fault 규칙이 달라졌다"보다 startup 과정에서 영향을 줄 수 있는 주변 요소가 더 많아졌다는 쪽이다.

### 1-3. `userBookmark` / `audioFeedback` 가설은 현재 코드와 맞지 않음
- `c4/cereal/services.py`에서 두 서비스는 `freq=0` on-demand 성격이다.
- `c4/cereal/messaging/__init__.py`에서 `freq=0` 서비스는 초기 상태가 `alive/freq_ok/valid=True`로 잡힌다.

의미:
- "이 두 서비스가 안 와서 `all_valid()`가 깨지고 c4가 항상 6초 timeout된다"는 새 가설은 현재 코드 기준으로는 지지되지 않는다.

---

## 2. 더 설득력 있는 원인 프레임

### 2-1. 메시지 계약 mismatch
- `RadarInterface`는 tracks 모드에서 특정 trigger가 와야만 `RadarData`를 반환한다.
- 반면 `radard`와 상위 초기화 경로는 `liveTracks`가 충분히 살아 있기를 기대한다.

의미:
- "조건부 publish"와 "주기적 alive 기대"가 만나는 지점이 구조적으로 취약하다.

### 2-2. 차량 상태 / CAN 환경
- 정차, 주차장, 저속, 전방 타겟 부재, 레이더 wake-up 조건에 따라 trigger가 늦을 수 있다.

의미:
- 같은 코드라도 실제 환경에 따라 cold start의 초기 공백 길이가 달라질 수 있다.

### 2-3. `c4` startup 증폭기
- `c4`는 `PythonProcess("ui", ...)`, `proclogd`, `journald`, `feedbackd` 등으로 `c3`보다 초기 프로세스 구성이 무겁다.

의미:
- 레이더 경로의 근본 원인을 새로 만든다기보다, 원래 취약한 초기 창을 더 좁게 만들 가능성이 있다.

### 2-4. `CarrotLink`는 증폭기이지 직접 원인은 아님
- sidecar는 `liveTracks`를 publish하지 않는다.
- 다만 `Stock` 주행 진입 시 `modelV2`, `radarState`, 카메라 계열을 포함한 live runtime을 요구한다.

의미:
- `CarrotLink`는 `radarFault`를 직접 만들어내기보다는, 너무 이른 시점의 heavy runtime 진입으로 `c4`의 startup race를 증폭할 수 있다.

---

## 3. `CarrotLink` 대응 원칙

### 3-1. 성능 하향이 아니라 startup soft-start
- 목표는 `p2`를 영구적으로 느리게 만드는 것이 아니다.
- `c4`에서만 startup 초기에 `p1`을 더 오래 유지하고, 레이더 안정화가 확인되면 원래 의도한 `p2`로 승격한다.

### 3-2. `c3`는 기존 동작 유지
- `c3`는 기존 `default` variant 경로를 유지한다.
- `c4` 계열만 `c4_safe` variant로 보수적으로 들어간다.

### 3-3. 판단 기준은 `variant`와 `repoFlavor`를 분리
- `variant`
  - sidecar runtime 정책 (`default`, `c4_safe`)
- `repoFlavor`
  - remote openpilot 계열 (`c3`, `c4`, `unknown`)

의미:
- UI 표시는 `c3/c4`로 명확하게 하고, 실제 보호 로직은 `c4_safe` variant에만 걸 수 있다.

---

## 4. 현재 적용한 `c4_safe` 보완책

### 4-1. sidecar가 `repoFlavor`를 직접 노출
- sidecar가 remote repo 구조와 `process_config.py` 시그니처를 바탕으로 `c3/c4/unknown`을 계산한다.
- `/health`, `/profile`, live/hud websocket hello payload에 `repoFlavor`를 싣는다.

### 4-2. `c4_safe`에서 `p1`도 `radarState`를 구독
- 기존 `p1`은 `radarState`를 보지 않았기 때문에, `p1` 유지 상태에선 레이더 안정화를 판단할 수 없었다.
- 이제 `c4_safe + p1`에서만 `radarState`를 얕게 구독해 startup 판단 신호로 사용한다.

의미:
- `p1`에 머문 채로 레이더가 안정됐는지 보고, 준비되면 `p2`로 올릴 수 있다.

### 4-3. `startupProtectionActive` / `radarFreshStable`를 실제 승격 조건으로 사용
- Flutter 쪽 `desiredProfile` 계산이 이제 `c4_safe`일 때 `startupProtectionActive`, `radarReady`, `radarFreshStable`를 본다.
- `c4_safe`이고 아직 안정화가 안 됐으면 `p1` 유지
- 안정화가 확인되면 `p2` 승격

### 4-4. `p2` 진입 후 불안정하면 다시 `p1`로 복귀
- `c4_safe`에서 live runtime이 다시 startup-protection 상태이거나 radar freshness가 흔들리면 recovery를 예약한다.
- recovery 시점에 `desiredProfile`을 다시 계산해 `p1 -> p2` 또는 `p2 -> p1`를 재조정한다.
- 더 이른 recovery 요청이 오면 기존 예약보다 앞당길 수 있게 해, `bootstrap hold`나 `live unstable` 상황에서 backoff 때문에 복구가 늦게 밀리지 않도록 했다.

### 4-5. stock 우측 상단 텍스트를 `c3/c4`로 표시
- 기존 우측 상단 `Stock` 텍스트는 openpilot overlay 모드에서 `repoFlavor` 기반 `c3` / `c4` 표시로 대체한다.
- flavor를 아직 못 잡은 극초기 구간은 `c?`로 표시해, 단순 stock 라벨과 flavor 미판별 상태를 구분한다.

### 4-6. service health 판정도 `c4_safe` 기준으로 정렬
- drive 화면뿐 아니라 `SidecarService` 내부 health 검증도 `c4_safe` 기준과 동일하게 맞췄다.
- 따라서 live profile에서 `startupProtectionActive == true`이거나 `radarReady/radarFreshStable`가 확보되지 않으면, sidecar를 준비 완료로 재사용하지 않는다.

---

## 5. 해석 주의
- 이 대응은 `openpilot` 내부 `radarFault` 원인을 직접 고친 것이 아니다.
- 실제 root cause가 openpilot 내부 초기화/liveness 계약 쪽에 있더라도, `CarrotLink`가 그 취약한 창을 덜 건드리게 만들어 재현 확률을 낮추는 실용적 완화책이다.
- 만약 `c4_safe`에서도 동일 fault가 계속 난다면, 다음 단계는 `openpilot c4` 쪽 cold-start 로그와 `selfdrived.initialized`, `liveTracks`, `radarState` 시점을 더 직접 비교해야 한다.

---

## 6. 다음 확인 포인트
- `c4_safe` 적용 후 cold boot에서 `p1` 유지 시간이 어떻게 바뀌는지
- `repoFlavor=c4`, `variant=c4_safe` 상태에서 `startupProtectionActive -> false` 전환 시점
- `radarFreshStable=true` 이후 `p2` 승격이 정상적으로 이뤄지는지
- 동일 조건에서 `c3`는 기존 체감 성능과 동작이 유지되는지
