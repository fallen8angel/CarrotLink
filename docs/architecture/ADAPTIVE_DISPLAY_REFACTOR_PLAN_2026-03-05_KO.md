# CarrotLink 적응형 디스플레이 리팩토링 계획 (2026-03-05)

최종 분석일: 2026-03-05  
분석 대상:
- 앱 코드: `d:/CarrotLink/CarrotLink-dev/lib`

## 1. 목적

이 문서는 CarrotLink가 다음 환경에서 레이아웃 깨짐 없이 동작하도록 하는 적응형(UI/UX) 기준과 리팩토링 순서를 정의한다.

- 일반 스마트폰 (compact)
- 폴더블 접힘/펼침 (hinge/fold)
- 태블릿/대화면 (expanded 이상)
- 다양한 화면 밀도(mdpi~xxxhdpi)

## 2. 현재 구조 진단 (핵심)

### 2.1 전역 방향 정책

- `main.dart`에서 앱 전체를 `portraitUp`으로 고정하고 있음.
  - 파일: `lib/main.dart:30`
  - 영향: 폴더블 펼침/태블릿 가로 활용도 저하, size class 대응 어려움.

### 2.2 고정값 기반 레이아웃 다수

`width/height/fontSize/SizedBox` 고정값 사용이 많은 파일 상위:
- `lib/screens/drive/live_drive_canvas_screen.dart` (69)
- `lib/screens/tabs/carrot_settings_tab.dart` (64)
- `lib/screens/tabs/git_tab.dart` (47)
- `lib/screens/settings/connection_settings_widgets.dart` (45)
- `lib/screens/backup_manager_screen.dart` (44)
- `lib/widgets/home_hud_preview_card.dart` (36)

### 2.3 HUD 프리뷰 카드의 고정 기준 캔버스

- `HomeHudPreviewCard`가 `maxWidth: 340`, `aspectRatio: 1` 중심으로 구성됨.
  - 파일: `lib/widgets/home_hud_preview_card.dart:216`
- 내부 좌표계(340 기준 scale)는 장점도 있으나, 큰 화면에서 정보밀도/여백 최적화 한계가 있음.

### 2.4 텍스트 스케일 비활성

- HUD 프리뷰에서 `TextScaler.noScaling` 강제.
  - 파일: `lib/widgets/home_hud_preview_card.dart:210`
- 영향: 접근성(큰 글자), 다양한 DPI/사용자 설정 대응 약화.

### 2.5 HUD 주행화면 도크/배너의 혼합 단위

- 도크 폭은 비율 기반(`constraints.maxWidth * 0.08`)으로 잘 구성됨.
  - 파일: `lib/screens/drive/live_drive_canvas_screen.dart:5399`
- 그러나 상태 배너/팝업/아이콘은 고정값(10, 16, 560 등)이 다수.
  - 파일: `lib/screens/drive/live_drive_canvas_screen.dart:5622`, `:5629`, `:5888`

## 3. 원칙 (프로젝트 기준)

### 3.1 단위

- Flutter에서 `dp` 개념은 논리 픽셀(logical pixel)이다.
- 절대 `px` 하드코딩 대신, 다음 우선순위 사용:
  1. 비율(`Expanded/Flexible`)
  2. 제약(`LayoutBuilder`, `ConstrainedBox`)
  3. 토큰(`spacing/font/radius` 스케일)

### 3.2 이미지/아이콘

- 아이콘/로고는 벡터 우선(`.svg`, vector drawable).
- 비트맵(사진/배경)은 `BoxFit` 정책과 함께 해상도별 에셋 세트 유지.

### 3.3 Size Class

우선 2단계(Compact/Expanded)를 적용하고, 내부적으로는 5단계까지 확장 가능하게 설계한다.

- compact: `< 600dp`
- medium: `600~839dp`
- expanded: `840~1199dp`
- large: `1200~1599dp`
- extra-large: `>= 1600dp`

## 4. 권장 리팩토링 구조

### 4.1 공통 유틸 레이어 신설

신규 모듈(예시):
- `lib/ui/adaptive/window_class.dart`
- `lib/ui/adaptive/scale_tokens.dart`
- `lib/ui/adaptive/display_feature_utils.dart`

기능:
- `WindowClass` 계산
- 화면 크기별 spacing/font/icon/radius 토큰 제공
- fold/hinge 영역 회피 인셋 계산

### 4.2 페이지 템플릿 표준화

각 주요 탭 화면에서 공통 패턴으로 통일:
- 상단 헤더
- 스크롤 본문
- 하단 safe area padding
- compact/expanded 분기 레이아웃

### 4.3 HUD 화면 이원화

- compact: 현재와 유사한 단일 컬럼 + 도크
- expanded 이상: `좌측 도크 + 우측 콘텐츠`를 유지하되, 상태패널/디버그패널 폭을 size class별로 분기

## 5. 단계별 실행 계획

### Phase A (기반, 위험 낮음)

1. WindowClass/Token 유틸 추가
2. 공통 spacing/font 토큰으로 하드코딩 치환 시작
3. 전역 컴포넌트(`DesignCard`, 토스트, 공통 버튼)부터 적용

### Phase B (핵심 화면)

1. `dashboard_screen.dart` + `home_tab.dart`
2. `home_hud_preview_card.dart`
3. `live_drive_canvas_screen.dart` (도크/배너/디버그 레이아웃)

### Phase C (나머지 탭)

1. `carrot_settings_tab.dart`
2. `connection_settings_widgets.dart`
3. `git_tab.dart`, `logs_tab.dart`, `backup_manager_screen.dart`

## 6. 수용 기준 (Definition of Done)

### 6.1 화면 클래스별

- compact(폰 세로): 오버플로우 0
- expanded(태블릿/폴더블 펼침): 좌우 여백 과다/정보 과밀 없음

### 6.2 폴더블/힌지

- hinge를 가로지르는 버튼/텍스트 없음
- 주요 상호작용 요소는 단일 영역에 완전히 포함

### 6.3 접근성

- 시스템 글자 확대 시 핵심 화면(Home, HUD, Settings)에서 기능 접근 가능

## 7. 즉시 적용 권장사항 (우선 3개)

1. `main.dart` 전역 세로 고정 재검토  
   - 기본은 유지하되, HUD/특정 페이지에서 size class 기반 방향 정책을 허용.

2. `HomeHudPreviewCard`의 `TextScaler.noScaling` 완화  
   - 최소/최대 스케일 clamp 방식으로 접근성 허용.

3. `live_drive_canvas_screen.dart` 상태배너 고정 폭/고정 인셋 토큰화  
   - `maxWidth: 560` 등 고정값을 클래스별 토큰으로 분리.

## 8. 결론

현재 코드는 기능 구현 속도에 최적화되어 있고, 일부 화면은 이미 `LayoutBuilder/Expanded`를 사용해 기반은 나쁘지 않다.  
다만 "전역 방향 고정 + 고정값 다량 사용 + 텍스트 스케일 강제 차단" 조합 때문에 디바이스 다양성 대응이 제한된다.

따라서 다음 결론이 타당하다:
- **원칙은 유지**: 오픈파일럿 정합/주행 화면 품질 우선
- **구조는 교체**: 하드코딩에서 size class + 토큰 + display feature 대응 구조로 점진 전환
- **순서는 보수적**: 공통 유틸 → Home/HUD → 나머지 탭

## 9. 진행 현황 (2026-03-05)

- 완료:
  - `main.dart` 전역 방향 정책 완화
    - `portraitUp` 고정 해제, `portraitUp + landscapeLeft + landscapeRight` 허용
    - 폴더블/태블릿 펼침 가로 검증 가능 상태로 전환
  - `splash_screen.dart` 적응형 1차 적용
    - 로고/간격 고정값 축소, size class 기반 크기 분기
    - `SafeArea + ConstrainedBox + SingleChildScrollView`로 작은 높이/큰 글꼴 오버플로우 방지
  - `permission_screen.dart` 적응형 1차 적용
    - 고정 `Column+Spacer` 구조를 스크롤 가능한 적응형 레이아웃으로 전환
    - 권한 카드 폭 기준(`LayoutBuilder`)으로 compact 레이아웃 분기
    - `withOpacity` 잔여 코드 `withValues`로 정리
  - `lib/ui/adaptive/window_class.dart` 추가
  - `lib/ui/adaptive/layout_tokens.dart` 추가
  - `lib/ui/adaptive/display_feature_utils.dart` 추가
  - `HomeTab` 리스트 패딩/간격을 토큰 기반으로 1차 전환
  - `dashboard_screen.dart`에 size class 기반 내비 전환 적용
    - compact: `NavigationBar`
    - expanded 이상: `NavigationRail`
  - `device_settings_tab.dart` / `git_management_tab.dart` / `logs_tab.dart`
    - size class 기반 max-width + 수평 패딩 토큰 적용
  - 공통 `section_tab_bar.dart`
    - size class 기반 탭 폰트/패딩/인디케이터 두께 토큰 적용
  - `git_tab.dart` 내부 1차 적응형화
    - 로그/하단 액션 영역 패딩 토큰화
    - 하단 액션 그리드 `crossAxisCount` 반응형 전환(1/2/4)
  - `git_tab.dart` 내부 2차 적응형화
    - 저장소 선택 바텀시트 패딩/행 밀도/서브타이틀 폰트 size class 분기
    - 브랜치 선택 다이얼로그 정보 라벨/값/서브텍스트 폰트 분기
    - 고급 Git 설정/현재 Git 상세정보 시트 패딩·폰트 size class 분기
    - 잔여 `withOpacity` 제거(`withValues`로 통일)
  - `carrot_settings_tab.dart` 내부 1차 적응형화
    - 검색/오류/리스트 패딩 토큰화
    - 설정 행 우측 컨트롤 폭/버튼 크기 size class 기반 분기
  - `carrot_settings_tab.dart` 내부 2차 적응형화
    - 설정 편집 시트(`_SettingEditSheet`) 수직 인셋/간격 토큰 분기
    - 메타 칩(`_MetaChip`) 패딩/폰트 분기
    - 즐겨찾기 메뉴/검색결과 피커/차량 선택 화면 패딩·간격·폰트 분기
    - 퀵 입력 다이얼로그/그룹 검색 바(아이콘·폰트·제약) size class 분기
    - 잔여 `withOpacity` 제거(`withValues`로 통일)
  - `logs_tab` 하위 뷰 1차 적응형화
    - `_DashcamLogsView`, `_RemoteVideoLogsView`, `_TmuxLogsView` 리스트/컨텐츠 패딩·간격 토큰화
    - 세그먼트 플레이어 다이얼로그 인셋/최소높이/최대높이 비율 size class 분기
    - `_LogsSubHeader` 패딩/설명 폰트 크기 size class 분기
  - `logs_tab` 하위 뷰 2차 적응형화
    - 대시캠 route/segment 행 배지/제목/서브텍스트/트레일링 폭 size class 분기
    - `_LogsSubHeader` 설명 간격 size class 분기
    - 세그먼트 공유 옵션 다이얼로그 inset/content/maxWidth size class 분기
  - `git_tab.dart` 내부 3차 적응형화
    - origin 변경/저장소 경로 설정/리모트 추가·수정·삭제 다이얼로그 inset/content/maxWidth 토큰화
    - 브랜치 선택 다이얼로그 자체 inset/content/maxWidth 및 커밋 URL fallback 팝업 토큰화
  - `logs_tab.dart` 하위 뷰 3차 적응형화
    - 대시캠 로딩/상태/대용량 공유 경고 다이얼로그 inset/content/maxWidth 토큰화
    - TMUX 블로킹 진행 다이얼로그 inset/content/maxWidth 토큰화
  - `backup_manager_screen.dart` 1차 심화 적응형화
    - 로컬/클라우드 선택 삭제, 단일 삭제, 백업 내용, Diff 복원 다이얼로그 inset/content/maxWidth 토큰화
    - 정렬 헤더/리스트 영역 max-width 제약, 카드 내부 패딩/칩·메타 텍스트 size class 분기
    - 상단 백업 진행 배너 인셋/간격/텍스트 크기 size class 분기
    - 잔여 `withOpacity` 제거(`withValues` 통일)
  - `connection_settings_widgets.dart` 1차 심화 적응형화
    - 페이지 패딩, 섹션 간격, 카드 패딩, 버튼 높이, 아이콘 액션 크기 제약을 size class 토큰 기반으로 전환
    - `connection_settings_screen.dart`에 adaptive 유틸 import 정리
  - `git_tab.dart` 하위 UI 미세 조정
    - Git 로그 패널(헤더 간격/로그 패딩/폰트), 하단 액션 그리드 간격, 브랜치 리스트 일부 텍스트/패딩 size class 분기
  - `git_tab.dart` Fold/대화면 로그 가시성 보강
    - 하단 액션 패널 최대 높이 제한 + 내부 스크롤
    - 버튼 그리드 childAspectRatio/열 분기 재튜닝으로 로그 영역 축소 완화
  - `git_tab.dart` Fold/대화면 로그 가시성 2차 보강
    - 하단 액션 패널 높이를 window class별로 추가 축소(Expanded~XL)
    - 버튼 그리드를 `mainAxisExtent` 기반으로 고정 높이화해 화면 폭 증가 시 과도한 버튼 높이 확장 방지
  - `git_tab.dart` Fold/대화면 로그 가시성 3차 보강
    - expanded+landscape에서 `로그(좌) + 액션(우)` 스플릿 레이아웃 도입
    - 로그 영역 높이 우선 확보, 비연결 상태에서도 오버플로우 없이 표시되도록 구조 개선
  - `carrot_settings_tab.dart` 하위 UI 미세 조정
    - 연결 필요/오류/차량 선택/주행설정 헤더 카드의 간격·패딩·검색필드 폭/폰트 size class 분기
  - `home_hud_preview_card.dart` 적응형/접근성 보강
    - `TextScaler.noScaling` 제거, window class별 clamp 스케일 적용
    - HUD 프리뷰 카드 `maxWidth`를 window class 기반으로 확장(Compact~XL)
  - `live_drive_canvas_screen.dart` 주변 UI(도크 폭/상태배너/검증패널/하단 알림 인셋) 상수 1차 적응형화
    - 주행 좌표/매핑 수학 로직은 미변경(원본 정합 유지)
  - `live_drive_canvas_screen.dart` 주변 UI 상수 2차 적응형화
    - 카메라 stall 배지/사이드카 상태 배너/오류·안내 배너/검증 패널의 패딩·반경·폰트·아이콘 크기 토큰화
    - window class별 배너 밀도/가독성 조정(Compact/Fold/Expanded 분기)
  - `live_drive_canvas_screen.dart` HUD 디버그 고정폭 잔여 정리
    - 디버그 텍스트 다이얼로그 폭(기존 640 고정) window class 분기 적용
    - 디버그 metric pill 최소폭(기존 148 고정) 및 내부 패딩 분기 적용
  - `live_drive_canvas_screen.dart`에 hinge/fold 추가 인셋(회피 패딩) 1차 적용
  - `live_drive_canvas_screen.dart` fold 인셋 계산 보정
    - 중앙 힌지/폴드에 대해 전체 화면을 한쪽으로 밀어내지 않도록 `DisplayFeatureUtils` 로직 수정
    - edge-anchored fold/hinge에만 추가 인셋을 적용해 폴드 에뮬레이터/와이드 화면 왜곡 완화
  - `ConnectionRequiredView` 오버플로우 방어 개선
    - 저높이 영역에서 margin/padding/icon 크기 자동 축소
    - `SingleChildScrollView` 래핑으로 좁은 높이에서도 안전 표시
  - `HUD 디버그` 팝업 레이아웃 개선
    - 와이드: 좌측 그룹 네비 + 우측 콘텐츠
    - 협소: 상단 가로 그룹 칩 + 전체폭 콘텐츠
    - 힌지 인셋 반영, 패딩/칩 간격/헤더 폰트 size class 분기
    - 정보 밀도 재구성: 핵심 상태(그리드) + 배포/버전 상세(그리드) 분리
  - `HUD 디버그` 상단 4개 성능 지표 줄바꿈 방지
    - `Wrap` → 가로 스크롤 `Row`로 전환해 항상 한 줄 유지
    - metric pill 최소폭/패딩 추가 축소로 폴드 가로모드에서 가독성 개선
  - `connection_settings_widgets.dart` 타이포/간격 하드코딩 1차 정리
    - 11/12/13 고정 폰트와 4/6/8/12 고정 간격을 size class 기반 metrics로 치환
    - 아이콘/스피너/버튼 패딩도 metrics 기반으로 통일
  - `carrot_backup_tab.dart` 필터/소스스위치 고정 높이 제거
    - `height: 36/40` 제거, `minHeight + size class` 분기로 변경
  - `dashcam_player_screen.dart` 공유 시트 썸네일 적응형화
    - `height: 88` 고정 제거, size class 기반 동적 높이 적용
  - `git_tab.dart` 폴드 와이드 액션 패널 여백/배치 보정
    - 우측 패널을 top-align으로 변경해 Reboot 하단 과다 여백 완화
  - `home_hud_preview_card.dart` 폴드 가로모드 배율 보정
    - window class 최대폭 + landscape 높이 상한 동시 적용으로 과대 HUD 축소

- 미완료(다음 페이즈):
  - 폴더블 hinge 회피 규칙 검증(실기기별 튜닝)
