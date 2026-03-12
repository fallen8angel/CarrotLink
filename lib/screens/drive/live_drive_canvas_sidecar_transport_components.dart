part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasSidecarTransportComponents
    on _LiveDriveCanvasScreenState {
  static const int _sidecarPort = 7766;
  static const int _cameraPort = 7766;
  static const int _diagPort = 7769;

  Uri _sidecarHttpUriImpl(String path, [Map<String, String>? query]) {
    return Uri(
      scheme: 'http',
      host: _hostIp,
      port: _sidecarPort,
      path: path,
      queryParameters: query,
    );
  }

  Uri _cameraHttpUriImpl(String path, [Map<String, String>? query]) {
    return Uri(
      scheme: 'http',
      host: _hostIp,
      port: _cameraPort,
      path: path,
      queryParameters: query,
    );
  }

  Uri _diagHttpUriImpl(String path, [Map<String, String>? query]) {
    return Uri(
      scheme: 'http',
      host: _hostIp,
      port: _diagPort,
      path: path,
      queryParameters: query?.isEmpty ?? true ? null : query,
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

  Future<Map<String, dynamic>> _cameraGetJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(_cameraHttpUri(path, query)).timeout(
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

  Future<Map<String, dynamic>> _diagGetJson(
    String path, [
    Map<String, String>? query,
  ]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request =
          await client.getUrl(_diagHttpUriImpl(path, query)).timeout(
                const Duration(seconds: 3),
              );
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      final body = await utf8.decodeStream(response).timeout(
            const Duration(seconds: 5),
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode}: $body',
          uri: _diagHttpUriImpl(path, query),
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
      throw const FormatException('JSON object expected');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _cameraPostJson(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.postUrl(_cameraHttpUri(path)).timeout(
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
