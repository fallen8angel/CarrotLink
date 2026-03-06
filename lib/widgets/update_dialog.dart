import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/update_service.dart';
import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Consumer<UpdateService>(
      builder: (context, updateService, child) {
        final release = updateService.latestRelease;

        if (release == null) {
          return AlertDialog(
            title: const Text("업데이트 확인"),
            content: updateService.isChecking
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text("확인 중..."),
                    ],
                  )
                : const Text("최신 버전입니다."),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("확인"),
              ),
              if (!updateService.isChecking)
                ElevatedButton(
                  onPressed: () => updateService.checkForUpdate(),
                  child: const Text("다시 확인"),
                ),
            ],
          );
        }

        final String tagName = release['tag_name'] ?? "Unknown";
        final String body = release['body'] ?? "";

        return AlertDialog(
          title: Text("새로운 업데이트: $tagName"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("현재 버전: ${updateService.currentVersion}"),
                SizedBox(height: tokens.itemGap + 2),
                if (body.isNotEmpty) ...[
                  const Divider(),
                  const Text("변경 사항:",
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: tokens.itemGap - 2),
                  Text(
                    body,
                    style: TextStyle(fontSize: window.isCompact ? 12.5 : 13),
                  ),
                ],
                SizedBox(height: tokens.sectionGap + 2),
                if (updateService.isDownloading) ...[
                  LinearProgressIndicator(
                      value: updateService.downloadProgress),
                  SizedBox(height: tokens.itemGap + 2),
                  Text(
                      "${(updateService.downloadProgress * 100).toStringAsFixed(0)}%"),
                ] else if (updateService.downloadedFilePath != null) ...[
                  Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green),
                      const SizedBox(width: 8),
                      Text(
                        "다운로드 완료",
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
                if (updateService.statusMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      updateService.statusMessage,
                      style: TextStyle(
                        fontSize: window.isCompact ? 11.5 : 12,
                        color: updateService.statusMessage.contains("실패")
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                updateService.ignoreUpdateFor3Days();
                Navigator.pop(context);
              },
              child: const Text("3일간 무시"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("닫기"),
            ),
            if (updateService.downloadedFilePath != null)
              ElevatedButton(
                onPressed: () {
                  updateService.installUpdate();
                  Navigator.pop(context);
                },
                child: const Text("설치"),
              )
            else if (!updateService.isDownloading)
              ElevatedButton(
                onPressed: () => updateService.downloadUpdate(),
                child: const Text("다운로드"),
              ),
          ],
        );
      },
    );
  }
}
