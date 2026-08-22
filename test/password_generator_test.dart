import 'package:flutter_test/flutter_test.dart';
import 'package:keykeep_passwords/services/password_generator.dart';

void main() {
  test(
    'creates a password of requested length with several character groups',
    () {
      final password = const PasswordGenerator().generate(length: 20);
      expect(password.length, 20);
      expect(RegExp(r'[A-Za-z]').hasMatch(password), isTrue);
      expect(RegExp(r'[0-9]').hasMatch(password), isTrue);
      expect(RegExp(r'[!@#%&*+\-_=]').hasMatch(password), isTrue);
    },
  );

  test('rejects passwords shorter than eight characters', () {
    expect(
      () => const PasswordGenerator().generate(length: 7),
      throwsArgumentError,
    );
  });
}
