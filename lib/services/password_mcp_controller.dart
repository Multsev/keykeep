// ignore_for_file: curly_braces_in_flow_control_structures, prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:keykeep_passwords/domain/password_entry.dart';
import 'package:keykeep_passwords/domain/vault_folder.dart';

typedef PasswordVaultReader =
    ({List<VaultFolder> folders, List<PasswordEntry> entries}) Function();
typedef PasswordVaultWriter = Future<void> Function(
  List<PasswordEntry> entries,
);

/// Exposes an unlocked vault through a token-protected local MCP endpoint.
class PasswordMcpController extends ChangeNotifier {
  PasswordMcpController({
    required PasswordVaultReader readVault,
    required PasswordVaultWriter writeEntries,
    FlutterSecureStorage? storage,
  }) : _readVault = readVault,
       _writeEntries = writeEntries,
       _storage = storage ?? const FlutterSecureStorage();
  static const _tokenKey = 'keykeep_mcp_token';
  final PasswordVaultReader _readVault;
  final PasswordVaultWriter _writeEntries;
  final FlutterSecureStorage _storage;
  HttpServer? _server;
  String _token = '';
  bool _readWrite = false;
  String? _advertisedAddress;

  bool get isRunning => _server != null;
  bool get readWrite => _readWrite;
  String? get endpoint => _server == null
      ? null
      : 'http://$_advertisedAddress:${_server!.port}/mcp';
  String get connectionCommand =>
      "export KEYKEEP_MCP_TOKEN='$_token'\ncodex mcp add keykeep --url '$endpoint' --bearer-token-env-var KEYKEEP_MCP_TOKEN";

  Future<void> start({bool readWrite = false}) async {
    if (isRunning) return;
    _readWrite = readWrite;
    _token = await _loadToken();
    _server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      8766,
      shared: false,
    );
    _advertisedAddress = await _localAddress();
    unawaited(_serve(_server!));
    notifyListeners();
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _advertisedAddress = null;
    _token = '';
    if (server != null) await server.close(force: true);
    notifyListeners();
  }

  Future<void> setReadWrite(bool value) async {
    _readWrite = value;
    notifyListeners();
  }

  Future<void> rotateToken() async {
    _token = await _newToken();
    notifyListeners();
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<String> _localAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (_isPrivateAddress(address.address)) return address.address;
      }
    }
    return InternetAddress.loopbackIPv4.address;
  }

  bool _isPrivateAddress(String value) =>
      value.startsWith('10.') ||
      value.startsWith('192.168.') ||
      RegExp(r'^172\.(1[6-9]|2[0-9]|3[0-1])\.').hasMatch(value);

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path != '/mcp' || request.method != 'POST') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (!_authorized(request)) {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer',
        );
        await request.response.close();
        return;
      }
      final source = await utf8.decoder.bind(request).join();
      final message = jsonDecode(source) as Map<String, dynamic>;
      final id = message['id'];
      final result = await _dispatch(
        message['method'] as String,
        Map<String, dynamic>.from(message['params'] as Map? ?? const {}),
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
      );
      await request.response.close();
    } catch (error) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32603, 'message': error.toString()},
        }),
      );
      await request.response.close();
    }
  }

  bool _authorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    return header != null &&
        header.startsWith('Bearer ') &&
        _constantTime(header.substring(7), _token);
  }

  bool _constantTime(String a, String b) {
    if (a.length != b.length) return false;
    var value = 0;
    for (var i = 0; i < a.length; i++) {
      value |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return value == 0;
  }

  Future<Map<String, Object?>> _dispatch(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method == 'initialize')
      return {
        'protocolVersion': '2025-06-18',
        'capabilities': {
          'tools': {'listChanged': false},
        },
        'serverInfo': {'name': 'KeyKeep', 'version': '1.0'},
        'instructions': 'Vault is sensitive. Use list_vault_structure first; request passwords only when necessary.',
      };
    if (method == 'ping') return {};
    if (method == 'tools/list') return {'tools': _tools};
    if (method == 'tools/call') return _call(params);
    throw FormatException('Unsupported MCP method: $method');
  }

  List<Map<String, Object>> get _tools => [
    {
      'name': 'list_vault_structure',
      'description': 'Lists folders and entry metadata without passwords.',
      'inputSchema': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'get_password_entry',
      'description':
          'Reads one full entry, including protected fields and password.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
    },
    {
      'name': 'upsert_password_entry',
      'description': 'Creates or updates a password entry. Available only in read/write mode.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'title': {'type': 'string'},
          'username': {'type': 'string'},
          'password': {'type': 'string'},
          'folderId': {'type': 'string'},
        },
        'required': ['title', 'username', 'password'],
      },
    },
  ];
  Future<Map<String, Object?>> _call(Map<String, dynamic> params) async {
    final name = params['name'] as String?;
    final args = Map<String, dynamic>.from(
      params['arguments'] as Map? ?? const {},
    );
    final vault = _readVault();
    Object result;
    if (name == 'list_vault_structure')
      result = {
        'folders': vault.folders.map((folder) => folder.toJson()).toList(),
        'entries': vault.entries
            .map(
              (entry) => {
                'id': entry.id,
                'title': entry.title,
                'username': entry.username,
                'folderId': entry.folderId,
                'updatedAt': entry.updatedAt.toIso8601String(),
              },
            )
            .toList(),
      };
    else if (name == 'get_password_entry') {
      final id = args['id'] as String?;
      final entry = vault.entries.where((value) => value.id == id).firstOrNull;
      if (entry == null) throw FormatException('Entry not found.');
      result = entry.toJson();
    } else if (name == 'upsert_password_entry') {
      if (!_readWrite) throw FormatException('MCP is in read-only mode.');
      final id = args['id'] as String?;
      final index = vault.entries.indexWhere((entry) => entry.id == id);
      final changed = PasswordEntry(
        id: id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        title: _string(args, 'title'),
        username: _string(args, 'username'),
        password: _string(args, 'password'),
        website: args['website'] as String? ?? '',
        note: args['note'] as String? ?? '',
        updatedAt: DateTime.now(),
        folderId: args['folderId'] as String? ?? 'root',
      );
      final entries = [...vault.entries];
      if (index < 0) {
        entries.add(changed);
      } else {
        entries[index] = vault.entries[index].copyWith(
          title: changed.title,
          username: changed.username,
          password: changed.password,
          website: changed.website,
          note: changed.note,
          folderId: changed.folderId,
        );
      }
      await _writeEntries(entries);
      result = {'id': changed.id, 'updated': index >= 0};
    } else
      throw FormatException('Unknown tool: $name');
    return {
      'content': [
        {
          'type': 'text',
          'text': const JsonEncoder.withIndent('  ').convert(result),
        },
      ],
      'structuredContent': result,
      'isError': false,
    };
  }

  String _string(Map<String, dynamic> values, String key) {
    final value = values[key];
    if (value is! String || value.isEmpty)
      throw FormatException('$key is required.');
    return value;
  }

  Future<String> _loadToken() async =>
      (await _storage.read(key: _tokenKey)) ?? _newToken();
  Future<String> _newToken() async {
    final token = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    await _storage.write(key: _tokenKey, value: token);
    return token;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
