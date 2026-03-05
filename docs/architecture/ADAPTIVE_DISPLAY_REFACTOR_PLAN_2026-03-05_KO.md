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
  - `lib/ui/adaptive/window_class.dart` 추가
  - `lib/ui/adaptive/layout_tokens.dart` 추가
  - `lib/ui/adaptive/display_feature_utils.dart` 추가
  - `HomeTab` 리스트 패딩/간격을 토큰 기반으로 1차 전환

- 미완료(다음 페이즈):
  - Dashboard/Settings/Git/Logs 탭의 토큰 기반 치환
  - HUD 주행화면 주변 UI(도크/배너/디버그 팝업) 적응형화
  - 폴더블 hinge 회피 규칙 실적용
