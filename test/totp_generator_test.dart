import 'package:flutter_test/flutter_test.dart';
import 'package:keykeep_passwords/services/totp_generator.dart';

void main() {
  test('generates the RFC 6238 SHA-1 reference code', () {
    final code = const TotpGenerator().code(
      'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
      time: DateTime.utc(1970, 1, 1, 0, 0, 59),
    );

    expect(code, '287082');
  });
}
