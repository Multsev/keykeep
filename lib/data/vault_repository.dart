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

  Future<bool> unlock(String pin) async {
    final salt = await _storage.read(key: _saltKey);
    final verifier = await _storage.read(key: _verifierKey);
    return salt != null &&
        verifier != null &&
        _masterPin.matches(pin, salt, verifier);
  }

  Future<bool> biometricUnlock() async {
    final pin = await _storage.read(key: _biometricPinKey);
    return pin != null && await unlock(pin);
  }

  Future<bool> hasBiometricUnlock() async =>
      (await _storage.read(key: _biometricPinKey)) != null;

  /// Stores the PIN only in Android's keystore-backed secure storage after
  /// the user explicitly enables biometric unlocking.
  Future<void> enableBiometricUnlock(String pin) =>
      _storage.write(key: _biometricPinKey, value: pin);

  Future<void> disableBiometricUnlock() =>
      _storage.delete(key: _biometricPinKey);

  Future<List<PasswordEntry>> loadEntries() async {
    final source = await _storage.read(key: _vaultKey);
    if (source == null) return [];
    final decoded = jsonDecode(source) as List<dynamic>;
    return decoded
        .map((item) => PasswordEntry.fromJson(item as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  Future<void> saveEntries(List<PasswordEntry> entries) => _storage.write(
    key: _vaultKey,
    value: jsonEncode(entries.map((entry) => entry.toJson()).toList()),
  );

  Future<List<VaultFolder>> loadFolders() async {
    final source = await _storage.read(key: _foldersKey);
    if (source == null) {
      return const [VaultFolder(id: 'root', name: 'Все записи')];
    }
    return (jsonDecode(source) as List<dynamic>)
        .map((item) => VaultFolder.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveFolders(List<VaultFolder> folders) => _storage.write(
    key: _foldersKey,
    value: jsonEncode(folders.map((folder) => folder.toJson()).toList()),
  );
}
