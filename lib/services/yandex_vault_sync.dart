// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:keykeep_passwords/domain/password_entry.dart';
import 'package:keykeep_passwords/domain/vault_folder.dart';
import 'package:keykeep_passwords/services/kdbx_vault_codec.dart';
import 'package:keykeep_passwords/services/yandex_disk_oauth.dart';

class YandexVaultSync {
  YandexVaultSync({
    YandexDiskOAuthService? oauth,
    http.Client? client,
    KdbxVaultCodec? codec,
  }) : _oauth = oauth ?? YandexDiskOAuthService(),
       _client = client ?? http.Client(),
       _codec = codec ?? KdbxVaultCodec();
  static const _currentPath = 'app:/keykeep-vault.kdbx';
  static const _historyFolder = 'keykeep-history';
  final YandexDiskOAuthService _oauth;
  final http.Client _client;
  final KdbxVaultCodec _codec;

  /// Publishes the current vault and an immutable, content-addressed snapshot.
  /// The snapshot id behaves like a Git commit id: identical vaults have the
  /// same id and earlier versions are never overwritten.
  Future<SyncVersion> upload({
    required List<VaultFolder> folders,
    required List<PasswordEntry> entries,
    required String password,
  }) async {
    final bytes = await _codec.export(
      folders: folders,
      entries: entries,
      password: password,
    );
    await _ensureFolder(_historyFolder);
    await _upload(_currentPath, bytes);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final id = sha256.convert(bytes).toString().substring(0, 12);
    final snapshotPath = 'app:/$_historyFolder/$stamp-$id.kdbx';
    await _upload(snapshotPath, bytes);
    return SyncVersion(
      id: id,
      createdAt: DateTime.now().toUtc(),
      path: snapshotPath,
    );
  }

  Future<VaultSnapshot> download({required String password}) async {
    final token = await _oauth.token();
    final response = await _client.get(
      Uri.https('cloud-api.yandex.net', '/v1/disk/resources/download', {
        'path': _currentPath,
      }),
      headers: {'Authorization': 'OAuth $token'},
    );
    if (response.statusCode == 404)
      throw StateError('На Яндекс Диске пока нет синхронизированной базы.');
    final href =
        (jsonDecode(response.body) as Map<String, dynamic>)['href'] as String?;
    if (response.statusCode != 200 || href == null)
      throw StateError('Не удалось скачать базу с Диска.');
    final file = await _client.get(Uri.parse(href));
    if (file.statusCode != 200)
      throw StateError('Не удалось скачать содержимое базы.');
    return _codec.import(Uint8List.fromList(file.bodyBytes), password);
  }

  Future<void> _ensureFolder(String name) async {
    final token = await _oauth.token();
    final response = await _client.put(
      Uri.https('cloud-api.yandex.net', '/v1/disk/resources', {
        'path': 'app:/$name',
      }),
      headers: {'Authorization': 'OAuth $token'},
    );
    if (response.statusCode != 201 && response.statusCode != 409)
      throw StateError('Не удалось подготовить папку синхронизации.');
  }

  Future<void> _upload(String path, Uint8List bytes) async {
    final token = await _oauth.token();
    final response = await _client.get(
      Uri.https('cloud-api.yandex.net', '/v1/disk/resources/upload', {
        'path': path,
        'overwrite': 'true',
      }),
      headers: {'Authorization': 'OAuth $token'},
    );
    final href =
        (jsonDecode(response.body) as Map<String, dynamic>)['href'] as String?;
    if (response.statusCode != 200 || href == null)
      throw StateError('Не удалось начать загрузку на Диск.');
    final upload = await _client.put(Uri.parse(href), body: bytes);
    if (upload.statusCode < 200 || upload.statusCode >= 300)
      throw StateError('Не удалось загрузить зашифрованную базу.');
  }
}

class SyncVersion {
  const SyncVersion({
    required this.id,
    required this.createdAt,
    required this.path,
  });

  final String id;
  final DateTime createdAt;
  final String path;
}
