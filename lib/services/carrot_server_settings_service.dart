import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/carrot_settings_models.dart';

class CarrotServerSettingsService {
  static const int defaultPort = 7000;
  static const Duration _timeout = Duration(seconds: 6);

  Uri _uri(String host, String path,
      {Map<String, String>? query, int port = defaultPort}) {
    return Uri(
      scheme: 'http',
      host: host,
      port: port,
      path: path,
      queryParameters: query,
    );
  }

  Future<CarrotSettingsBundle> fetchSettings(String host,
      {int port = defaultPort}) async {
    final response = await http
        .get(_uri(host, '/api/settings', port: port))
        .timeout(_timeout);
    final json = _decodeJson(response);
    _assertOk(json, response.statusCode);
    return CarrotSettingsBundle.fromJson(json);
  }

  Future<Map<String, dynamic>> fetchParamsBulk(
    String host,
    List<String> names, {
    int port = defaultPort,
  }) async {
    if (names.isEmpty) return const {};
    final response = await http
        .get(
          _uri(
            host,
            '/api/params_bulk',
            port: port,
            query: {'names': names.join(',')},
          ),
        )
        .timeout(_timeout);
    final json = _decodeJson(response);
    _assertOk(json, response.statusCode);
    final rawValues = json['values'];
    if (rawValues is! Map) return const {};
    return Map<String, dynamic>.from(rawValues);
  }

  Future<dynamic> setParam(
    String host, {
    required String name,
    required dynamic value,
    int port = defaultPort,
  }) async {
    final response = await http
        .post(
          _uri(host, '/api/param_set', port: port),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'name': name, 'value': value}),
        )
        .timeout(_timeout);
    final json = _decodeJson(response);
    _assertOk(json, response.statusCode);
    return json['value'];
  }

  Future<CarrotCarsBundle> fetchCars(String host,
      {int port = defaultPort}) async {
    final response =
        await http.get(_uri(host, '/api/cars', port: port)).timeout(_timeout);
    final json = _decodeJson(response);
    _assertOk(json, response.statusCode);
    return CarrotCarsBundle.fromJson(json);
  }

  Future<void> reboot(String host, {int port = defaultPort}) async {
    final response = await http.post(_uri(host, '/api/reboot', port: port),
        headers: const {'content-type': 'application/json'}).timeout(_timeout);
    final json = _decodeJson(response);
    _assertOk(json, response.statusCode);
  }

  Map<String, dynamic> _decodeJson(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    final dynamic decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw Exception('Invalid response');
    }
    return Map<String, dynamic>.from(decoded);
  }

  void _assertOk(Map<String, dynamic> json, int statusCode) {
    if (json['ok'] == true) return;
    final error = json['error']?.toString();
    throw Exception(error?.isNotEmpty == true ? error : 'HTTP $statusCode');
  }
}
