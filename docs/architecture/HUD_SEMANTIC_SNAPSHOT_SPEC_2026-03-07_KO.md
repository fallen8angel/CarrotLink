# HUD Semantic Snapshot Spec (2026-03-07)

## 문서 목적
- 원본 carrot onroad HUD의 값 의미를 CarrotLink에서 공통으로 사용할 수 있는 데이터 계약으로 정의한다.
- 이 문서는 **디자인 문서가 아니다**.
- 이 문서는 **adaptive HUD 구현 전에 필요한 semantic spec 문서**다.
- 홈탭 HUD, 주행화면 HUD, HUD 오버레이, preview HUD가 모두 같은 의미 체계를 쓰도록 만드는 것이 목적이다.

관련 문서:
- [CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md)
- [ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md)

---

## 1. 설계 원칙

### 1-1. UI 의미와 UI 표현을 분리한다
snapshot에는:
- 값 의미
- 값 우선순위
- 값 계산 결과

만 들어간다.

snapshot에 들어가면 안 되는 것:
- 색상
- 폰트
- 위치
- 박스 크기
- 카드 여부
- 애니메이션 방식

### 1-2. Flutter는 raw 신호를 재해석하지 않는다
예:
- `tempSource`가 비었을 때 Flutter가 임의로 `eco`를 넣지 않는다
- `LIMIT/CAM` 판정도 Flutter가 하지 않는다
- `APN/APM`도 Flutter가 문자열 추론하지 않는다

즉, source 계층에서 이미 **최종 semantic state**를 만들고 내려야 한다.

### 1-3. 원본 HUD의 값 의미를 유지한다
adaptive HUD는 새로 만들지만,
- 메인 속도가 무엇인지
- 설정속도가 무엇인지
- temp 영역이 어떤 우선순위인지
- drive mode가 어떤 값인지
- APN/APM이 무엇을 뜻하는지

이런 의미는 원본과 같아야 한다.

### 1-4. fallback은 최소화한다
fallback 허용:
- CPU
- MEM
- DISK

fallback 금지:
- GPS
- drive mode
- temp source/speed
- LIMIT/CAM
- APN/APM
- signal state

---

## 2. Snapshot 최상위 구조

권장 최상위 타입 이름:
- `OriginalHudSnapshot`

권장 구조:

```json
{
  "version": 1,
  "tsMonoMs": 0,
  "source": {
    "transport": "sidecar_hud",
    "deviceHost": "172.30.1.23"
  },
  "vehicle": {},
  "tempControl": {},
  "driveMode": {},
  "gap": {},
  "limits": {},
  "connectivity": {},
  "signals": {},
  "device": {},
  "visibility": {},
  "meta": {}
}
```

이유:
- flat map보다 의미 그룹이 분명하다
- adaptive HUD가 필요한 값만 부분 사용하기 쉽다
- 향후 원본 parity와 custom extension을 분리하기 쉽다

---

## 3. 필드 그룹 정의

## 3-1. 공통 메타

| 필드 | 타입 | 필수 | 설명 |
|---|---|---:|---|
| `version` | `int` | 예 | snapshot schema 버전 |
| `tsMonoMs` | `int` | 예 | 단조증가 기준 timestamp |
| `source.transport` | `string` | 예 | `sidecar_hud`, `preview`, `replay` 등 |
| `source.deviceHost` | `string?` | 아니오 | 현재 대상 기기 IP |

권장값 예시:
- `version = 1`
- `transport = sidecar_hud`

---

## 3-2. vehicle 그룹

원본 HUD의 핵심 주행값.

| 필드 | 타입 | 단위 | 원본 값 소스 | 설명 |
|---|---|---|---|---|
| `vehicle.speedClusterKph` | `double?` | kph | `carState.vEgoCluster` | 메인 속도 |
| `vehicle.setSpeedClusterKph` | `double?` | kph | `carState.vCruiseCluster` | 설정속도 |
| `vehicle.speedClusterMps` | `double?` | m/s | optional | 필요 시 계산용 원본 보존 |
| `vehicle.setSpeedClusterMps` | `double?` | m/s | optional | 필요 시 계산용 원본 보존 |
| `vehicle.gearText` | `string` | - | `carState.gearShifter`, `gearStep` | HUD용 기어 문자열 |
| `vehicle.longActive` | `bool` | - | `selfdriveState.enabled` | longitudinal active 여부 |
| `vehicle.latActive` | `bool` | - | `carControl.latActive` | lateral active 여부 |

원칙:
- HUD 표시용 속도는 cluster 기준으로 고정한다
- Flutter에서 다시 mph/kph 의미 변환하지 않는다
- 기어는 source에서 최종 문자열까지 만들어서 보낸다

`gearText` 예시:
- `P`
- `D`
- `N`
- `R`
- `S`
- `L`
- `B`
- `E`
- `1`, `2`, `3` ...
- `U`

---

## 3-3. tempControl 그룹

원본 HUD의 `eco / source / temp speed` 영역.

| 필드 | 타입 | 단위 | 원본 값 소스 | 설명 |
|---|---|---|---|---|
| `tempControl.mode` | `string` | - | source 계산 | `apply`, `eco`, `hidden` |
| `tempControl.label` | `string?` | - | source 계산 | 최종 표시 라벨 |
| `tempControl.speedKph` | `double?` | kph | source 계산 | 최종 표시 숫자 |
| `tempControl.sourceRaw` | `string?` | - | `carrotMan.desiredSource` | 원본 source 문자열 |
| `tempControl.applySpeedKph` | `double?` | kph | `carrotMan.desiredSpeed` | raw apply speed |
| `tempControl.cruiseTargetKph` | `double?` | kph | `longitudinalPlan.cruiseTarget` | raw cruise target |
| `tempControl.isDecel` | `bool` | - | source 계산 | 보조 색상/표시용 |

### 최종 표시 규칙
이 규칙은 source에서 계산해야 한다.

1. `desiredSource`가 있고, 원본 규칙상 표시 가능하면:
- `mode = apply`
- `label = desiredSource`
- `speedKph = desiredSpeed`

2. 아니고 `cruiseTarget != setSpeedClusterKph` 이면:
- `mode = eco`
- `label = eco`
- `speedKph = cruiseTarget`

3. 둘 다 아니면:
- `mode = hidden`
- `label = null`
- `speedKph = null`

중요:
- Flutter는 빈 source를 보고 임의로 `eco`를 넣지 않는다
- source가 최종 상태를 계산해서 내려야 한다

---

## 3-4. driveMode 그룹

| 필드 | 타입 | 원본 값 소스 | 설명 |
|---|---|---|---|
| `driveMode.code` | `int?` | `longitudinalPlan.myDrivingMode` | 원본 코드 |
| `driveMode.nameOriginal` | `string` | source 계산 | `ECO`, `SAFE`, `NORM`, `FAST` |
| `driveMode.kind` | `string` | source 계산 | `eco`, `safe`, `normal`, `fast` |

원칙:
- 원본 이름을 보존한다
- UI 친화적인 kind도 같이 보낸다

매핑:
- `1 -> ECO / eco`
- `2 -> SAFE / safe`
- `3 -> NORM / normal`
- `4 -> FAST / fast`

---

## 3-5. gap 그룹

| 필드 | 타입 | 원본 값 소스 | 설명 |
|---|---|---|---|
| `gap.personalityRaw` | `int?` | `Params(LongitudinalPersonality)` | raw personality 값 |
| `gap.displayValue` | `int` | source 계산 | HUD 숫자 값, 보통 `raw + 1` |
| `gap.barCount` | `int` | source 계산 | HUD bar 개수 |

원칙:
- 원본과 동일하게 `LongitudinalPersonality` 기준
- UI는 `displayValue`와 `barCount`만 쓰면 된다

---

## 3-6. connectivity 그룹

원본의 APN/APM 관련 의미.

| 필드 | 타입 | 원본 값 소스 | 설명 |
|---|---|---|---|
| `connectivity.activeCarrot` | `int?` | `carrotMan.activeCarrot` | 원본 정수 상태 |
| `connectivity.badgeMode` | `string` | source 계산 | `apn`, `apm`, `hidden` |
| `connectivity.badgeLabel` | `string?` | source 계산 | `APN`, `APM` 또는 null |

규칙:
- `activeCarrot >= 2 -> apn`
- `activeCarrot >= 1 -> apm`
- 그 외 `hidden`

중요:
- 현재 placeholder `apm` 문자열 방식은 버린다
- raw 정수값을 남겨야 이후 의미 확장이 가능하다

---

## 3-7. limits 그룹

원본 HUD의 `LIMIT / CAM` 영역.

| 필드 | 타입 | 단위 | 원본 값 소스 | 설명 |
|---|---|---|---|---|
| `limits.mode` | `string` | - | source 계산 | `limit`, `camera`, `hidden` |
| `limits.label` | `string?` | - | source 계산 | `LIMIT`, `CAM`, null |
| `limits.displaySpeedKph` | `double?` | kph | source 계산 | 실제 HUD 숫자 |
| `limits.roadLimitSpeedKph` | `double?` | kph | `carrotMan.nRoadLimitSpeed` | raw 일반 도로 제한속도 |
| `limits.cameraLimitSpeedKph` | `double?` | kph | `carrotMan.xSpdLimit` | raw 카메라 제한속도 |
| `limits.cameraSignType` | `int?` | - | `carrotMan.xSpdType` | sign type |
| `limits.isOverLimit` | `bool` | - | source 계산 | 원본 규칙 기반 과속 여부 |
| `limits.shouldBlink` | `bool` | - | source 계산 | CAM blink 여부 |

### 최종 표시 규칙
1. `xSpdLimit > 0` 이고 원본 조건 만족:
- `mode = camera`
- `label = CAM`
- `displaySpeedKph = cameraLimitSpeedKph`
- `shouldBlink = true`

2. 아니면 일반 제한속도:
- `mode = limit`
- `label = LIMIT`
- `displaySpeedKph = roadLimitSpeedKph`

3. 둘 다 없으면:
- `mode = hidden`

과속 판단:
- 원본 규칙과 동일하게 `currentSpeedKph > displaySpeedKph + 2`

---

## 3-8. signals 그룹

원본 HUD의 신호등/점 상태.

| 필드 | 타입 | 원본 값 소스 | 설명 |
|---|---|---|---|
| `signals.trafficStateLp` | `int?` | `longitudinalPlan.trafficState` | LP 쪽 상태 |
| `signals.trafficStateCarrot` | `int?` | `carrotMan.trafficState` | carrot 쪽 상태 |
| `signals.visualState` | `string` | source 계산 | `off`, `red`, `green` |
| `signals.redDot` | `bool` | source 계산 또는 확장용 | 빨간 점 사용 시 |

규칙:
- visualState는 raw 두 상태를 보고 source에서 계산
- UI는 raw int를 직접 해석하지 않는다

---

## 3-9. gps 그룹

| 필드 | 타입 | 원본 값 소스 | 설명 |
|---|---|---|---|
| `gps.hasFix` | `bool` | `gpsLocationExternal` 또는 `gpsLocation` | 실제 fix |
| `gps.provider` | `string?` | source 계산 | `external`, `internal` 등 |

중요:
- `gps.hasFix`는 절대 placeholder 금지
- 현재처럼 무조건 `true`로 내려보내는 방식 금지

---

## 3-10. device 그룹

| 필드 | 타입 | 단위 | 원본 값 소스 | 설명 |
|---|---|---|---|---|
| `device.cpuTempAvgC` | `double?` | °C | `deviceState.cpuTempC` 평균 | 원본 HUD CPU 표시값 |
| `device.cpuTempMaxC` | `double?` | °C | optional | debug/보조용 |
| `device.memUsagePct` | `double?` | % | `deviceState.memoryUsagePercent` | MEM |
| `device.diskUsedPct` | `double?` | % | `100 - freeSpacePercent` | DISK 표시값 |
| `device.freeSpacePct` | `double?` | % | `deviceState.freeSpacePercent` | raw 보관용 |
| `device.voltV` | `double?` | V | `peripheralState.voltage / 1000` | VOLT |
| `device.metricPrimaryMode` | `string` | - | source 계산 | `disk`, `volt` |

원칙:
- CPU는 원본 parity용 `avg`를 표준으로 쓴다
- `max`는 debug용이면 따로 둔다
- DISK/VOLT는 단일 값 multiplex보다 separate fields 권장

---

## 3-11. visibility 그룹

원본 HUD에서 param으로 토글되는 표시 관련 값.

| 필드 | 타입 | 원본 값 소스 | 설명 |
|---|---|---|---|
| `visibility.showDeviceState` | `bool` | `Params(ShowDeviceState)` | 상단 metrics 노출 여부 |
| `visibility.showDateTimeMode` | `int?` | `Params(ShowDateTime)` | 날짜/시간 표시 모드 |

주의:
- adaptive HUD에서는 이걸 그대로 쓸지, 앱 정책으로 덮을지는 별도 결정 가능
- 다만 snapshot에는 원본 상태를 남기는 게 좋다

---

## 3-12. meta 그룹

| 필드 | 타입 | 설명 |
|---|---|---|
| `meta.isPreview` | `bool` | preview/mock snapshot 여부 |
| `meta.isFallbackMetricsApplied` | `bool` | CPU/MEM/DISK fallback 개입 여부 |
| `meta.missingFields` | `string[]` | source 미수집 필드 목록 |
| `meta.quality` | `string` | `live`, `degraded`, `preview` 등 |

이 필드는 parity용은 아니지만 운영상 유용하다.

---

## 4. 현재 우리 앱 필드와의 차이

현재 Flutter `_HudSnapshot`은 아래 필드를 쓴다.
- [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart#L741)

현재 필드:
- `cpuTempC`
- `memPct`
- `diskValue`
- `diskLabel`
- `vEgoKph`
- `vSetKph`
- `gear`
- `gpsOk`
- `tfBars`
- `driveModeName`
- `driveModeKind`
- `tlight`
- `redDot`
- `tempSource`
- `tempSpeedKph`
- `tempIsDecel`
- `speedLimitKph`
- `speedLimitOver`

문제:
- raw와 final semantic state가 섞여 있다
- `LIMIT`와 `CAM`이 같은 필드에 눌려 있다
- `APN/APM`이 빠져 있다
- `gpsOk`가 신뢰 불가
- `tempSource`는 Flutter가 추정하기 쉬운 구조다
- `DISK/VOLT`가 multiplex 구조다

결론:
- `_HudSnapshot`은 새 semantic spec을 담기엔 부족하다
- 새 `OriginalHudSnapshot` 계열로 교체해야 한다

---

## 5. 수집 계층에서 계산해야 하는 것

아래는 UI가 아니라 data layer에서 계산해야 한다.

### source에서 계산
- `tempControl.mode`
- `tempControl.label`
- `tempControl.speedKph`
- `driveMode.nameOriginal`
- `driveMode.kind`
- `gap.displayValue`
- `gap.barCount`
- `connectivity.badgeMode`
- `connectivity.badgeLabel`
- `limits.mode`
- `limits.label`
- `limits.displaySpeedKph`
- `limits.isOverLimit`
- `limits.shouldBlink`
- `signals.visualState`

### UI가 하면 안 되는 것
- 빈 source면 `eco` 넣기
- `activeCarrot` 보고 APN/APM 추정
- signType 보고 LIMIT/CAM 판정
- GPS true/false 추측
- DISK/VOLT 라벨을 fallback 유무로 결정

---

## 6. 수집 주기와 전달 정책

권장 기본 주기:
- live HUD snapshot: 10Hz
- device metrics: 2~5Hz 가능

정책:
- 한 snapshot에 가능한 한 같은 시점의 값이 묶여야 한다
- raw source가 늦는 항목은 null 허용
- 의미가 다른 fallback 값으로 덮어쓰지 않는다

예:
- CPU가 없으면 `device.cpuTempAvgC = null`
- 대신 `meta.isFallbackMetricsApplied = true`

---

## 7. JSON 예시

```json
{
  "version": 1,
  "tsMonoMs": 184233042,
  "source": {
    "transport": "sidecar_hud",
    "deviceHost": "172.30.1.23"
  },
  "vehicle": {
    "speedClusterKph": 34.0,
    "setSpeedClusterKph": 80.0,
    "gearText": "7",
    "longActive": true,
    "latActive": true
  },
  "tempControl": {
    "mode": "apply",
    "label": "eco",
    "speedKph": 83.0,
    "sourceRaw": "eco",
    "applySpeedKph": 83.0,
    "cruiseTargetKph": 80.0,
    "isDecel": false
  },
  "driveMode": {
    "code": 1,
    "nameOriginal": "ECO",
    "kind": "eco"
  },
  "gap": {
    "personalityRaw": 1,
    "displayValue": 2,
    "barCount": 2
  },
  "connectivity": {
    "activeCarrot": 2,
    "badgeMode": "apn",
    "badgeLabel": "APN"
  },
  "limits": {
    "mode": "limit",
    "label": "LIMIT",
    "displaySpeedKph": 70.0,
    "roadLimitSpeedKph": 70.0,
    "cameraLimitSpeedKph": null,
    "cameraSignType": null,
    "isOverLimit": false,
    "shouldBlink": false
  },
  "signals": {
    "trafficStateLp": 0,
    "trafficStateCarrot": 0,
    "visualState": "off",
    "redDot": false
  },
  "gps": {
    "hasFix": true,
    "provider": "external"
  },
  "device": {
    "cpuTempAvgC": 75.2,
    "cpuTempMaxC": 81.0,
    "memUsagePct": 63.0,
    "diskUsedPct": 64.0,
    "freeSpacePct": 36.0,
    "voltV": 12.7,
    "metricPrimaryMode": "volt"
  },
  "visibility": {
    "showDeviceState": true,
    "showDateTimeMode": 1
  },
  "meta": {
    "isPreview": false,
    "isFallbackMetricsApplied": false,
    "missingFields": [],
    "quality": "live"
  }
}
```

---

## 8. 구현 전 결론

이 spec이 먼저 고정돼야:
- sidecar가 무엇을 읽고 계산할지 정할 수 있고
- Flutter adaptive HUD가 raw payload를 추정하지 않게 되며
- 홈탭, 주행화면, 오버레이가 같은 semantic snapshot을 공유할 수 있다

즉 다음 순서는 이렇다.

1. 이 spec 확정
2. HUD data pipeline 문서화
3. sidecar / endpoint 설계
4. adaptive HUD layout spec
5. 최종 UI 구현

