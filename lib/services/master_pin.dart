import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Derives a verifier without retaining the master PIN itself.
class MasterPin {
  const MasterPin({this.random});

  final Random? random;
  static const iterations = 120000;

  String newSalt() {
    final source = random ?? Random.secure();
    return base64UrlEncode(List<int>.generate(16, (_) => source.nextInt(256)));
  }

  String derive(String pin, String salt) {
    List<int> value = utf8.encode('$salt:$pin');
    for (var round = 0; round < iterations; round++) {
      value = sha256.convert(value).bytes;
    }
    return base64UrlEncode(value);
  }

  bool matches(String pin, String salt, String verifier) =>
      derive(pin, salt) == verifier;
}
