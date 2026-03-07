import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

class HudRemoteStreamDataSource {
  final List<({int port, String path})> candidates;
  final Duration reconnectDelay;
  final Duration idleTimeout;

  const HudRemoteStreamDataSource({
    this.candidates = const <({int port, String path})>[
      (port: 7766, path: '/ws/hud'),
      (port: 7000, path: '/ws/carstate'),
    ],
    this.reconnectDelay = const Duration(seconds: 2),
    this.idleTimeout = const Duration(seconds: 12),
  });

  Stream<Map<String, dynamic>> watch({
    required String host,
  }) {
    late final StreamController<Map<String, dynamic>> controller;
    WebSocketChannel? channel;
    var disposed = false;

    Future<void> run() async {
      while (!disposed) {
        Object? lastError;
        StackTrace? lastStackTrace;
        for (final candidate in candidates) {
          if (disposed) break;
          var deliveredPayload = false;
          try {
            final uri = Uri.parse('ws://$host:${candidate.port}${candidate.path}');
            channel = WebSocketChannel.connect(uri);
            await for (final event in channel!.stream.timeout(idleTimeout)) {
              if (disposed) {
                break;
              }
              final payload = _decodePayload(event);
              if (payload != null) {
                deliveredPayload = true;
                controller.add(payload);
              }
            }
          } catch (error, stackTrace) {
            if (deliveredPayload) {
              lastError = null;
              lastStackTrace = null;
              break;
            }
            lastError = error;
            lastStackTrace = stackTrace;
          } finally {
            try {
              await channel?.sink.close();
            } catch (_) {}
            channel = null;
          }

          if (deliveredPayload) {
            lastError = null;
            lastStackTrace = null;
            break;
          }
        }

        if (!disposed && lastError != null) {
          controller.addError(lastError, lastStackTrace);
        }

        if (!disposed) {
          await Future<void>.delayed(reconnectDelay);
        }
      }
    }

    controller = StreamController<Map<String, dynamic>>(
      onListen: () {
        unawaited(run());
      },
      onCancel: () async {
        disposed = true;
        try {
          await channel?.sink.close();
        } catch (_) {}
      },
    );

    return controller.stream;
  }

  Map<String, dynamic>? _decodePayload(dynamic event) {
    final rawText = switch (event) {
      String value => value,
      List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      _ => null,
    };
    if (rawText == null || rawText.trim().isEmpty) {
      return null;
    }

    final decoded = jsonDecode(rawText);
    if (decoded is Map && decoded['type'] == 'hello') {
      return null;
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return null;
  }
}
