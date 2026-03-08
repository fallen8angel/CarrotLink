# CarrotLink-dev 전수 파일 분석 보고서 (2026-02-26)

- 분석 경로: `D:\CarrotLink\CarrotLink-dev`
- 분석 방식: 파일 17,801개를 바이트 단위로 1개씩 순회 읽기 후 매니페스트 생성
- 매니페스트: `docs/_analysis/file_manifest_2026-02-26.csv`

## 1. 전수 스캔 요약

- 총 파일 수: **17801**
- 총 용량: **3662.13 MB**
- 텍스트 파일: **9368**
- 바이너리 파일: **8433**
- 관리대상(생성물 제외) 파일: **236**
- 생성/캐시 파일: **17565**

## 2. 최상위 디렉터리 파일 분포

| 디렉터리 | 파일 수 |
|---|---:|
| build | 17200 |
| .git | 179 |
| .dart_tool | 83 |
| android | 82 |
| windows | 65 |
| lib | 56 |
| ios | 51 |
| macos | 30 |
| .idea | 11 |
| linux | 10 |
| docs | 8 |
| web | 7 |
| tools | 3 |
| scripts | 3 |
| test | 2 |
| assets | 2 |
| README.md | 1 |
| pubspec.yaml | 1 |
| logs | 1 |
| process_icon.py | 1 |
| .flutter-plugins-dependencies | 1 |
| .gitignore | 1 |
| analysis_options.yaml | 1 |
| pubspec.lock | 1 |
| .metadata | 1 |

## 3. 상위 확장자 분포 (Top 30)

| 확장자 | 파일 수 |
|---|---:|
| .xml | 4586 |
| .flat | 3972 |
| .json | 2010 |
| .png | 1440 |
| .class | 1310 |
| .h | 1292 |
| .txt | 601 |
| .dex | 484 |
| (noext) | 448 |
| .jar | 214 |
| .bin | 148 |
| .tlog | 118 |
| .properties | 107 |
| .len | 66 |
| .dart | 61 |
| .1 | 48 |
| .aar | 47 |
| .stamp | 44 |
| .cmake | 43 |
| .log | 42 |
| .so | 38 |
| .kotlin_module | 34 |
| .vcxproj | 31 |
| .filters | 28 |
| .d | 25 |
| .tab | 24 |
| .rule | 23 |
| .obj | 23 |
| .at | 22 |
| .keystream | 22 |

## 4. 대용량 파일 Top 20

| 경로 | 크기(MB) |
|---|---:|
| $((Norm @{rel_path=build\app\intermediates\merged_native_libs\debug\mergeDebugNativeLibs\out\lib\arm64-v8a\libflutter.so; top_dir=build; extension=.so; size_bytes=358456968; is_text=False; line_count=; todo_count=; fixme_count=; sha256=7bbef76ed4d8c2f1157e3c67f13b7377527e9bf4b491b678a2ed3b7c58457b90; last_write=2026-02-26T05:39:14.4336105Z}.rel_path)) | 341.85 |
| $((Norm @{rel_path=windows\flutter\ephemeral\flutter_windows.dll.pdb; top_dir=windows; extension=.pdb; size_bytes=252186624; is_text=False; line_count=; todo_count=; fixme_count=; sha256=5f101035602ff3d80f895d9c3735c9c04fe2811e713941cab3cc28b5b741243c; last_write=2025-11-21T15:54:16.0929550Z}.rel_path)) | 240.5 |
| $((Norm @{rel_path=build\app\intermediates\merged_native_libs\debug\mergeDebugNativeLibs\out\lib\arm64-v8a\libVkLayer_khronos_validation.so; top_dir=build; extension=.so; size_bytes=233032976; is_text=False; line_count=; todo_count=; fixme_count=; sha256=b15afdb137bf5bfc886a2ffd1299826cd25d828b606f3aaf1f0fdb23dbe56e01; last_write=2026-02-26T05:39:12.8160960Z}.rel_path)) | 222.24 |
| $((Norm @{rel_path=build\app\intermediates\incremental\debug-mergeJavaRes\zip-cache\zXoUwIFF0adwrnst6rPfZ41gGew=; top_dir=build; extension=(noext); size_bytes=168478005; is_text=False; line_count=; todo_count=; fixme_count=; sha256=f90bf6e3d0ee1d8ca15a3fc1cde9647b18ba1437b8a5f6dee62146bf43b5df49; last_write=2026-02-26T01:59:56.8857163Z}.rel_path)) | 160.67 |
| $((Norm @{rel_path=build\app\intermediates\merged_native_libs\release\mergeReleaseNativeLibs\out\lib\x86_64\libflutter.so; top_dir=build; extension=.so; size_bytes=144837816; is_text=False; line_count=; todo_count=; fixme_count=; sha256=f1ec35f1d0e2e610b3445abd3263a66af8ca9ae28033591ae21be9a1a9cc616d; last_write=2026-02-26T04:03:38.6407490Z}.rel_path)) | 138.13 |
| $((Norm @{rel_path=build\app\intermediates\merged_native_libs\release\mergeReleaseNativeLibs\out\lib\arm64-v8a\libflutter.so; top_dir=build; extension=.so; size_bytes=144312672; is_text=False; line_count=; todo_count=; fixme_count=; sha256=6d771b6c5b0cf98f9fd1bcc62d15c40347d89c8f8430333b73e8c15df4053a8d; last_write=2026-02-26T04:03:38.0821653Z}.rel_path)) | 137.63 |
| $((Norm @{rel_path=build\app\intermediates\merged_native_libs\release\mergeReleaseNativeLibs\out\lib\armeabi-v7a\libflutter.so; top_dir=build; extension=.so; size_bytes=131381824; is_text=False; line_count=; todo_count=; fixme_count=; sha256=5be592fb4317fe854846ec409d3127c5b27a82ea25b60c8010b291beb9a70898; last_write=2026-02-26T04:03:37.6157858Z}.rel_path)) | 125.3 |
| $((Norm @{rel_path=build\app\outputs\flutter-apk\app-debug.apk; top_dir=build; extension=.apk; size_bytes=122403646; is_text=False; line_count=; todo_count=; fixme_count=; sha256=84992ead1611499c22d1366ac80d71f9bdd98b627a843588bcacd47dba560aa7; last_write=2026-02-26T11:33:39.1994920Z}.rel_path)) | 116.73 |
| $((Norm @{rel_path=build\app\outputs\apk\debug\app-debug.apk; top_dir=build; extension=.apk; size_bytes=122403646; is_text=False; line_count=; todo_count=; fixme_count=; sha256=84992ead1611499c22d1366ac80d71f9bdd98b627a843588bcacd47dba560aa7; last_write=2026-02-26T11:33:38.4762768Z}.rel_path)) | 116.73 |
| $((Norm @{rel_path=build\app\intermediates\incremental\debug-mergeJavaRes\zip-cache\aKI6l_wtFaZGxRtFS3Fg7inrmx8=; top_dir=build; extension=(noext); size_bytes=110296701; is_text=False; line_count=; todo_count=; fixme_count=; sha256=7ce699da82c9557b3f7e37aca0b4c6dad71b94bb203840f77fac56e452168ad7; last_write=2026-02-26T01:59:57.1686246Z}.rel_path)) | 105.19 |
| $((Norm @{rel_path=build\app\intermediates\incremental\debug-mergeJavaRes\zip-cache\lKHfTU2s990fATbkgvNk6ne68+8=; top_dir=build; extension=(noext); size_bytes=106004008; is_text=False; line_count=; todo_count=; fixme_count=; sha256=180d3a9bbc2bab83d1392bde93c00c8c729d6f1b0ba920ba0f22c874cd1549cb; last_write=2026-02-26T01:59:56.4654898Z}.rel_path)) | 101.09 |
| $((Norm @{rel_path=build\4df1b2fdd203e67cc7c260e1a493e869.cache.dill.track.dill; top_dir=build; extension=.dill; size_bytes=87805720; is_text=False; line_count=; todo_count=; fixme_count=; sha256=c29fa0ed4a96750f1377bbe8239783d831574538b5bdf5f5f3a07c9ba00fe653; last_write=2026-02-26T11:33:06.5176828Z}.rel_path)) | 83.74 |
| $((Norm @{rel_path=.dart_tool\flutter_build\7a600fe1c778a26ade9ff87c6fb7bb9c\app.dill; top_dir=.dart_tool; extension=.dill; size_bytes=87805720; is_text=False; line_count=; todo_count=; fixme_count=; sha256=c29fa0ed4a96750f1377bbe8239783d831574538b5bdf5f5f3a07c9ba00fe653; last_write=2026-02-26T11:33:20.4023362Z}.rel_path)) | 83.74 |
| $((Norm @{rel_path=build\app\intermediates\flutter\debug\flutter_assets\kernel_blob.bin; top_dir=build; extension=.bin; size_bytes=87805720; is_text=False; line_count=; todo_count=; fixme_count=; sha256=c29fa0ed4a96750f1377bbe8239783d831574538b5bdf5f5f3a07c9ba00fe653; last_write=2026-02-26T11:33:20.4023362Z}.rel_path)) | 83.74 |
| $((Norm @{rel_path=build\app\intermediates\assets\debug\mergeDebugAssets\flutter_assets\kernel_blob.bin; top_dir=build; extension=.bin; size_bytes=87805720; is_text=False; line_count=; todo_count=; fixme_count=; sha256=c29fa0ed4a96750f1377bbe8239783d831574538b5bdf5f5f3a07c9ba00fe653; last_write=2026-02-26T11:33:31.6863467Z}.rel_path)) | 83.74 |
| $((Norm @{rel_path=.dart_tool\flutter_build\0abc591b92a9facc5cb3170a64f93896\app.dill; top_dir=.dart_tool; extension=.dill; size_bytes=84735912; is_text=False; line_count=; todo_count=; fixme_count=; sha256=1c161bebb151783e078e42aa55c99247b6f69dd222a7d72c469f719b4e3ebb9a; last_write=2026-02-26T05:34:31.0408872Z}.rel_path)) | 80.81 |
| $((Norm @{rel_path=build\windows\x64\runner\Debug\data\flutter_assets\kernel_blob.bin; top_dir=build; extension=.bin; size_bytes=84735912; is_text=False; line_count=; todo_count=; fixme_count=; sha256=1c161bebb151783e078e42aa55c99247b6f69dd222a7d72c469f719b4e3ebb9a; last_write=2026-02-26T05:34:31.0408872Z}.rel_path)) | 80.81 |
| $((Norm @{rel_path=build\flutter_assets\kernel_blob.bin; top_dir=build; extension=.bin; size_bytes=84735912; is_text=False; line_count=; todo_count=; fixme_count=; sha256=1c161bebb151783e078e42aa55c99247b6f69dd222a7d72c469f719b4e3ebb9a; last_write=2026-02-26T05:34:31.0408872Z}.rel_path)) | 80.81 |
| $((Norm @{rel_path=.dart_tool\flutter_build\6cbd955cf1cf56d85373c7cccff358fa\app.dill; top_dir=.dart_tool; extension=.dill; size_bytes=84695704; is_text=False; line_count=; todo_count=; fixme_count=; sha256=2aa6cbc15818fda14e84f7077bac807da4a34c3041433dd4d2f45788814c0b7d; last_write=2026-02-26T01:56:45.8037363Z}.rel_path)) | 80.77 |
| $((Norm @{rel_path=build\app\outputs\apk\release\app-release.apk; top_dir=build; extension=.apk; size_bytes=63244765; is_text=False; line_count=; todo_count=; fixme_count=; sha256=611896e16610bef3df272cbffd4a3c2132c0b4e889f873f4e05d919f5dc281ce; last_write=2026-02-26T04:05:12.0151103Z}.rel_path)) | 60.31 |

## 5. Dart 코드 규모(Tracked)

- Tracked Dart 파일 수: **0**
- Tracked Dart 총 라인 수: ****

| Dart 파일 | 라인 수 |
|---|---:|

## 6. 추적(Tracked) 파일 개별 인벤토리

아래는 `git ls-files` 기준 전 파일을 1개씩 읽어 매니페스트와 매칭한 목록이다.

| 경로 | 크기(byte) | 라인수 | 분류 | 비고 |
|---|---:|---:|---|---|
| $(.gitignore) | 800 | 50 | root-config |  |
| $(.metadata) | 1751 | 46 | root-config |  |
| $(analysis_options.yaml) | 1448 | 29 | root-config |  |
| $(android/.gitignore) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/build.gradle.kts) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/google-services.json) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/debug/AndroidManifest.xml) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/AndroidManifest.xml) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/kotlin/com/example/carrot_pilot_manager/MainActivity.kt) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/drawable-v21/launch_background.xml) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/drawable/launch_background.xml) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/mipmap-hdpi/ic_launcher.png) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/mipmap-hdpi/launcher_icon.png) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/mipmap-mdpi/ic_launcher.png) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/mipmap-mdpi/launcher_icon.png) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/mipmap-xhdpi/ic_launcher.png) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/mipmap-xhdpi/launcher_icon.png) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/mipmap-xxhdpi/launcher_icon.png) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/mipmap-xxxhdpi/launcher_icon.png) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/values-night/styles.xml) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/main/res/values/styles.xml) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/app/src/profile/AndroidManifest.xml) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/build.gradle.kts) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/gradle.properties) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/gradle/wrapper/gradle-wrapper.properties) | - | - | platform-android | 매니페스트 미매칭 |
| $(android/settings.gradle.kts) | - | - | platform-android | 매니페스트 미매칭 |
| $(assets/icon.png) | - | - | asset | 매니페스트 미매칭 |
| $(assets/original_icon.jpg) | - | - | asset | 매니페스트 미매칭 |
| $(docs/architecture/core/CODEBASE_DEEP_ANALYSIS_2026-02-26_KO.md) | - | - | docs | 매니페스트 미매칭 |
| $(docs/architecture/core/DEV_STRUCTURE_REFACTOR_2026-02-26.md) | - | - | docs | 매니페스트 미매칭 |
| $(docs/MASTER_DEVELOPMENT_GUIDE_KO.md) | - | - | docs | 매니페스트 미매칭 |
| $(docs/operations/APK_SCRIPT_USAGE_KO.md) | - | - | docs | 매니페스트 미매칭 |
| $(docs/operations/CARROTMAN_APK_SET_PATH_KO.md) | - | - | docs | 매니페스트 미매칭 |
| $(docs/operations/GIT_SYSTEM_TAB_SSH_COMMANDS_KO.md) | - | - | docs | 매니페스트 미매칭 |
| $(docs/operations/TERMINAL_BUILD_INSTALL_COMMANDS_KO.md) | - | - | docs | 매니페스트 미매칭 |
| $(docs/README.md) | - | - | docs | 매니페스트 미매칭 |
| $(ios/.gitignore) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Flutter/AppFrameworkInfo.plist) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Flutter/Debug.xcconfig) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Flutter/Release.xcconfig) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner.xcodeproj/project.pbxproj) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner.xcodeproj/project.xcworkspace/contents.xcworkspacedata) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner.xcworkspace/contents.xcworkspacedata) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/AppDelegate.swift) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-50x50@1x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-50x50@2x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-57x57@1x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-57x57@2x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-72x72@1x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-72x72@2x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/LaunchImage.imageset/Contents.json) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Base.lproj/LaunchScreen.storyboard) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Base.lproj/Main.storyboard) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Info.plist) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/Runner/Runner-Bridging-Header.h) | - | - | platform-ios | 매니페스트 미매칭 |
| $(ios/RunnerTests/RunnerTests.swift) | - | - | platform-ios | 매니페스트 미매칭 |
| $(lib/constants.dart) | - | - | app-core | 매니페스트 미매칭 |
| $(lib/main.dart) | - | - | app-core | 매니페스트 미매칭 |
| $(lib/models/carrot_settings_models.dart) | - | - | app-model | 매니페스트 미매칭 |
| $(lib/screens/backup_manager_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/dashboard_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/diagnostics_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/github_login_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/github_verification_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/permission_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings/backup_settings_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings/connection_settings_auth.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings/connection_settings_discovery.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings/connection_settings_keys.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings/connection_settings_persistence.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings/connection_settings_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings/connection_settings_widgets.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings/info_settings_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings/settings_home_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/settings/share_settings_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/splash_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/carrot_settings_tab.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/file_editor_screen.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/file_explorer_tab.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/file_explorer/file_explorer_controller.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/file_explorer/widgets/file_explorer_bottom_bar.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/file_explorer/widgets/file_explorer_file_list_view.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/file_explorer/widgets/file_explorer_top_toolbar.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/git_management_tab.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/git_tab.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/home_tab.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/logs_tab.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/macro_tab.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/system_tab.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/screens/tabs/terminal_tab.dart) | - | - | app-screen | 매니페스트 미매칭 |
| $(lib/services/background_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/backup_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/carrot_server_settings_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/device_action_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/diagnostics_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/github_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/google_drive_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/key_backup_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/macro_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/ssh_key_helper.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/ssh_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/storage_layout_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/services/update_service.dart) | - | - | app-service | 매니페스트 미매칭 |
| $(lib/theme/app_theme.dart) | - | - | app-theme | 매니페스트 미매칭 |
| $(lib/widgets/command_execution_dialog.dart) | - | - | app-widget | 매니페스트 미매칭 |
| $(lib/widgets/custom_toast.dart) | - | - | app-widget | 매니페스트 미매칭 |
| $(lib/widgets/design_components.dart) | - | - | app-widget | 매니페스트 미매칭 |
| $(lib/widgets/drive_list_widget.dart) | - | - | app-widget | 매니페스트 미매칭 |
| $(lib/widgets/section_tab_bar.dart) | - | - | app-widget | 매니페스트 미매칭 |
| $(lib/widgets/update_dialog.dart) | - | - | app-widget | 매니페스트 미매칭 |
| $(lib/widgets/video_list_widget.dart) | - | - | app-widget | 매니페스트 미매칭 |
| $(linux/.gitignore) | - | - | platform-linux | 매니페스트 미매칭 |
| $(linux/CMakeLists.txt) | - | - | platform-linux | 매니페스트 미매칭 |
| $(linux/flutter/CMakeLists.txt) | - | - | platform-linux | 매니페스트 미매칭 |
| $(linux/flutter/generated_plugin_registrant.cc) | - | - | platform-linux | 매니페스트 미매칭 |
| $(linux/flutter/generated_plugin_registrant.h) | - | - | platform-linux | 매니페스트 미매칭 |
| $(linux/flutter/generated_plugins.cmake) | - | - | platform-linux | 매니페스트 미매칭 |
| $(linux/runner/CMakeLists.txt) | - | - | platform-linux | 매니페스트 미매칭 |
| $(linux/runner/main.cc) | - | - | platform-linux | 매니페스트 미매칭 |
| $(linux/runner/my_application.cc) | - | - | platform-linux | 매니페스트 미매칭 |
| $(linux/runner/my_application.h) | - | - | platform-linux | 매니페스트 미매칭 |
| $(logs/.gitkeep) | - | - | root-config | 매니페스트 미매칭 |
| $(macos/.gitignore) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Flutter/Flutter-Debug.xcconfig) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Flutter/Flutter-Release.xcconfig) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Flutter/GeneratedPluginRegistrant.swift) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner.xcodeproj/project.pbxproj) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner.xcworkspace/contents.xcworkspacedata) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/AppDelegate.swift) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_64.png) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Base.lproj/MainMenu.xib) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Configs/AppInfo.xcconfig) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Configs/Debug.xcconfig) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Configs/Release.xcconfig) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Configs/Warnings.xcconfig) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/DebugProfile.entitlements) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Info.plist) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/MainFlutterWindow.swift) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/Runner/Release.entitlements) | - | - | platform-macos | 매니페스트 미매칭 |
| $(macos/RunnerTests/RunnerTests.swift) | - | - | platform-macos | 매니페스트 미매칭 |
| $(process_icon.py) | 688 | 23 | root-config |  |
| $(pubspec.lock) | 37891 | 1211 | root-config |  |
| $(pubspec.yaml) | 1273 | 59 | root-config | 패키지 의존성/버전 |
| $(README.md) | 1287 | 58 | root-config | 문서 파일 |
| $(scripts/apk_menu.ps1) | - | - | script | 매니페스트 미매칭 |
| $(scripts/build_dev_apk.ps1) | - | - | script | 매니페스트 미매칭 |
| $(scripts/check_ssh.dart) | - | - | script | 매니페스트 미매칭 |
| $(test/ssh_key_check.dart) | - | - | test | 매니페스트 미매칭 |
| $(test/widget_test.dart) | - | - | test | 매니페스트 미매칭 |
| $(tools/windows/apk_menu.cmd) | - | - | tool-wrapper | 매니페스트 미매칭 |
| $(tools/windows/oneclick_install_existing_release.cmd) | - | - | tool-wrapper | 매니페스트 미매칭 |
| $(tools/windows/oneclick_release_build_install.cmd) | - | - | tool-wrapper | 매니페스트 미매칭 |
| $(web/favicon.png) | - | - | platform-web | 매니페스트 미매칭 |
| $(web/icons/Icon-192.png) | - | - | platform-web | 매니페스트 미매칭 |
| $(web/icons/Icon-512.png) | - | - | platform-web | 매니페스트 미매칭 |
| $(web/icons/Icon-maskable-192.png) | - | - | platform-web | 매니페스트 미매칭 |
| $(web/icons/Icon-maskable-512.png) | - | - | platform-web | 매니페스트 미매칭 |
| $(web/index.html) | - | - | platform-web | 매니페스트 미매칭 |
| $(web/manifest.json) | - | - | platform-web | 매니페스트 미매칭 |
| $(windows/.gitignore) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/CMakeLists.txt) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/flutter/CMakeLists.txt) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/flutter/generated_plugin_registrant.cc) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/flutter/generated_plugin_registrant.h) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/flutter/generated_plugins.cmake) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/CMakeLists.txt) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/flutter_window.cpp) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/flutter_window.h) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/main.cpp) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/resource.h) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/resources/app_icon.ico) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/runner.exe.manifest) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/Runner.rc) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/utils.cpp) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/utils.h) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/win32_window.cpp) | - | - | platform-windows | 매니페스트 미매칭 |
| $(windows/runner/win32_window.h) | - | - | platform-windows | 매니페스트 미매칭 |

## 7. 핵심 진단

- `build/` 폴더가 파일 수의 절대다수(17,200개)이며 분석 노이즈의 핵심 원인이다.
- 유지보수 실질 대상은 `lib/` + `scripts/` + `docs/` + 플랫폼 설정(Tracked 215개 중심)이다.
- `android/app/google-services.json` 등 민감 설정 파일이 존재하므로 배포/공유 정책 분리 필요.
- `windows/flutter/ephemeral`, `ios/Flutter/ephemeral`, `android/.gradle`은 생성물로 정기 정리 가능하다.

