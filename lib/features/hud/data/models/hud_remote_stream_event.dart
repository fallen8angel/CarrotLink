class HudRemoteStreamEvent {
  final Map<String, dynamic> payload;
  final int port;
  final String path;
  final int receivedAtMs;

  const HudRemoteStreamEvent({
    required this.payload,
    required this.port,
    required this.path,
    required this.receivedAtMs,
  });
}
