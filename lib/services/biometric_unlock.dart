import 'package:local_auth/local_auth.dart';

/// Owns the system biometric prompt; it never receives vault data itself.
class BiometricUnlock {
  BiometricUnlock({LocalAuthentication? authentication})
    : _authentication = authentication ?? LocalAuthentication();

  final LocalAuthentication _authentication;

  Future<bool> isAvailable() async =>
      await _authentication.canCheckBiometrics &&
      (await _authentication.getAvailableBiometrics()).isNotEmpty;

  Future<bool> verify() => _authentication.authenticate(
    localizedReason: 'Подтвердите личность, чтобы открыть KeyKeep',
    biometricOnly: true,
    persistAcrossBackgrounding: true,
  );
}
