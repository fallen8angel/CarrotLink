# CarrotLink Stock Mode Remote AR 구현 체크리스트 (2026-03-06)

최종 분석일: 2026-03-06

대상:
- 앱: `E:\CarrotLink\CarrotLink`
- 장치 런타임: `E:\CarrotLink\C3-v10-wip`

이 문서는 stock 모드 remote AR 구현을 실제 작업 단위로 쪼갠 체크리스트다.

## 1. 데이터 계약

- [ ] 기존 path/lane projection 수학 비수정 원칙 유지
- [ ] 기존 camera frame sync / frameId 처리 비수정 원칙 유지
- [ ] `carrotMan`와 `navInstructionCarrot`를 1차 주 계약으로 확정
- [ ] `7712 raw`는 디버그/보강용으로만 문서화
- [ ] `naviPaths` 포맷을 `x,y,d;x,y,d;...`로 명시
- [ ] `xTurnInfo`, `xDistToTurn`, `szTBTMainText` 의미를 표로 고정
- [ ] `xSpdType`, `xSpdLimit`, `xSpdDist`, `trafficState` 사용 목적을 고정
- [ ] scene payload version 필드 추가 여부 결정
- [ ] stale timeout, frame gap tolerance, clip margin 상수 문서화

## 2. 좌표계

- [ ] `lat/lng`와 `car-space(x,y,z)`를 문서상 분리
- [ ] 1차 기준 좌표를 `car-space`로 확정
- [ ] `naviPaths`는 route 원본이 아니라 상대 경로라는 점 명시
- [ ] z 값은 `laneLines/path`에서 샘플링하는 규칙 문서화
- [ ] `pathOffsetZ` 사용 범위 고정
- [ ] road/wideRoad 좌표 규칙 분리

## 3. Scene 모델

- [ ] raw payload를 바로 renderer로 보내지 않도록 금지
- [ ] `RouteRibbonScene` 정의
- [ ] `TurnGateScene` 정의
- [ ] `TurnBoardScene` 정의
- [ ] `SpeedCueScene` 정의
- [ ] `TrafficCueScene` 정의
- [ ] `SceneHealth` 정의
- [ ] scene builder 입력/출력 인터페이스 문서화

## 4. 경로 리본

- [ ] `naviPaths` 파서 cache 적용
- [ ] 전방 거리 사용 범위 확정 예: `2m~120m`
- [ ] point cap 확정 예: `60~90개`
- [ ] resample step 확정
- [ ] distance-based width/alpha 규칙 정의
- [ ] lane/path z 샘플링 규칙 정의
- [ ] road camera clip/culling 규칙 적용

## 5. 턴 게이트 / 턴 보드

- [ ] `xDistToTurn` 근처 경로점 anchor 선택 규칙 정의
- [ ] `xTurnInfo` -> 좌/우/유턴/도착 semantic 매핑 표 작성
- [ ] `navInstructionCarrot`를 fallback으로 쓰는 규칙 정의
- [ ] gate width를 lane width 또는 고정 width 중 어떤 방식으로 갈지 확정
- [ ] gate와 board의 상대 z / y offset 규칙 정의
- [ ] turn 전/후 fade-in, fade-out 규칙 정의

## 6. 보조 AR 레이어

- [ ] 속도카메라 표지 2차 여부 확정
- [ ] 신호등 상태 2차 여부 확정
- [ ] 제한속도는 AR object가 아닌 HUD badge로 둘지 결정
- [ ] 도착 zone 연출 2차 여부 확정
- [ ] clutter budget 문서화

## 7. 카메라 맵핑

- [ ] road/wideRoad별 intrinsic 값 확인
- [ ] `liveCalibration.rpyCalib` 적용 조건 확인
- [ ] `wideFromDeviceEuler` 적용 조건 확인
- [ ] `_viewFromDevice` 포함한 최종 transform 순서 고정
- [ ] `car-space -> source pixel -> canvas` 순서 유지
- [ ] video placement와 overlay placement가 같은 transform을 쓰는지 검증
- [ ] frameId sync 없을 때 숨김 규칙 적용

## 8. 렌더러 구조

- [ ] Flutter 역할을 shell/UI 수준으로 제한
- [ ] semantic scene까지만 Flutter에서 생성
- [ ] 투영과 최종 렌더는 native에서 처리할지 결정
- [ ] 1차는 기존 polygon/label 확장인지, 새 native 3D renderer인지 확정
- [ ] road/wide 전환 시 renderer 재초기화 정책 정의
- [ ] renderer object pooling 여부 결정

## 9. 성능 / 경량화

- [ ] per-frame MethodChannel 대량 payload 금지
- [ ] update 주기 분리
- [ ] thermal degrade 단계 정의
- [ ] max path points / max labels / max chevrons 제한
- [ ] offscreen culling 적용
- [ ] stale scene 재사용 또는 drop 규칙 정의
- [ ] payload size budget 문서화

## 10. 환경 / 고도 적응

- [ ] 1차는 `lane/path z + calibration height` 기반 pseudo-3D로 확정
- [ ] 오르막/내리막에서 z 샘플링이 충분한지 실차 검증
- [ ] curve/분기에서 path ribbon 위치가 자연스러운지 검증
- [ ] road edge / lane width를 이용한 gate placement 보정 여부 결정
- [ ] wide/road camera별 최적 보드 위치 별도 튜닝
- [ ] 고정된 screen-space y offset 남용 금지
- [ ] 환경 적응은 "주변 차선/경로 형상 기반"으로 하고, world-fixed 착시를 과도하게 주지 않도록 제어

## 11. 실패 / 폴백 규칙

- [ ] calibration 부재 시 AR downgrade
- [ ] `naviPaths` stale 시 경로 리본 숨김
- [ ] frame gap 과다 시 alpha down 후 숨김
- [ ] turn 데이터 없음 시 route만 유지
- [ ] route 데이터 없음 시 일반 HUD만 유지
- [ ] road/wide 전환 직후 안전한 fade-in 적용

## 12. 검증

- [ ] 직진 고속도로
- [ ] 완만한 곡선
- [ ] 급커브
- [ ] 좌/우 분기
- [ ] 교차로 턴
- [ ] 오르막 / 내리막
- [ ] wideRoad 전환
- [ ] 저속 정체
- [ ] night / day
- [ ] thermal throttling 상황

## 13. 1차 MVP 완료 기준

- [ ] 경로 리본이 실제 도로 흐름과 크게 어긋나지 않음
- [ ] 턴 게이트가 실제 maneuver 위치와 대체로 맞음
- [ ] frame mismatch 시 AR가 과감히 사라짐
- [ ] clutter가 과하지 않음
- [ ] 실기기에서 장시간 구동 시 성능 저하가 허용 범위 내

## 14. 내 의견

- 1차 성공 기준은 "멋진 3D"가 아니라 "경로와 턴이 안정적으로 맞는 것"이다
- 고도/환경 적응은 가능하지만, 우선 `lane/path z`와 `camera calibration height`만으로 시작하는 게 맞다
- world-fixed AR처럼 보이는 연출은 2차 이후에 천천히 올리는 게 안전하다

## 15. 참고 문서

- `docs/architecture/STOCK_MODE_REMOTE_AR_MVP_EXECUTION_PLAN_2026-03-06_KO.md`
- `docs/architecture/STOCK_MODE_REMOTE_AR_MAPPING_OPTIMIZATION_2026-03-06_KO.md`
- `docs/architecture/STOCK_MODE_REMOTE_AR_DISPLAY_DESIGN_2026-03-06_KO.md`
