import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'diagnostics_service.dart';
import 'storage_layout_service.dart';

enum GitHubTokenValidationStatus {
  missing,
  valid,
  invalid,
  insufficientScope,
  transientError,
}

class GitHubService {
  static const String _baseUrl = 'https://api.github.com';
  static const String _oauthScopes = 'admin:public_key gist repo';
  // Homepage URL: http://localhost
  // Authorization callback URL: http://localhost
  static const String _clientId = 'Ov23lis2qk24z3GryKlt';
  static const String _tokenMirrorFileName = 'github_token_v1.json';
  static const String _keyringSchema = 'clink.ssh.keyring.v1';
  static const String _keyringFileName = 'clink_ssh_keyring_v1.json';
  static const String _keyringDescriptionPrefix = 'CLINK|SSH_KEYRING|v1';
  static const String _keyringEnv = 'prod';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final DiagnosticsService _diag = DiagnosticsService.instance;

  Future<Map<String, dynamic>> initiateDeviceFlow() async {
    _diag.info('github_oauth', 'Initiating GitHub device flow');
    final response = await http.post(
      Uri.parse('https://github.com/login/device/code'),
      headers: {'Accept': 'application/json'},
      body: {
        'client_id': _clientId,
        'scope': _oauthScopes,
      },
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final intervalRaw = data['interval'];
      final expiresRaw = data['expires_in'];
      final interval = intervalRaw is int
          ? intervalRaw
          : int.tryParse(intervalRaw?.toString() ?? '') ?? 5;
      final expiresIn = expiresRaw is int
          ? expiresRaw
          : int.tryParse(expiresRaw?.toString() ?? '') ?? 900;
      _diag.info(
        'github_oauth',
        'Device flow started interval=${interval}s expires=${expiresIn}s',
      );

      // Some environments/apps may not return verification_uri_complete consistently.
      // Build a fallback URL so users can skip manual 8-digit input.
      if ((data['verification_uri_complete'] == null ||
              data['verification_uri_complete'].toString().isEmpty) &&
          data['verification_uri'] != null &&
          data['user_code'] != null) {
        final verificationUri = data['verification_uri'].toString();
        final userCode = data['user_code'].toString();
        data['verification_uri_complete'] =
            '$verificationUri?user_code=${Uri.encodeQueryComponent(userCode)}';
      }

      return data;
    } else {
      try {
        final errorData = jsonDecode(response.body);
        _diag.warn(
          'github_oauth',
          'Device flow init failed status=${response.statusCode} error=${errorData['error']}',
        );
        if (errorData['error'] == 'device_flow_disabled') {
          throw Exception(
              'GitHub 앱 설정에서 Device Flow가 활성화되지 않았습니다. 개발자에게 문의하거나 설정을 확인하세요.');
        }
        throw Exception(errorData['error_description'] ?? response.body);
      } catch (e) {
        if (e.toString().contains('Device Flow')) rethrow;
        throw Exception('Failed to initiate device flow: ${response.body}');
      }
    }
  }

  Future<String?> pollForToken(String deviceCode) async {
    final response = await http.post(
      Uri.parse('https://github.com/login/oauth/access_token'),
      headers: {'Accept': 'application/json'},
      body: {
        'client_id': _clientId,
        'device_code': deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      },
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data.containsKey('access_token')) {
        _diag.info('github_oauth', 'Token polling success');
        return data['access_token'];
      } else if (data['error'] == 'authorization_pending') {
        _diag.info('github_oauth', 'Token polling pending');
        return null;
      } else if (data['error'] == 'slow_down') {
        _diag.warn('github_oauth', 'Token polling asked to slow_down');
        throw Exception('slow_down');
      } else if (data['error'] == 'expired_token') {
        _diag.warn('github_oauth', 'Token polling expired_token');
        throw Exception('expired_token');
      } else {
        // access_denied or other errors
        _diag.warn(
          'github_oauth',
          'Token polling error=${data['error']} desc=${data['error_description']}',
        );
        throw Exception(data['error_description'] ?? data['error']);
      }
    } else {
      _diag.warn(
        'github_oauth',
        'Token polling failed status=${response.statusCode}',
      );
      throw Exception('Failed to poll token: ${response.body}');
    }
  }

  Future<void> saveToken(String token) async {
    await _storage.write(key: 'github_token', value: token);
    await _saveTokenMirror(token);
  }

  Future<String?> getToken() async {
    final stored = await _storage.read(key: 'github_token');
    if (stored != null && stored.isNotEmpty) return stored;

    final mirrored = await _readTokenMirror();
    if (mirrored != null && mirrored.isNotEmpty) {
      await _storage.write(key: 'github_token', value: mirrored);
      return mirrored;
    }

    return null;
  }

  Future<void> clearToken() async {
    await _storage.delete(key: 'github_token');
    await _deleteTokenMirror();
  }

  Future<bool> isLoggedIn() async {
    return (await getToken()) != null;
  }

  Future<Map<String, dynamic>?> getUserInfo() async {
    final token = await getToken();
    if (token == null) return null;

    final response = await http.get(
      Uri.parse('$_baseUrl/user'),
      headers: {
        'Authorization': 'token $token',
        'Accept': 'application/vnd.github.v3+json',
      },
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    return null;
  }

  Future<GitHubTokenValidationStatus> validateSavedToken() async {
    final token = await getToken();
    if (token == null || token.isEmpty) {
      return GitHubTokenValidationStatus.missing;
    }

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/user'),
        headers: {
          'Authorization': 'token $token',
          'Accept': 'application/vnd.github.v3+json',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        if (!_hasRequiredScope(response.headers)) {
          _diag.warn(
            'github',
            'Saved token missing required scopes admin:public_key + gist + repo '
                'scopes=${response.headers['x-oauth-scopes'] ?? ''}',
          );
          return GitHubTokenValidationStatus.insufficientScope;
        }
        return GitHubTokenValidationStatus.valid;
      }
      if (response.statusCode == 401) {
        _diag.warn('github', 'Saved token is invalid (401)');
        return GitHubTokenValidationStatus.invalid;
      }

      _diag.warn(
          'github', 'Token validation temporary status=${response.statusCode}');
      return GitHubTokenValidationStatus.transientError;
    } catch (e) {
      _diag.warn('github', 'Token validation transient error: $e');
      return GitHubTokenValidationStatus.transientError;
    }
  }

  Future<List<Map<String, dynamic>>> listPublicKeys() async {
    final token = await getToken();
    if (token == null) throw Exception("Not logged in");

    final allKeys = <Map<String, dynamic>>[];
    var page = 1;

    while (true) {
      final response = await http.get(
        Uri.parse('$_baseUrl/user/keys?per_page=100&page=$page'),
        headers: {
          'Authorization': 'token $token',
          'Accept': 'application/vnd.github.v3+json',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw _buildGitHubApiException('키 목록 조회', response);
      }

      final List<dynamic> data = jsonDecode(response.body);
      final pageItems = data.cast<Map<String, dynamic>>();
      allKeys.addAll(pageItems);

      if (pageItems.length < 100) {
        break;
      }
      page += 1;
    }

    return allKeys;
  }

  /// Uploads a public key and returns the created key's ID, or null on failure.
  Future<int?> uploadPublicKey(String title, String key) async {
    final token = await getToken();
    if (token == null) throw Exception("Not logged in");

    final response = await http
        .post(
          Uri.parse('$_baseUrl/user/keys'),
          headers: {
            'Authorization': 'token $token',
            'Accept': 'application/vnd.github.v3+json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'title': title,
            'key': key,
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 201) {
      final data = jsonDecode(response.body);
      return data['id'] as int?;
    } else {
      throw _buildGitHubApiException('SSH 키 등록', response);
    }
  }

  // Key generation moved to SSHKeyHelper

  Future<bool> deletePublicKey(int keyId) async {
    final token = await getToken();
    if (token == null) throw Exception("Not logged in");

    final response = await http.delete(
      Uri.parse('$_baseUrl/user/keys/$keyId'),
      headers: {
        'Authorization': 'token $token',
        'Accept': 'application/vnd.github.v3+json',
      },
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode == 204) {
      return true;
    } else {
      throw _buildGitHubApiException('SSH 키 삭제', response);
    }
  }

  Future<Map<String, dynamic>?> loadManagedKeyring() async {
    final token = await getToken();
    if (token == null) throw Exception('Not logged in');

    final ownerTag = await _resolveOwnerTag();
    final gistId = await _findManagedKeyringGistId(token);
    if (gistId == null || gistId.isEmpty) {
      return null;
    }

    final gist = await _getGistDetail(token, gistId);
    if (gist == null) {
      return null;
    }

    final files = gist['files'];
    if (files is! Map<String, dynamic>) {
      return null;
    }
    final file = files[_keyringFileName];
    if (file is! Map<String, dynamic>) {
      return null;
    }
    final content = file['content']?.toString();
    if (content == null || content.trim().isEmpty) {
      return null;
    }

    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final payload = Map<String, dynamic>.from(decoded);
    payload['__gistId'] = gistId;
    payload['__ownerTag'] = ownerTag;
    return payload;
  }

  Future<void> upsertManagedKeyringKey({
    required String privateKeyPem,
    required String title,
    int? githubKeyId,
    bool setActive = true,
  }) async {
    final token = await getToken();
    if (token == null) throw Exception('Not logged in');

    final publicKey = await getPublicKeyFromPrivateKey(privateKeyPem);
    if (publicKey == null || publicKey.isEmpty) {
      throw Exception('개인키에서 공개키를 추출하지 못했습니다.');
    }
    final fingerprint = _fingerprintFromPublicKey(publicKey);
    final ownerTag = await _resolveOwnerTag();
    final existing = await loadManagedKeyring();
    final gistId = existing?['__gistId']?.toString();

    final payload = existing == null
        ? _newManagedKeyringPayload(ownerTag: ownerTag)
        : Map<String, dynamic>.from(existing)
      ..remove('__gistId')
      ..remove('__ownerTag');

    final rawKeys = payload['keys'];
    final keys = <Map<String, dynamic>>[];
    if (rawKeys is List) {
      for (final item in rawKeys) {
        if (item is Map<String, dynamic>) {
          keys.add(Map<String, dynamic>.from(item));
        } else if (item is Map) {
          keys.add(Map<String, dynamic>.from(item.cast<String, dynamic>()));
        }
      }
    }

    final now = DateTime.now().toUtc().toIso8601String();
    int matchIndex = keys.indexWhere(
      (k) => k['fingerprint']?.toString() == fingerprint,
    );
    if (matchIndex < 0 && githubKeyId != null) {
      matchIndex = keys.indexWhere(
        (k) => k['githubKeyId']?.toString() == githubKeyId.toString(),
      );
    }

    final newEntry = <String, dynamic>{
      'fingerprint': fingerprint,
      'githubKeyId': githubKeyId,
      'title': title,
      'privateKeyPem': privateKeyPem,
      'updatedAt': now,
      'createdAt':
          matchIndex >= 0 ? keys[matchIndex]['createdAt']?.toString() : now,
    };

    if (matchIndex >= 0) {
      keys[matchIndex] = newEntry;
    } else {
      keys.add(newEntry);
    }

    payload['schema'] = _keyringSchema;
    payload['owner'] = ownerTag;
    payload['env'] = _keyringEnv;
    payload['updatedAt'] = now;
    payload['keys'] = keys;
    if (setActive) {
      payload['activeFingerprint'] = fingerprint;
    }

    await _writeManagedKeyring(
      token: token,
      payload: payload,
      ownerTag: ownerTag,
      gistId: gistId,
    );
    final preview = fingerprint.isEmpty
        ? 'unknown'
        : (fingerprint.length > 12
            ? '${fingerprint.substring(0, 12)}...'
            : fingerprint);
    _diag.info(
      'github',
      'Managed gist key synced fp=$preview',
    );
  }

  Future<void> removeManagedKeyringKeyByGitHubId(int githubKeyId) async {
    final token = await getToken();
    if (token == null) throw Exception('Not logged in');

    final existing = await loadManagedKeyring();
    if (existing == null) {
      return;
    }
    final gistId = existing['__gistId']?.toString();
    if (gistId == null || gistId.isEmpty) {
      return;
    }
    final ownerTag =
        existing['__ownerTag']?.toString() ?? await _resolveOwnerTag();

    final payload = Map<String, dynamic>.from(existing)
      ..remove('__gistId')
      ..remove('__ownerTag');
    final activeFingerprint = payload['activeFingerprint']?.toString();

    final rawKeys = payload['keys'];
    final keys = <Map<String, dynamic>>[];
    if (rawKeys is List) {
      for (final item in rawKeys) {
        if (item is Map<String, dynamic>) {
          keys.add(Map<String, dynamic>.from(item));
        } else if (item is Map) {
          keys.add(Map<String, dynamic>.from(item.cast<String, dynamic>()));
        }
      }
    }
    final removed = keys.where(
      (k) => k['githubKeyId']?.toString() == githubKeyId.toString(),
    );
    final removedFingerprints = removed
        .map((k) => k['fingerprint']?.toString() ?? '')
        .where((fp) => fp.isNotEmpty)
        .toSet();

    keys.removeWhere(
      (k) => k['githubKeyId']?.toString() == githubKeyId.toString(),
    );
    payload['keys'] = keys;
    payload['updatedAt'] = DateTime.now().toUtc().toIso8601String();

    if (activeFingerprint != null &&
        activeFingerprint.isNotEmpty &&
        removedFingerprints.contains(activeFingerprint)) {
      payload['activeFingerprint'] =
          keys.isNotEmpty ? keys.first['fingerprint']?.toString() : null;
    }

    await _writeManagedKeyring(
      token: token,
      payload: payload,
      ownerTag: ownerTag,
      gistId: gistId,
    );
  }

  Future<String?> getPublicKeyFromPrivateKey(String privateKeyPem) async {
    try {
      return await compute(_getPublicKeyFromPrivateKeyIsolate, privateKeyPem);
    } catch (e) {
      return null;
    }
  }

  static String _getPublicKeyFromPrivateKeyIsolate(String privateKeyPem) {
    try {
      final keys = SSHKeyPair.fromPem(privateKeyPem);
      if (keys.isEmpty) return '';

      // Use dynamic to access properties of RsaPrivateKey from dartssh2
      // dartssh2 RsaPrivateKey usually has n and e (BigInt)
      final dynamic key = keys.first;

      // Check if it has n and e
      try {
        final n = key.n as BigInt;
        final e = key.e as BigInt;
        final public = RSAPublicKey(n, e); // pointycastle RSAPublicKey
        return _encodePublicKeyToSsh(public);
      } catch (e) {
        // Not RSA or properties not found
        return '';
      }
    } catch (e) {
      debugPrint("Error parsing key: $e");
      return '';
    }
  }

  static String _encodePublicKeyToSsh(RSAPublicKey publicKey) {
    const keyType = 'ssh-rsa';
    final e = publicKey.publicExponent!;
    final n = publicKey.modulus!;

    final bytes = <int>[];
    _writeString(bytes, keyType);
    _writeBigInt(bytes, e);
    _writeBigInt(bytes, n);

    return '$keyType ${base64.encode(bytes)} CarrotLink';
  }

  static void _writeString(List<int> buffer, String s) {
    final bytes = utf8.encode(s);
    _writeInt(buffer, bytes.length);
    buffer.addAll(bytes);
  }

  static void _writeInt(List<int> buffer, int v) {
    buffer.add((v >> 24) & 0xFF);
    buffer.add((v >> 16) & 0xFF);
    buffer.add((v >> 8) & 0xFF);
    buffer.add(v & 0xFF);
  }

  static void _writeBigInt(List<int> buffer, BigInt v) {
    var bytes = _encodeBigInt(v);
    _writeInt(buffer, bytes.length);
    buffer.addAll(bytes);
  }

  static List<int> _encodeBigInt(BigInt number) {
    if (number == BigInt.zero) return [0];

    var hex = number.toRadixString(16);
    if (hex.length % 2 != 0) hex = '0$hex';

    var bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }

    // If MSB is set, prepend 0x00 to indicate positive number in 2's complement
    if ((bytes[0] & 0x80) != 0) {
      bytes.insert(0, 0x00);
    }
    return bytes;
  }

  Future<File?> _tokenMirrorFile() async {
    if (!Platform.isAndroid) return null;
    final ready = await StorageLayoutService.instance.ensureBaseFolders();
    if (!ready) return null;
    return File('${StorageLayoutService.authPath}/$_tokenMirrorFileName');
  }

  Future<void> _saveTokenMirror(String token) async {
    try {
      final file = await _tokenMirrorFile();
      if (file == null) return;

      final payload = <String, dynamic>{
        'token': token,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      };
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (_) {}
  }

  Future<String?> _readTokenMirror() async {
    try {
      final file = await _tokenMirrorFile();
      if (file == null || !await file.exists()) return null;

      final text = await file.readAsString();
      final trimmed = text.trim();
      if (trimmed.isEmpty) return null;

      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          final token = decoded['token']?.toString();
          if (token != null && token.isNotEmpty) return token;
        }
      } catch (_) {
        return trimmed;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _deleteTokenMirror() async {
    try {
      final file = await _tokenMirrorFile();
      if (file != null && await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  bool _hasRequiredScope(Map<String, String> headers) {
    final scopesRaw = headers['x-oauth-scopes'] ?? '';
    if (scopesRaw.isEmpty) return true;
    final scopes = scopesRaw
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty);
    return scopes.contains('admin:public_key') &&
        scopes.contains('gist') &&
        scopes.contains('repo');
  }

  String _normalizePublicKeyForCompare(String key) {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0]} ${parts[1]}';
    }
    return trimmed;
  }

  String _fingerprintFromPublicKey(String publicKey) {
    final normalized = _normalizePublicKeyForCompare(publicKey);
    if (normalized.isEmpty) return '';
    return 'sha256:${_sha256Hex(normalized)}';
  }

  String _sha256Hex(String input) {
    final digest =
        SHA256Digest().process(Uint8List.fromList(utf8.encode(input)));
    final buffer = StringBuffer();
    for (final b in digest) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  Map<String, dynamic> _newManagedKeyringPayload({required String ownerTag}) {
    final now = DateTime.now().toUtc().toIso8601String();
    return <String, dynamic>{
      'schema': _keyringSchema,
      'owner': ownerTag,
      'env': _keyringEnv,
      'activeFingerprint': null,
      'updatedAt': now,
      'keys': <Map<String, dynamic>>[],
    };
  }

  Future<String> _resolveOwnerTag() async {
    final user = await getUserInfo();
    final id = user?['id']?.toString();
    if (id != null && id.isNotEmpty) return id;
    final login = user?['login']?.toString();
    if (login != null && login.isNotEmpty) return login;
    return 'unknown';
  }

  Future<String?> _findManagedKeyringGistId(String token) async {
    var page = 1;
    while (true) {
      final response = await http.get(
        Uri.parse('$_baseUrl/gists?per_page=100&page=$page'),
        headers: {
          'Authorization': 'token $token',
          'Accept': 'application/vnd.github.v3+json',
        },
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw _buildGitHubApiException('Gist 목록 조회', response);
      }

      final data = jsonDecode(response.body);
      if (data is! List) return null;

      for (final raw in data) {
        if (raw is! Map) continue;
        final gist = raw.cast<String, dynamic>();
        final description = gist['description']?.toString() ?? '';
        if (!description.startsWith(_keyringDescriptionPrefix)) continue;
        final files = gist['files'];
        if (files is! Map) continue;
        if (!files.containsKey(_keyringFileName)) continue;
        final gistId = gist['id']?.toString();
        if (gistId != null && gistId.isNotEmpty) return gistId;
      }

      if (data.length < 100) break;
      page += 1;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getGistDetail(
      String token, String gistId) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/gists/$gistId'),
      headers: {
        'Authorization': 'token $token',
        'Accept': 'application/vnd.github.v3+json',
      },
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw _buildGitHubApiException('Gist 조회', response);
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) return null;
    return data;
  }

  Future<void> _writeManagedKeyring({
    required String token,
    required Map<String, dynamic> payload,
    required String ownerTag,
    String? gistId,
  }) async {
    final description = '$_keyringDescriptionPrefix|$ownerTag|$_keyringEnv';
    final body = jsonEncode({
      'description': description,
      'public': false,
      'files': {
        _keyringFileName: {
          'content': const JsonEncoder.withIndent('  ').convert(payload),
        },
      },
    });

    final isCreate = gistId == null || gistId.isEmpty;
    final uri = isCreate
        ? Uri.parse('$_baseUrl/gists')
        : Uri.parse('$_baseUrl/gists/$gistId');
    final response = isCreate
        ? await http
            .post(
              uri,
              headers: {
                'Authorization': 'token $token',
                'Accept': 'application/vnd.github.v3+json',
                'Content-Type': 'application/json',
              },
              body: body,
            )
            .timeout(const Duration(seconds: 15))
        : await http
            .patch(
              uri,
              headers: {
                'Authorization': 'token $token',
                'Accept': 'application/vnd.github.v3+json',
                'Content-Type': 'application/json',
              },
              body: body,
            )
            .timeout(const Duration(seconds: 15));

    final expectedStatus = isCreate ? 201 : 200;
    if (response.statusCode != expectedStatus) {
      throw _buildGitHubApiException('Gist 저장', response);
    }
  }

  Exception _buildGitHubApiException(String action, http.Response response) {
    final status = response.statusCode;
    var bodyMessage = response.body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final msg = decoded['message']?.toString();
        final errors = decoded['errors'];
        final detail = errors == null ? '' : ' errors=$errors';
        if (msg != null && msg.isNotEmpty) {
          bodyMessage = '$msg$detail';
        }
      }
    } catch (_) {}

    String friendly;
    if (status == 401) {
      friendly = 'GitHub 인증이 만료되었습니다. 다시 로그인하세요.';
    } else if (status == 403) {
      final lower = bodyMessage.toLowerCase();
      if (lower.contains('admin:public_key') ||
          lower.contains('gist') ||
          lower.contains('repo') ||
          lower.contains('resource not accessible')) {
        friendly =
            '토큰 권한이 부족합니다. admin:public_key, gist, repo 권한이 필요합니다.';
      } else {
        friendly = '$action 권한이 거부되었습니다.';
      }
    } else if (status == 422) {
      friendly = '요청이 거부되었습니다. 이미 등록된 키이거나 입력값을 확인하세요.';
    } else {
      friendly = '$action 실패 (HTTP $status)';
    }

    return Exception('$friendly\n$bodyMessage');
  }
}
