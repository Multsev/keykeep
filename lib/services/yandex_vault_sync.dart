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
  static const _vaultFileName = 'keykeep-vault.kdbx';
  static const _historyFolderName = 'keykeep-history';
  final YandexDiskOAuthService _oauth;
  final http.Client _client;
  final KdbxVaultCodec _codec;

  Future<List<String>> listFolders() async {
    final token = await _oauth.token();
    final response = await _client.get(
      Uri.https('cloud-api.yandex.net', '/v1/disk/resources', {
        'path': 'disk:/',
        'limit': '1000',
      }),
      headers: {'Authorization': 'OAuth $token'},
    );
    if (response.statusCode != 200) {
      throw StateError('Не удалось получить список папок на Яндекс Диске.');
    }
    final items =
        (jsonDecode(response.body)
                as Map<String, dynamic>)['_embedded']?['items']
            as List<dynamic>? ??
        const [];
    return items
        .whereType<Map<String, dynamic>>()
        .where((item) => item['type'] == 'dir')
        .map((item) => item['name'] as String)
        .toList()
      ..sort();
  }

  Future<void> prepareFolder(String folder) async {
    await _ensureFolder(folder);
    await _ensureFolder('$folder/$_historyFolderName');
  }

  Future<List<CloudVaultVersion>> listVersions() async {
    final token = await _oauth.token();
    final folder = await _oauth.syncFolder();
    final response = await _client.get(
      Uri.https('cloud-api.yandex.net', '/v1/disk/resources', {
        'path': 'disk:/$folder/$_historyFolderName',
        'limit': '1000',
      }),
      headers: {'Authorization': 'OAuth $token'},
    );
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) {
      throw StateError('Не удалось получить историю облачных версий.');
    }
    final items =
        (jsonDecode(response.body)
                as Map<String, dynamic>)['_embedded']?['items']
            as List<dynamic>? ??
        const [];
    return items
        .whereType<Map<String, dynamic>>()
        .where((item) => item['type'] == 'file')
        .where((item) => (item['name'] as String).endsWith('.kdbx'))
        .map(
          (item) => CloudVaultVersion(
            name: item['name'] as String,
            modifiedAt: DateTime.parse(item['modified'] as String).toLocal(),
            size: item['size'] as int? ?? 0,
          ),
        )
        .toList()
      ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
  }

  Future<RemoteVaultInfo?> remoteInfo() async {
    final token = await _oauth.token();
    final folder = await _oauth.syncFolder();
    final response = await _client.get(
      Uri.https('cloud-api.yandex.net', '/v1/disk/resources', {
        'path': _currentPath(folder),
      }),
      headers: {'Authorization': 'OAuth $token'},
    );
    if (response.statusCode == 404) return null;
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final modified = payload['modified'] as String?;
    if (response.statusCode != 200 || modified == null) {
      throw StateError('Не удалось получить сведения об облачной версии.');
    }
    return RemoteVaultInfo(
      modifiedAt: DateTime.parse(modified).toLocal(),
      size: payload['size'] as int? ?? 0,
    );
  }

  /// Keeps the current device state before remote data replaces it.
  Future<SyncVersion> backupLocal({
    required List<VaultFolder> folders,
    required List<PasswordEntry> entries,
    required String password,
  }) async {
    final bytes = await _codec.export(
      folders: folders,
      entries: entries,
      password: password,
    );
    final folder = await _oauth.syncFolder();
    await prepareFolder(folder);
    return _uploadSnapshot(
      folder: folder,
      prefix: 'local-before-restore',
      bytes: bytes,
    );
  }

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
    final folder = await _oauth.syncFolder();
    await prepareFolder(folder);
    await _backupCurrentCloudVersion(folder);
    await _upload(_currentPath(folder), bytes);
    return _uploadSnapshot(folder: folder, prefix: 'cloud', bytes: bytes);
  }

  Future<VaultSnapshot> download({required String password}) async {
    final token = await _oauth.token();
    final folder = await _oauth.syncFolder();
    final response = await _client.get(
      Uri.https('cloud-api.yandex.net', '/v1/disk/resources/download', {
        'path': _currentPath(folder),
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
        'path': 'disk:/$name',
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

  /// A desktop KeePass client may have written the shared file since the phone
  /// last used it. Preserve that exact cloud file before the phone replaces it.
  Future<void> _backupCurrentCloudVersion(String folder) async {
    final token = await _oauth.token();
    final response = await _client.get(
      Uri.https('cloud-api.yandex.net', '/v1/disk/resources/download', {
        'path': _currentPath(folder),
      }),
      headers: {'Authorization': 'OAuth $token'},
    );
    if (response.statusCode == 404) return;
    final href =
        (jsonDecode(response.body) as Map<String, dynamic>)['href'] as String?;
    if (response.statusCode != 200 || href == null) {
      throw StateError('Не удалось сохранить предыдущую облачную версию.');
    }
    final file = await _client.get(Uri.parse(href));
    if (file.statusCode != 200) {
      throw StateError('Не удалось скачать предыдущую облачную версию.');
    }
    await _uploadSnapshot(
      folder: folder,
      prefix: 'cloud-before-upload',
      bytes: Uint8List.fromList(file.bodyBytes),
    );
  }

  Future<SyncVersion> _uploadSnapshot({
    required String folder,
    required String prefix,
    required Uint8List bytes,
  }) async {
    final createdAt = DateTime.now().toUtc();
    final stamp = createdAt.toIso8601String().replaceAll(':', '-');
    final id = sha256.convert(bytes).toString().substring(0, 12);
    final path = 'disk:/$folder/$_historyFolderName/$prefix-$stamp-$id.kdbx';
    await _upload(path, bytes);
    return SyncVersion(id: id, createdAt: createdAt, path: path);
  }

  String _currentPath(String folder) => 'disk:/$folder/$_vaultFileName';
}

class RemoteVaultInfo {
  const RemoteVaultInfo({required this.modifiedAt, required this.size});
  final DateTime modifiedAt;
  final int size;
}

class CloudVaultVersion {
  const CloudVaultVersion({
    required this.name,
    required this.modifiedAt,
    required this.size,
  });
  final String name;
  final DateTime modifiedAt;
  final int size;
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
