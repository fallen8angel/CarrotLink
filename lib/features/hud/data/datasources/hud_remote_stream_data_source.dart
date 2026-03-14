import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:msgpack_dart/msgpack_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/hud_remote_stream_event.dart';

class HudRemoteStreamDataSource {
  final List<({int port, String path})> candidates;
  final Duration reconnectDelay;
  final Duration idleTimeout;
  final bool stickToPrimaryAfterSuccess;
  final String clientRole;

  const HudRemoteStreamDataSource({
    this.candidates = const <({int port, String path})>[
      (port: 7766, path: '/ws/hud'),
      (port: 7767, path: '/ws/hud'),
    ],
    this.reconnectDelay = const Duration(milliseconds: 250),
    // Healthy HUD relays send an initial snapshot immediately and then keep
    // emitting at ~10Hz. Raised to 4 s to absorb transient sidecar-side send
    // timeouts and recovery jitter while the broker switches between primary
    // and fallback HUD relays.
    this.idleTimeout = const Duration(milliseconds: 4000),
    this.stickToPrimaryAfterSuccess = true,
    this.clientRole = 'app_hud',
  });

  Stream<HudRemoteStreamEvent> watch({
    required String host,
  }) {
    late final StreamController<HudRemoteStreamEvent> controller;
    WebSocketChannel? channel;
    var disposed = false;
    DateTime? lastFailureReportedAt;
    String? lastFailureSummary;
    final primaryCandidate = candidates.isEmpty ? null : candidates.first;
    var primaryDeliveredOnce = false;
    final sessionId =
        'hud-${DateTime.now().microsecondsSinceEpoch}-${host.hashCode.abs()}';

    bool isPrimary(({int port, String path}) candidate) {
      if (primaryCandidate == null) {
        return false;
      }
      return candidate.port == primaryCandidate.port &&
          candidate.path == primaryCandidate.path;
    }

    Future<void> run() async {
      while (!disposed) {
        final failedCandidates = <String>[];
        var deliveredPayloadThisCycle = false;
        final activeCandidates = primaryDeliveredOnce &&
                primaryCandidate != null &&
                stickToPrimaryAfterSuccess
            ? <({int port, String path})>[
                primaryCandidate,
                ...candidates.where((candidate) => !isPrimary(candidate)),
              ]
            : candidates;
        for (final candidate in activeCandidates) {
          if (disposed) break;
          var deliveredPayload = false;
          try {
            final uri = Uri(
              scheme: 'ws',
              host: host,
              port: candidate.port,
              path: candidate.path,
              queryParameters: <String, String>{
                'encoding': 'msgpack',
                'role': clientRole,
                'session': sessionId,
              },
            );
            channel = WebSocketChannel.connect(uri);
            await channel!.ready;
            await for (final event in channel!.stream.timeout(idleTimeout)) {
              if (disposed) {
                break;
              }
              final payload = _decodePayload(event);
              if (payload != null) {
                deliveredPayload = true;
                if (isPrimary(candidate)) {
                  primaryDeliveredOnce = true;
                }
                controller.add(
                  HudRemoteStreamEvent(
                    payload: payload,
                    port: candidate.port,
                    path: candidate.path,
                    receivedAtMs: DateTime.now().millisecondsSinceEpoch,
                  ),
                );
                deliveredPayloadThisCycle = true;
                lastFailureReportedAt = null;
                lastFailureSummary = null;
              }
            }
          } catch (_, __) {
            if (deliveredPayload) {
              break;
            }
            failedCandidates.add('${candidate.port}${candidate.path}');
            // Ignore connection-refused and other transient startup races.
            // The reconnect loop below will retry shortly.
          } finally {
            await _closeChannel(channel);
            channel = null;
          }

          if (deliveredPayload) {
            break;
          }
        }

        // Transient startup races are expected while the broker/hud port is
        // still coming up. Keep retrying quietly instead of surfacing an
        // uncaught websocket error to the app layer on every refused connect.
        if (!disposed && !deliveredPayloadThisCycle) {
          final summary = failedCandidates.isEmpty
              ? 'HUD stream unavailable'
              : 'HUD stream unavailable (${failedCandidates.join(', ')})';
          final now = DateTime.now();
          final shouldReport = lastFailureSummary != summary ||
              lastFailureReportedAt == null ||
              now.difference(lastFailureReportedAt!) >=
                  const Duration(seconds: 5);
          if (shouldReport) {
            controller.addError(StateError(summary));
            lastFailureSummary = summary;
            lastFailureReportedAt = now;
          }
        }

        if (!disposed) {
          await Future<void>.delayed(reconnectDelay);
        }
      }
    }

    controller = StreamController<HudRemoteStreamEvent>(
      onListen: () {
        unawaited(run());
      },
      onCancel: () async {
        disposed = true;
        await _closeChannel(channel);
      },
    );

    return controller.stream;
  }

  Future<void> _closeChannel(WebSocketChannel? channel) async {
    if (channel == null) {
      return;
    }
    try {
      await channel.sink.close().timeout(const Duration(milliseconds: 700));
    } catch (_) {}
  }

  Map<String, dynamic>? _decodePayload(dynamic event) {
    dynamic decoded;
    if (event is String) {
      final rawText = event;
      if (rawText.trim().isEmpty) {
        return null;
      }
      decoded = jsonDecode(rawText);
    } else if (event is List<int>) {
      try {
        decoded = jsonDecode(utf8.decode(event, allowMalformed: true));
      } catch (_) {
        decoded = deserialize(Uint8List.fromList(event));
      }
    } else {
      return null;
    }

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
