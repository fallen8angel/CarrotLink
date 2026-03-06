part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasSidecarTransportComponents
    on _LiveDriveCanvasScreenState {
  Uri _sidecarHttpUriImpl(String path, [Map<String, String>? query]) {
    return Uri(
      scheme: 'http',
      host: widget.hostIp,
      port: 7766,
      path: path,
      queryParameters: query,
    );
  }

  Future<Map<String, dynamic>> _sidecarGetJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(_sidecarHttpUri(path, query)).timeout(
            const Duration(seconds: 4),
          );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      final text = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: $text');
      }
      final decoded =
          text.trim().isEmpty ? <String, dynamic>{} : jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw Exception('invalid response');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _sidecarPostJson(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.postUrl(_sidecarHttpUri(path)).timeout(
            const Duration(seconds: 4),
          );
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.write(jsonEncode(body));
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      final text = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: $text');
      }
      final decoded =
          text.trim().isEmpty ? <String, dynamic>{} : jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw Exception('invalid response');
    } finally {
      client.close(force: true);
    }
  }
}
