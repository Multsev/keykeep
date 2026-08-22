import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:keykeep_passwords/services/master_pin.dart';

void main() {
  test('verifies the correct PIN and rejects another PIN', () {
    final pin = MasterPin(random: Random(2));
    final salt = pin.newSalt();
    final verifier = pin.derive('safe-master-pin', salt);
    expect(pin.matches('safe-master-pin', salt, verifier), isTrue);
    expect(pin.matches('wrong-pin', salt, verifier), isFalse);
  });
}
