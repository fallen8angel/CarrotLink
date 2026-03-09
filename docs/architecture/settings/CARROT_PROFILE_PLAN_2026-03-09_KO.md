# Carrot Profile Plan (2026-03-09)

## 목표

- `당근백업` 탭에 `로컬 / 클라우드 / 프로필` 3개 소스를 둔다.
- 프로필은 사용자가 이름을 붙여 저장하는 "설정 스냅샷"이다.
- 기기가 연결되지 않아도 프로필 내용을 보고 일부 수정할 수 있다.
- 기기가 연결되어 있으면 현재 값과 프로필 값을 비교하고, 프로필 값을 적용할 수 있다.

## 현재 구현 상태

- [x] `profiles/index.json + profiles/<id>.json` 구조
- [x] `settings schema snapshot + params value snapshot` 저장
- [x] `당근백업` 탭에 `로컬 / 클라우드 / 프로필` 소스 스위치 추가
- [x] 현재 기기 설정값을 읽어 새 프로필 저장
- [x] 프로필 목록 / 직접 열기 / 이름 변경 / 복제 / 삭제
- [x] 연결됨: `현재 기기값 vs 프로필값` 비교
- [x] 미연결: `마지막 로컬 백업값 vs 프로필값` 비교
- [x] 프로필 오프라인 보기/수정용 별도 화면
- [x] 프로필 화면 AppBar `3점 메뉴` 액션(`닫기 / 이름 변경 / 복제 / 비교 / 적용 / 삭제`)
- [x] 비교 전용 화면 추가(요약칩 + 그룹별 diff 카드)
- [x] 프로필 편집 화면 그룹별 접기/펼치기
- [x] 프로필 편집 화면 현재 보고 있는 그룹 상단 배지
- [x] 프로필 편집/비교 화면 하단 상태 플로팅 카드
- [x] 비교 화면 그룹별 접기/펼치기 + 현재 그룹 배지
- [x] 프로필 값을 현재 기기에 전체 적용
- [ ] 비교 결과에서 선택 적용
- [ ] `CarrotSettingsTab`과 완전 공용 데이터소스 추상화
- [ ] 프로필 클라우드 동기화

## 현재 재사용 가능한 기반

- 백업 읽기: [carrot_backup_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/carrot_backup_tab.dart#L473)
- 백업 적용: [carrot_backup_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/carrot_backup_tab.dart#L656)
- live 설정 schema 조회: [carrot_server_settings_service.dart](/d:/CarrotLink/CarrotLink-dev/lib/services/carrot_server_settings_service.dart#L22)
- live 현재값 조회: [carrot_server_settings_service.dart](/d:/CarrotLink/CarrotLink-dev/lib/services/carrot_server_settings_service.dart#L32)
- live 설정 UI: [carrot_settings_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/carrot_settings_tab.dart)

## 핵심 판단

- 프로필은 "백업 파일의 다른 이름"으로만 두면 부족하다.
- 오프라인에서도 `콤마설정`처럼 보이려면 `값(Map<String, dynamic>)`만이 아니라 `schema(groups/items/unitCycle)`도 같이 필요하다.
- 따라서 프로필 저장 시점에 아래 2개를 함께 저장해야 한다.
  - settings schema snapshot
  - params value snapshot
- 비교는 연결 상태에 따라 두 모드로 나눈다.
  - 연결됨: `현재 기기값 vs 프로필값`
  - 미연결: `마지막 로컬 백업값 vs 프로필값`
- 미연결 비교는 live가 아니라 snapshot 비교이므로 UI에서 구분 표시가 필요하다.

## 제안 데이터 모델

### ProfileHeader

- `id`
- `name`
- `createdAt`
- `updatedAt`
- `sourceBranch`
- `sourceDongleId` 또는 `sourceSerial`
- `paramCount`
- `schemaVersion`

### ProfileDocument

- `header`
- `settingsBundleJson`
- `values`

## 저장 위치 제안

- 기본 경로: `StorageLayoutService.appPath/profiles`
- 파일 구조:
  - `profiles/index.json`
  - `profiles/<profileId>.json`

이유:

- 목록 조회와 본문 조회를 분리할 수 있다.
- 이름 변경/중복/삭제가 단순하다.
- 나중에 클라우드 동기화로 확장하기 쉽다.
- 문서 하나가 깨져도 전체 프로필 목록 복구가 쉽다.

## UI 제안

### 소스 스위치

- 현재 `로컬 / 클라우드`
- 변경 `로컬 / 클라우드 / 프로필`

### 프로필 목록 카드

- 프로필 이름
- 저장 시각
- 기준 브랜치
- 키 개수
- 탭 시 즉시 프로필 편집 화면으로 진입

### 프로필 편집 화면

- 상단 검색창 + 검색 결과 위치 이동
- 상단 현재 그룹 배지
- 그룹별 접기/펼치기
- 그룹 헤더 아래에 `콤마설정 하위메뉴`와 같은 row card 렌더
- 숫자 항목은 value pill / step pill / `- +` / slider 구성
- 액션은 상세 다이얼로그가 아니라 AppBar `3점 메뉴`로 이동
- 하단 플로팅 상태 카드로 `편집 모드 / 작업 중 / 저장 중` 상태 노출

### 프로필 액션

- `새 프로필 저장`
  - 현재 기기 설정값 읽어서 새 이름으로 저장
- `닫기`
- `이름 변경`
- `복제`
- `비교`
  - 연결됨: 현재 기기 값 vs 프로필 값
  - 미연결: 마지막 로컬 백업 값 vs 프로필 값
- `적용`
  - 프로필 값을 현재 기기에 적용
- `삭제`

## 오프라인 보기/수정 방식

### 권장 방식

- `CarrotSettingsTab`을 그대로 복붙하지 말고,
- "live provider"와 "snapshot provider"를 갈아끼울 수 있게 한 단계 추상화한다.
- 1차 구현은 프로필 저장/목록/상세/기본 액션부터 넣고,
- 오프라인 `콤마설정 UI` 편집은 같은 데이터소스 추상화 위에 2차로 올린다.

### 최소 추상화

- `CarrotSettingsDataSource`
  - `Future<CarrotSettingsBundle> loadBundle()`
  - `Future<Map<String, dynamic>> loadValues(List<String> names)`
  - `Future<void> setValue(String name, dynamic value)`
  - `bool get isLive`

### 구현체

- `LiveCarrotSettingsDataSource`
  - 기존 `CarrotServerSettingsService` 사용
- `ProfileCarrotSettingsDataSource`
  - 로컬 profile json 사용
  - `setValue()`는 서버가 아니라 profile 문서를 수정

### schema snapshot 의미

- 그룹 목록
- 항목 제목/설명
- 최소/최대값
- 기본값
- unit(step)
- slider/boolean 판정에 필요한 메타

즉, 프로필 오프라인 보기/수정에 필요한 `설정 UI 정의` 전체를 저장한다.

## 비교 기능 제안

### 비교 대상

- 연결됨: 현재 기기 vs 프로필
- 미연결: 마지막 로컬 백업 vs 프로필

### 비교 출력

- 요약칩
  - 총 키 수
  - 다른 키 수
  - baseline 누락 키 수
  - profile 누락 키 수
- 그룹별 diff 개수
- 항목별 2열 비교 카드
  - 좌측 `baseline`
  - 우측 `profile`
  - 누락값은 별도 강조
- 그룹별 접기/펼치기
- 상단 현재 그룹 배지
- 하단 플로팅 상태 카드로 `비교 모드`와 기준 baseline 노출

### 비교 모드 표기

- `Live Compare`
  - 현재 기기 기준
- `Snapshot Compare`
  - 마지막 로컬 백업 기준
- snapshot 비교는 "현재 기기값 아님" 배지를 반드시 표시

### 비교 뷰 재사용

- 기존 백업 diff/적용 흐름을 확장
- 현재 [carrot_backup_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/carrot_backup_tab.dart#L514) 대화상자와 [carrot_backup_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/carrot_backup_tab.dart#L656) 적용 루프를 profile 쪽으로 일반화 가능

## 적용 기능 제안

### 연결된 경우

- profile `values.entries`를 순회하면서 `setParam` 적용

### 연결 안 된 경우

- 적용 버튼 비활성화
- 대신 "현재 기기 연결 후 적용 가능" 안내

## 단계별 구현 순서

### 1단계

- [x] `ProfileService`
- [x] profile json 저장/로드/삭제/이름변경
- [x] 프로필 목록 탭 추가
- [x] 현재 기기 -> 프로필 저장
- [x] 프로필 상세 보기/삭제/적용

### 2단계

- [x] 연결됨: 현재 기기와 비교
- [x] 미연결: 마지막 로컬 백업과 비교

### 3단계

- [ ] `CarrotSettingsDataSource` 추상화
- [x] profile 전용 오프라인 보기/수정 화면
- [x] `콤마설정` row/edit 패턴을 재사용하는 공용 위젯 도입
- [ ] live/profile 완전 공용 UI로 수렴

### 4단계

- [x] profile 오프라인 수정
- [x] profile -> 기기 적용
- [ ] diff 선택 적용

## 리스크

- 오프라인 표시를 위해 schema snapshot이 꼭 필요하다.
- 기기 firmware/schema가 바뀌면 profile schema와 현재 schema가 어긋날 수 있다.
- 따라서 profile 문서에 `schemaVersion`과 저장 시점 branch 정보를 남겨야 한다.

## 이번 턴 권장 범위

- 설계 기준 확정
  - `index.json + 개별 profile 문서`
  - `schema snapshot + values snapshot`
  - `live compare / snapshot compare`
- 구현은 `ProfileService + 목록/저장/상세/기본 액션`부터 시작
- `오프라인 콤마설정 UI`와 profile 편집은 데이터소스 추상화 이후 2차 작업으로 분리
