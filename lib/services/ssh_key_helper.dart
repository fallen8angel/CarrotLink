import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

class SSHKeyHelper {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// Generates a new RSA key pair, saves it securely, and returns the public key.
  Future<Map<String, String>> generateAndSaveKey() async {
    final keyPair = await compute(_generateRSAKeyPairIsolate, null);

    // 개인키와 공개키 모두 저장
    await _storage.write(key: 'user_private_key', value: keyPair['private']);
    await _storage.write(key: 'user_public_key', value: keyPair['public']);

    // 저장 확인 로그
    final savedPrivate = await _storage.read(key: 'user_private_key');
    final savedPublic = await _storage.read(key: 'user_public_key');
    debugPrint("=== KEY SAVE CHECK ===");
    debugPrint(
        "Private key saved: ${savedPrivate != null ? 'YES (${savedPrivate.length} chars)' : 'NO'}");
    debugPrint(
        "Private key starts with: ${savedPrivate?.substring(0, 50) ?? 'null'}");
    debugPrint(
        "Public key saved: ${savedPublic != null ? 'YES (${savedPublic.length} chars)' : 'NO'}");
    debugPrint("Public key: ${savedPublic ?? 'null'}");
    debugPrint("======================");

    return keyPair;
  }

  Future<String?> getStoredPublicKey() async {
    return await _storage.read(key: 'user_public_key');
  }

  static Map<String, String> _generateRSAKeyPairIsolate(_) {
    final secureRandom = SecureRandom('Fortuna')
      ..seed(KeyParameter(Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(255)))));

    final keyGen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
        secureRandom,
      ));

    final pair = keyGen.generateKeyPair();
    final public = pair.publicKey as RSAPublicKey;
    final private = pair.privateKey as RSAPrivateKey;

    return {
      'private': _encodePrivateKeyToPem(private),
      'public': _encodePublicKeyToSsh(public),
    };
  }

  static String _encodePrivateKeyToPem(RSAPrivateKey privateKey) {
    var version = BigInt.zero;
    var n = privateKey.modulus!;
    var e = privateKey.publicExponent!;
    var d = privateKey.privateExponent!;
    var p = privateKey.p!;
    var q = privateKey.q!;
    var dP = d % (p - BigInt.one);
    var dQ = d % (q - BigInt.one);
    var qInv = q.modInverse(p);

    var bytes = <int>[];

    // Sequence content
    var content = <int>[];
    content.addAll(_encodeASN1Integer(version));
    content.addAll(_encodeASN1Integer(n));
    content.addAll(_encodeASN1Integer(e));
    content.addAll(_encodeASN1Integer(d));
    content.addAll(_encodeASN1Integer(p));
    content.addAll(_encodeASN1Integer(q));
    content.addAll(_encodeASN1Integer(dP));
    content.addAll(_encodeASN1Integer(dQ));
    content.addAll(_encodeASN1Integer(qInv));

    // Sequence header
    bytes.add(0x30);
    _writeASN1Length(bytes, content.length);
    bytes.addAll(content);

    var base64Data = base64.encode(bytes);
    var pem = "-----BEGIN RSA PRIVATE KEY-----\n";
    for (var i = 0; i < base64Data.length; i += 64) {
      pem += "${base64Data.substring(i, min(i + 64, base64Data.length))}\n";
    }
    pem += "-----END RSA PRIVATE KEY-----";
    return pem;
  }

  static List<int> _encodeASN1Integer(BigInt v) {
    var bytes = <int>[];
    bytes.add(0x02); // Integer tag
    var content = _encodeBigInt(v);
    _writeASN1Length(bytes, content.length);
    bytes.addAll(content);
    return bytes;
  }

  static void _writeASN1Length(List<int> bytes, int length) {
    if (length < 128) {
      bytes.add(length);
    } else {
      var lenBytes = <int>[];
      while (length > 0) {
        lenBytes.insert(0, length & 0xFF);
        length >>= 8;
      }
      bytes.add(0x80 | lenBytes.length);
      bytes.addAll(lenBytes);
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

  /// Connects using password, appends the public key to authorized_keys, and verifies connection.
  Future<Map<String, dynamic>> installKey(String ip, int port, String username,
      String password, String publicKey) async {
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(ip, port,
          timeout: const Duration(seconds: 10));

      client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => password,
      );

      // 인증 대기
      await client.authenticated.timeout(const Duration(seconds: 15));

      // Script to install key in multiple locations for compatibility
      // openpilot uses /data/params/d/GithubSshKeys (read by sshd via AuthorizedKeysCommand)
      // Also install to ~/.ssh/authorized_keys as fallback
      final escapedKey =
          publicKey.replaceAll('"', '\\"').replaceAll("'", "'\\''");
      final cmd = '''
# Ensure directories exist
mkdir -p /data/params/d 2>/dev/null || true
mkdir -p ~/.ssh 2>/dev/null || true
mkdir -p /home/comma/.ssh 2>/dev/null || true

# 1. Install to Openpilot GithubSshKeys param (primary method for openpilot)
touch /data/params/d/GithubSshKeys 2>/dev/null || true
if ! grep -qF "$escapedKey" /data/params/d/GithubSshKeys 2>/dev/null; then
  echo '$publicKey' >> /data/params/d/GithubSshKeys
fi
chmod 644 /data/params/d/GithubSshKeys 2>/dev/null || true

# 2. Install to comma user authorized_keys
touch /home/comma/.ssh/authorized_keys 2>/dev/null || true
if ! grep -qF "$escapedKey" /home/comma/.ssh/authorized_keys 2>/dev/null; then
  echo '$publicKey' >> /home/comma/.ssh/authorized_keys
fi
chmod 600 /home/comma/.ssh/authorized_keys 2>/dev/null || true
chmod 700 /home/comma/.ssh 2>/dev/null || true
chown -R comma:comma /home/comma/.ssh 2>/dev/null || true

# 3. Also try root's authorized_keys (some forks use this)
touch ~/.ssh/authorized_keys 2>/dev/null || true
if ! grep -qF "$escapedKey" ~/.ssh/authorized_keys 2>/dev/null; then
  echo '$publicKey' >> ~/.ssh/authorized_keys
fi
chmod 600 ~/.ssh/authorized_keys 2>/dev/null || true
chmod 700 ~/.ssh 2>/dev/null || true

echo "INSTALL_OK"
''';

      final result = await client.run(cmd);
      final output = utf8.decode(result);

      if (output.contains('INSTALL_OK')) {
        return {'success': true, 'message': 'Key installed successfully'};
      } else {
        return {
          'success': false,
          'message': 'Installation may have issues: $output'
        };
      }
    } on SSHAuthFailError catch (e) {
      print("SSH Auth Error: $e");
      return {
        'success': false,
        'message': '인증 실패 - 비밀번호 "comma"가 맞는지 확인하세요',
        'error': e.toString()
      };
    } on SSHAuthAbortError catch (e) {
      print("SSH Auth Abort: $e");
      return {'success': false, 'message': '인증 중단됨', 'error': e.toString()};
    } on SocketException catch (e) {
      print("Socket Error: $e");
      return {
        'success': false,
        'message': '연결 실패 - IP/네트워크 확인',
        'error': e.toString()
      };
    } on TimeoutException catch (e) {
      print("Timeout: $e");
      return {'success': false, 'message': '연결 시간 초과', 'error': e.toString()};
    } catch (e) {
      print("Error installing key: $e");
      return {'success': false, 'message': e.toString(), 'error': e.toString()};
    } finally {
      client?.close();
    }
  }

  /// Test SSH key authentication
  Future<Map<String, dynamic>> testKeyAuth(
      String ip, int port, String username, String privateKey) async {
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(ip, port,
          timeout: const Duration(seconds: 10));

      final keys = SSHKeyPair.fromPem(privateKey);
      if (keys.isEmpty) {
        return {'success': false, 'message': '유효하지 않은 개인키'};
      }

      client = SSHClient(
        socket,
        username: username,
        identities: keys,
      );

      await client.authenticated.timeout(const Duration(seconds: 15));

      // Try a simple command
      final result = await client.run('echo OK');
      final output = utf8.decode(result);

      if (output.contains('OK')) {
        return {'success': true, 'message': 'SSH 키 인증 성공'};
      } else {
        return {'success': false, 'message': '연결됐지만 명령 실행 실패'};
      }
    } on SSHAuthFailError catch (e) {
      print("SSH Key Auth Error: $e");
      return {
        'success': false,
        'message': 'SSH 키 인증 실패 - 키가 기기에 등록되지 않았을 수 있습니다',
        'error': e.toString()
      };
    } catch (e) {
      print("Error testing key: $e");
      return {'success': false, 'message': e.toString(), 'error': e.toString()};
    } finally {
      client?.close();
    }
  }

  Future<String?> getStoredPrivateKey() async {
    return await _storage.read(key: 'user_private_key');
  }
}
