import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

const _sampleEd25519PrivateKeyPem = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBZnnnYZjFQ7Zt0gMyJ2YYmDINTucLFWY81/Wuv2aOIpAAAAKBQ6gOSUOoD
kgAAAAtzc2gtZWQyNTUxOQAAACBZnnnYZjFQ7Zt0gMyJ2YYmDINTucLFWY81/Wuv2aOIpA
AAAEAP8fq0hjlR3jhL7pg+26PSaMiC1V/RrinVbo/4eBMRNFmeedhmMVDtm3SAzInZhiYM
g1O5wsVZjzX9a6/Zo4ikAAAAGWpmb3V0dHNAVVNBSkZPVVRUU00ubG9jYWwBAgME
-----END OPENSSH PRIVATE KEY-----''';

void main() {
  test('Check SSHPublicKey API (dartssh2 current API)', () {
    final keyPairs = SSHKeyPair.fromPem(_sampleEd25519PrivateKeyPem);

    expect(keyPairs, isNotEmpty);

    final keyPair = keyPairs.single;
    final encodedPublicKey = keyPair.toPublicKey().encode();

    expect(keyPair.type, isNotEmpty);
    expect(encodedPublicKey, isNotEmpty);

    // OpenSSH public-key line format example
    final publicKeyLine = '${keyPair.type} ${base64.encode(encodedPublicKey)}';
    expect(publicKeyLine, startsWith('${keyPair.type} '));
  });
}
