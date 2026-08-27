import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:keykeep_passwords/domain/password_entry.dart';
import 'package:keykeep_passwords/domain/vault_folder.dart';
import 'package:keykeep_passwords/services/master_pin.dart';

/// Persists the vault in Android's encrypted keystore-backed storage.
class VaultRepository {
  VaultRepository({FlutterSecureStorage? storage, MasterPin? masterPin})
    : _storage = storage ?? const FlutterSecureStorage(),
      _masterPin = masterPin ?? const MasterPin();

  static const _saltKey = 'master_pin_salt';
  static const _verifierKey = 'master_pin_verifier';
  static const _vaultKey = 'vault_entries';
  static const _foldersKey = 'vault_folders';
  static const _biometricPinKey = 'biometric_unlock_pin';
  static const _biometricAutoPromptKey = 'biometric_auto_prompt';
  static const _vaultModifiedAtKey = 'vault_modified_at';
  static const _failedUnlockCountKey = 'failed_unlock_count';
  static const _unlockBlockedUntilKey = 'unlock_blocked_until';
  static const _lastCloudSyncKey = 'last_cloud_sync_at';
  final FlutterSecureStorage _storage;
  final MasterPin _masterPin;

  Future<bool> hasMasterPin() async =>
      (await _storage.read(key: _verifierKey)) != null;

  Future<void> createMasterPin(String pin) async {
    final salt = _masterPin.newSalt();
    await _storage.write(key: _saltKey, value: salt);
    await _storage.write(
      key: _verifierKey,
      value: _masterPin.derive(pin, salt),
    );
  }

  /// The delay grows after repeated failures, without risking vault deletion.
  Future<Duration> unlockDelay() async {
    final source = await _storage.read(key: _unlockBlockedUntilKey);
    if (source == null) return Duration.zero;
    final blockedUntil = DateTime.tryParse(source);
    if (blockedUntil == null || !blockedUntil.isAfter(DateTime.now())) {
      await _storage.delete(key: _unlockBlockedUntilKey);
      return Duration.zero;
    }
    return blockedUntil.difference(DateTime.now());
  }

  Future<bool> unlock(String pin) async {
    final salt = await _storage.read(key: _saltKey);
    final verifier = await _storage.read(key: _verifierKey);
    final matched =
        salt != null &&
        verifier != null &&
        _masterPin.matches(pin, salt, verifier);
    if (matched) {
      await _storage.delete(key: _failedUnlockCountKey);
      await _storage.delete(key: _unlockBlockedUntilKey);
      return true;
    }
    final attempts =
        (int.tryParse(await _storage.read(key: _failedUnlockCountKey) ?? '0') ??
            0) +
        1;
    await _storage.write(key: _failedUnlockCountKey, value: '$attempts');
    // 0, 0, 0, 5, 10, 20 … seconds, capped at five minutes.
    if (attempts >= 4) {
      final seconds = (5 * (1 << (attempts - 4))).clamp(5, 300);
      await _storage.write(
        key: _unlockBlockedUntilKey,
        value: DateTime.now().add(Duration(seconds: seconds)).toIso8601String(),
      );
    }
    return false;
  }

  Future<bool> changeMasterPin({
    required String currentPin,
    required String newPin,
  }) async {
    if (!await unlock(currentPin)) return false;
    final salt = _masterPin.newSalt();
    await _storage.write(key: _saltKey, value: salt);
    await _storage.write(
      key: _verifierKey,
      value: _masterPin.derive(newPin, salt),
    );
    return true;
  }

  Future<bool> biometricUnlock() async {
    final pin = await _storage.read(key: _biometricPinKey);
    return pin != null && await unlock(pin);
  }

  Future<bool> hasBiometricUnlock() async =>
      (await _storage.read(key: _biometricPinKey)) != null;

  /// Stores the PIN only in Android's keystore-backed secure storage after
  /// the user explicitly enables biometric unlocking.
  Future<void> enableBiometricUnlock(String pin) async {
    await _storage.write(key: _biometricPinKey, value: pin);
    await setBiometricAutoPrompt(true);
  }

  Future<void> disableBiometricUnlock() async {
    await _storage.delete(key: _biometricPinKey);
    await _storage.delete(key: _biometricAutoPromptKey);
  }

  Future<bool> biometricAutoPrompt() async =>
      await _storage.read(key: _biometricAutoPromptKey) != 'false';

  Future<void> setBiometricAutoPrompt(bool enabled) =>
      _storage.write(key: _biometricAutoPromptKey, value: enabled.toString());

  /// Removes local vault data and access credentials, but retains app-level
  /// integrations such as a Yandex Disk OAuth connection.
  Future<void> deleteVault() async {
    for (final key in [
      _saltKey,
      _verifierKey,
      _vaultKey,
      _foldersKey,
      _biometricPinKey,
      _biometricAutoPromptKey,
      _vaultModifiedAtKey,
      _failedUnlockCountKey,
      _unlockBlockedUntilKey,
      _lastCloudSyncKey,
    ]) {
      await _storage.delete(key: key);
    }
  }

  Future<List<PasswordEntry>> loadEntries() async {
    final source = await _storage.read(key: _vaultKey);
    if (source == null) return [];
    final decoded = jsonDecode(source) as List<dynamic>;
    return decoded
        .map((item) => PasswordEntry.fromJson(item as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  Future<void> saveEntries(List<PasswordEntry> entries) async {
    await _storage.write(
      key: _vaultKey,
      value: jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
    await _touchVault();
  }

  Future<List<VaultFolder>> loadFolders() async {
    final source = await _storage.read(key: _foldersKey);
    if (source == null) {
      return const [VaultFolder(id: 'root', name: 'Все записи')];
    }
    return (jsonDecode(source) as List<dynamic>)
        .map((item) => VaultFolder.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveFolders(List<VaultFolder> folders) async {
    await _storage.write(
      key: _foldersKey,
      value: jsonEncode(folders.map((folder) => folder.toJson()).toList()),
    );
    await _touchVault();
  }

  Future<DateTime> vaultModifiedAt() async {
    final stored = await _storage.read(key: _vaultModifiedAtKey);
    if (stored != null) return DateTime.parse(stored).toLocal();
    final entries = await loadEntries();
    if (entries.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    return entries
        .map((entry) => entry.updatedAt)
        .reduce((latest, value) => value.isAfter(latest) ? value : latest);
  }

  Future<DateTime?> lastCloudSyncAt() async {
    final source = await _storage.read(key: _lastCloudSyncKey);
    return source == null ? null : DateTime.tryParse(source)?.toLocal();
  }

  Future<void> markCloudSynced() => _storage.write(
    key: _lastCloudSyncKey,
    value: DateTime.now().toUtc().toIso8601String(),
  );

  Future<void> _touchVault() => _storage.write(
    key: _vaultModifiedAtKey,
    value: DateTime.now().toUtc().toIso8601String(),
  );
}
