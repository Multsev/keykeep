import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Generates RFC 6238-compatible six digit TOTP codes from a Base32 secret.
class TotpGenerator {
  const TotpGenerator();

  String code(String base32Secret, {DateTime? time}) {
    final secret = _decodeBase32(base32Secret);
    final counter =
        ((time ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000 ~/ 30);
    final data = ByteData(8)..setUint64(0, counter);
    final digest = Hmac(sha1, secret).convert(data.buffer.asUint8List()).bytes;
    final offset = digest.last & 0x0f;
    final binary =
        ((digest[offset] & 0x7f) << 24) |
        (digest[offset + 1] << 16) |
        (digest[offset + 2] << 8) |
        digest[offset + 3];
    return (binary % 1000000).toString().padLeft(6, '0');
  }

  Uint8List _decodeBase32(String source) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    var buffer = 0;
    var bits = 0;
    final result = <int>[];
    for (final character
        in source.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '').codeUnits) {
      final value = alphabet.indexOf(String.fromCharCode(character));
      if (value < 0) throw FormatException('Некорректный Base32-секрет TOTP.');
      buffer = (buffer << 5) | value;
      bits += 5;
      while (bits >= 8) {
        bits -= 8;
        result.add((buffer >> bits) & 0xff);
      }
    }
    if (result.isEmpty) throw FormatException('Укажите TOTP-секрет.');
    return Uint8List.fromList(result);
  }
}
