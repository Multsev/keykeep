// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class YandexDiskOAuthService {
  YandexDiskOAuthService({FlutterSecureStorage? storage, http.Client? client})
    : _storage = storage ?? const FlutterSecureStorage(),
      _client = client ?? http.Client();

  static const _bundledClientId = String.fromEnvironment(
    'YANDEX_OAUTH_CLIENT_ID',
  );
  static const redirectUri = 'keykeep://oauth/callback';
  static const _tokenKey = 'yandex_disk_access_token';
  static const _stateKey = 'yandex_disk_state';
  static const _verifierKey = 'yandex_disk_verifier';
  static const _clientIdKey = 'yandex_disk_client_id';
  static const _syncFolderKey = 'yandex_disk_sync_folder';
  final FlutterSecureStorage _storage;
  final http.Client _client;

  Future<bool> get isConfigured async => (await clientId()).isNotEmpty;
  Future<bool> get isConnected async =>
      (await _storage.read(key: _tokenKey)) != null;

  Future<void> startAuthorization() async {
    final appClientId = await clientId();
    if (appClientId.isEmpty)
      throw StateError(
        'Укажите OAuth client ID Яндекса в настройках синхронизации.',
      );
    final state = _randomValue(32);
    final verifier = _randomValue(64);
    await _storage.write(key: _stateKey, value: state);
    await _storage.write(key: _verifierKey, value: verifier);
    final uri = Uri.https('oauth.yandex.ru', '/authorize', {
      'response_type': 'code',
      'client_id': appClientId,
      'redirect_uri': redirectUri,
      'scope': 'cloud_api:disk.app_folder',
      'state': state,
      'code_challenge': _challenge(verifier),
      'code_challenge_method': 'S256',
    });
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication))
      throw StateError('Не удалось открыть браузер.');
  }

  Future<void> completeAuthorization(Uri callback) async {
    final appClientId = await clientId();
    final state = await _storage.read(key: _stateKey);
    final verifier = await _storage.read(key: _verifierKey);
    final code = callback.queryParameters['code'];
    if (callback.scheme != 'keykeep' ||
        callback.host != 'oauth' ||
        callback.queryParameters['state'] != state ||
        verifier == null ||
        code == null)
      throw StateError('Не удалось подтвердить вход в Яндекс.');
    final response = await _client.post(
      Uri.https('oauth.yandex.ru', '/token'),
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': appClientId,
        'redirect_uri': redirectUri,
        'code_verifier': verifier,
      },
    );
    final token =
        (jsonDecode(response.body) as Map<String, dynamic>)['access_token']
            as String?;
    await _storage.delete(key: _stateKey);
    await _storage.delete(key: _verifierKey);
    if (response.statusCode != 200 || token == null)
      throw StateError('Яндекс не выдал токен доступа.');
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String> token() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) throw StateError('Сначала подключите Яндекс Диск.');
    return token;
  }

  Future<void> disconnect() => _storage.delete(key: _tokenKey);
  Future<String> clientId() async =>
      (await _storage.read(key: _clientIdKey)) ?? _bundledClientId;
  Future<void> saveClientId(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty)
      throw ArgumentError.value(value, 'value', 'Client ID is required.');
    await _storage.write(key: _clientIdKey, value: normalized);
  }

  /// Folder names are deliberately limited to one level inside app:/ so an
  /// OAuth token with app-folder scope can never address arbitrary Disk paths.
  Future<String> syncFolder() async =>
      (await _storage.read(key: _syncFolderKey)) ?? 'KeyKeep';

  Future<void> saveSyncFolder(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized == '.' ||
        normalized == '..' ||
        normalized.contains('/') ||
        normalized.contains('\\')) {
      throw ArgumentError.value(
        value,
        'value',
        'Имя папки не должно содержать путь.',
      );
    }
    await _storage.write(key: _syncFolderKey, value: normalized);
  }

  static String _challenge(String value) => base64Url
      .encode(sha256.convert(utf8.encode(value)).bytes)
      .replaceAll('=', '');
  static String _randomValue(int size) => base64Url
      .encode(List<int>.generate(size, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
}
