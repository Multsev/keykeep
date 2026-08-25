// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keykeep_passwords/data/vault_repository.dart';
import 'package:keykeep_passwords/domain/password_entry.dart';
import 'package:keykeep_passwords/domain/vault_folder.dart';
import 'package:keykeep_passwords/services/kdbx_vault_codec.dart';
import 'package:keykeep_passwords/services/biometric_unlock.dart';
import 'package:keykeep_passwords/services/totp_generator.dart';
import 'package:keykeep_passwords/services/yandex_disk_oauth.dart';
import 'package:keykeep_passwords/services/yandex_vault_sync.dart';
import 'package:keykeep_passwords/services/password_mcp_controller.dart';
import 'package:keykeep_passwords/ui/password_editor.dart';
import 'package:keykeep_passwords/ui/vault_settings.dart';

class VaultApp extends StatefulWidget {
  const VaultApp({super.key, required this.repository});

  final VaultRepository repository;

  @override
  State<VaultApp> createState() => _VaultAppState();
}

class _VaultAppState extends State<VaultApp> with WidgetsBindingObserver {
  bool? _hasMasterPin;
  var _unlocked = false;
  List<PasswordEntry> _entries = [];
  List<VaultFolder> _folders = const [];
  String _query = '';
  String _folderId = 'root';
  var _biometricEnabled = false;
  var _biometricAutoPrompt = true;
  final _yandex = YandexDiskOAuthService();
  late final YandexVaultSync _sync = YandexVaultSync(oauth: _yandex);
  late final PasswordMcpController _mcp;
  final _biometric = BiometricUnlock();
  StreamSubscription<Uri>? _oauthLinks;
  String? _vaultPassword;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mcp = PasswordMcpController(
      readVault: () => (folders: _folders, entries: _entries),
      writeEntries: (entries) async {
        if (mounted) setState(() => _entries = entries);
        await widget.repository.saveEntries(entries);
      },
    );
    _oauthLinks = AppLinks().uriLinkStream.listen(_completeYandexAuthorization);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _oauthLinks?.cancel();
    _mcp.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && mounted) {
      setState(() => _unlocked = false);
      _vaultPassword = null;
      unawaited(_mcp.stop());
    }
  }

  Future<void> _load() async {
    final hasPin = await widget.repository.hasMasterPin();
    final biometricEnabled = await widget.repository.hasBiometricUnlock();
    final biometricAutoPrompt = await widget.repository.biometricAutoPrompt();
    if (!mounted) return;
    setState(() {
      _hasMasterPin = hasPin;
      _biometricEnabled = biometricEnabled;
      _biometricAutoPrompt = biometricAutoPrompt;
      _unlocked = false;
    });
  }

  Future<void> _unlock(String pin) async {
    if (!await widget.repository.unlock(pin)) {
      throw StateError('Неверный PIN');
    }
    final entries = await widget.repository.loadEntries();
    final folders = await widget.repository.loadFolders();
    if (mounted) {
      setState(() {
        _entries = entries;
        _folders = folders;
        _unlocked = true;
        _vaultPassword = pin;
      });
    }
  }

  Future<void> _unlockWithBiometrics() async {
    if (!await _biometric.verify() ||
        !await widget.repository.biometricUnlock()) {
      throw StateError('Не удалось разблокировать хранилище по биометрии.');
    }
    final entries = await widget.repository.loadEntries();
    final folders = await widget.repository.loadFolders();
    if (mounted) {
      setState(() {
        _entries = entries;
        _folders = folders;
        _unlocked = true;
        _vaultPassword = null;
      });
    }
  }

  Future<bool> _configureBiometrics() async {
    final password = _vaultPassword;
    if (password == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Введите мастер-PIN после биометрического входа, чтобы настроить синхронизацию.',
          ),
        ),
      );
      return false;
    }
    if (!await _biometric.isAvailable()) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('На устройстве нет настроенной биометрии.'),
          ),
        );
      return false;
    }
    if (!await _biometric.verify()) return false;
    await widget.repository.enableBiometricUnlock(password);
    if (mounted) {
      setState(() {
        _biometricEnabled = true;
        _biometricAutoPrompt = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Вход по отпечатку или лицу включён.')),
      );
    }
    return true;
  }

  Future<void> _disableBiometrics() async {
    await widget.repository.disableBiometricUnlock();
    if (mounted) {
      setState(() {
        _biometricEnabled = false;
        _biometricAutoPrompt = false;
      });
    }
  }

  Future<void> _setBiometricAutoPrompt(bool enabled) async {
    await widget.repository.setBiometricAutoPrompt(enabled);
    if (mounted) setState(() => _biometricAutoPrompt = enabled);
  }

  Future<void> _deleteVault() async {
    await widget.repository.deleteVault();
    await _mcp.stop();
    if (!mounted) return;
    Navigator.of(context).pop();
    setState(() {
      _hasMasterPin = false;
      _unlocked = false;
      _biometricEnabled = false;
      _biometricAutoPrompt = false;
      _entries = [];
      _folders = const [];
      _folderId = 'root';
      _vaultPassword = null;
    });
  }

  Future<void> _openSettings() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => VaultSettings(
        biometricEnabled: _biometricEnabled,
        biometricAutoPrompt: _biometricAutoPrompt,
        onEnableBiometrics: _configureBiometrics,
        onDisableBiometrics: _disableBiometrics,
        onSetAutoPrompt: _setBiometricAutoPrompt,
        onImportVault: _importKdbx,
        onExportVault: _exportKdbx,
        onDeleteVault: _deleteVault,
        mcpController: _mcp,
      ),
    ),
  );

  Future<void> _finishFirstVaultSetup(String pin) async {
    await widget.repository.createMasterPin(pin);
    if (!mounted) return;
    // A newly created vault is already authenticated by the PIN confirmation.
    setState(() => _hasMasterPin = true);
    await _unlock(pin);
    if (!mounted) return;
    final biometricAvailable = await _biometric.isAvailable();
    if (!mounted || !biometricAvailable) return;
    final enable = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.fingerprint),
        title: const Text('Включить вход по биометрии?'),
        content: const Text(
          'При следующих открытиях можно будет разблокировать хранилище отпечатком пальца или лицом.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Позже'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Включить'),
          ),
        ],
      ),
    );
    if (enable == true && mounted) await _configureBiometrics();
  }

  Future<void> _save(PasswordEntry entry) async {
    final index = _entries.indexWhere((item) => item.id == entry.id);
    setState(() {
      if (index < 0) {
        _entries = [..._entries, entry];
      } else {
        _entries = [..._entries]..[index] = entry;
      }
    });
    await widget.repository.saveEntries(_entries);
  }

  Future<void> _edit([PasswordEntry? entry]) async {
    final saved = await Navigator.push<PasswordEntry>(
      context,
      MaterialPageRoute(
        builder: (_) => PasswordEditor(folders: _folders, entry: entry),
      ),
    );
    if (saved != null) await _save(saved);
  }

  Future<void> _delete(PasswordEntry entry) async {
    setState(
      () => _entries = _entries.where((item) => item.id != entry.id).toList(),
    );
    await widget.repository.saveEntries(_entries);
  }

  Future<void> _completeYandexAuthorization(Uri callback) async {
    try {
      await _yandex.completeAuthorization(callback);
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Яндекс Диск подключён.')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _syncUpload() async {
    final password = _vaultPassword;
    if (password == null) return;
    try {
      final version = await _sync.upload(
        folders: _folders,
        entries: _entries,
        password: password,
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Синхронизировано. Версия ${version.id} сохранена в истории.',
            ),
          ),
        );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _syncDownload() async {
    final password = _vaultPassword;
    if (password == null) return;
    try {
      final snapshot = await _sync.download(password: password);
      setState(() {
        _folders = snapshot.folders;
        _entries = snapshot.entries;
        _folderId = 'root';
      });
      await widget.repository.saveFolders(_folders);
      await widget.repository.saveEntries(_entries);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Данные восстановлены с Яндекс Диска.')),
        );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _showSyncSheet() async {
    final connected = await _yandex.isConnected;
    final configured = await _yandex.isConfigured;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Яндекс Диск'),
              subtitle: Text(
                connected
                    ? 'Подключён'
                    : (configured ? 'Не подключён' : 'Нужен OAuth client ID'),
              ),
            ),
            if (!configured)
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Указать OAuth client ID'),
                subtitle: const Text(
                  'Публичный идентификатор приложения из Яндекс ID',
                ),
                onTap: () async {
                  final saved = await _askYandexClientId();
                  if (saved && context.mounted) Navigator.pop(context);
                },
              ),
            if (!connected)
              ListTile(
                leading: const Icon(Icons.login),
                title: const Text('Подключить по OAuth'),
                enabled: configured,
                onTap: () {
                  Navigator.pop(context);
                  _yandex.startAuthorization().catchError((error) {
                    if (mounted) {
                      ScaffoldMessenger.of(
                        this.context,
                      ).showSnackBar(SnackBar(content: Text(error.toString())));
                    }
                  });
                },
              ),
            if (connected) ...[
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: const Text('Загрузить на Диск'),
                onTap: () {
                  Navigator.pop(context);
                  _syncUpload();
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_download_outlined),
                title: const Text('Скачать с Диска'),
                onTap: () {
                  Navigator.pop(context);
                  _syncDownload();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<bool> _askYandexClientId() async {
    final controller = TextEditingController(text: await _yandex.clientId());
    if (!mounted) return false;
    final clientId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('OAuth client ID Яндекса'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Client ID'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (clientId == null || clientId.trim().isEmpty) return false;
    await _yandex.saveClientId(clientId);
    return true;
  }

  Future<void> _addFolder() async {
    final controller = TextEditingController();
    var parentId = _folderId;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Новая папка'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Название'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: parentId,
                decoration: const InputDecoration(
                  labelText: 'Родительская папка',
                ),
                items: _folders
                    .map(
                      (folder) => DropdownMenuItem(
                        value: folder.id,
                        child: Text(_folderLabel(folder)),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setDialogState(() => parentId = value ?? 'root'),
              ),
            ],
          ),
          actions: [
            IconButton(
              onPressed: _showSyncSheet,
              icon: const Icon(Icons.cloud_sync_outlined),
              tooltip: 'Синхронизация с Яндекс Диском',
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final folder = VaultFolder(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      parentId: parentId,
    );
    setState(() => _folders = [..._folders, folder]);
    await widget.repository.saveFolders(_folders);
  }

  Future<String?> _askKdbxPassword(String title) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Пароль базы KeePass'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    controller.dispose();
    return password?.isEmpty ?? true ? null : password;
  }

  Future<void> _exportKdbx() async {
    final password = await _askKdbxPassword('Экспорт KeePass (.kdbx)');
    if (password == null) return;
    try {
      final bytes = await KdbxVaultCodec().export(
        folders: _folders,
        entries: _entries,
        password: password,
      );
      await FilePicker.saveFile(
        dialogTitle: 'Сохранить KeePass-базу',
        fileName: 'KeyKeep.kdbx',
        type: FileType.custom,
        allowedExtensions: const ['kdbx'],
        bytes: bytes,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось экспортировать KDBX.')),
        );
      }
    }
  }

  Future<void> _importKdbx() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['kdbx'],
    );
    if (picked == null) return;
    final password = await _askKdbxPassword('Открыть KeePass (.kdbx)');
    if (password == null) return;
    try {
      final snapshot = await KdbxVaultCodec().import(
        Uint8List.fromList(await picked.readAsBytes()),
        password,
      );
      setState(() {
        _folders = snapshot.folders;
        _entries = snapshot.entries;
        _folderId = 'root';
      });
      await widget.repository.saveFolders(_folders);
      await widget.repository.saveEntries(_entries);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('KeePass-база импортирована.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть KDBX: проверьте пароль и файл.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPin = _hasMasterPin;
    if (hasPin == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!hasPin) {
      return _CreatePinScreen(onCreated: _finishFirstVaultSetup);
    }
    return _unlocked
        ? _vault(context)
        : _UnlockScreen(
            onUnlock: _unlock,
            onBiometricUnlock: _biometricEnabled ? _unlockWithBiometrics : null,
            autoPromptBiometrics: _biometricEnabled && _biometricAutoPrompt,
          );
  }

  Widget _vault(BuildContext context) {
    final searching = _query.trim().isNotEmpty;
    final visible =
        _entries.where((entry) {
          final searchable =
              '${entry.title} ${entry.username} ${entry.website}';
          return (searching || entry.folderId == _folderId) &&
              searchable.toLowerCase().contains(_query.toLowerCase());
        }).toList()..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
    final childFolders =
        searching
              ? const <VaultFolder>[]
              : _folders
                    .where(
                      (folder) =>
                          folder.id != 'root' && folder.parentId == _folderId,
                    )
                    .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return Scaffold(
      appBar: AppBar(
        title: const Text('KeyKeep'),
        actions: [
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Настройки',
          ),
          IconButton(
            onPressed: _addFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Новая папка',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'import') _importKdbx();
              if (value == 'export') _exportKdbx();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'import',
                child: Text('Импорт KeePass (.kdbx)'),
              ),
              PopupMenuItem(
                value: 'export',
                child: Text('Экспорт KeePass (.kdbx)'),
              ),
            ],
          ),
          IconButton(
            onPressed: () {
              setState(() {
                _unlocked = false;
                _vaultPassword = null;
              });
              unawaited(_mcp.stop());
            },
            icon: const Icon(Icons.lock_outline),
            tooltip: 'Заблокировать',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _edit,
        icon: const Icon(Icons.add),
        label: const Text('Запись'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SearchBar(
              leading: const Icon(Icons.search),
              hintText: 'Поиск в хранилище',
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          if (!searching)
            _FolderBreadcrumbs(
              folders: _folderPath(_folderId),
              onOpen: (folder) => setState(() => _folderId = folder.id),
            ),
          Expanded(
            child: visible.isEmpty && childFolders.isEmpty
                ? Center(
                    child: Text(
                      _entries.isEmpty
                          ? 'Хранилище пока пустое\nДобавьте первую учётную запись.'
                          : 'Ничего не найдено',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView(
                    children: [
                      for (final folder in childFolders) ...[
                        ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(folder.name),
                          subtitle: Text(_folderContentsLabel(folder.id)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => setState(() => _folderId = folder.id),
                        ),
                        const Divider(height: 1),
                      ],
                      if (childFolders.isNotEmpty && visible.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
                          child: Text('Записи'),
                        ),
                      for (final entry in visible) ...[
                        _EntryTile(
                          entry: entry,
                          folderPath: searching
                              ? _folderPathText(entry.folderId)
                              : null,
                          onEdit: () => _edit(entry),
                          onDelete: () => _delete(entry),
                          onHistory: () => _showPasswordHistory(entry),
                        ),
                        const Divider(height: 1),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _showPasswordHistory(PasswordEntry entry) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('История: ${entry.title}'),
      content: SizedBox(
        width: double.maxFinite,
        child: entry.history.isEmpty
            ? const Text('Пароль ещё не изменялся.')
            : ListView(
                children: entry.history.reversed
                    .map(
                      (revision) => ListTile(
                        title: SelectableText(revision.password),
                        subtitle: Text(
                          revision.changedAt.toLocal().toString().substring(
                            0,
                            16,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );

  List<VaultFolder> _folderPath(String folderId) {
    final path = <VaultFolder>[];
    var currentId = folderId;
    while (true) {
      final matches = _folders.where((folder) => folder.id == currentId);
      if (matches.isEmpty) break;
      final folder = matches.first;
      path.insert(0, folder);
      if (folder.id == 'root') break;
      currentId = folder.parentId;
    }
    return path;
  }

  String _folderPathText(String folderId) =>
      _folderPath(folderId).map((folder) => folder.name).join(' › ');

  String _folderContentsLabel(String folderId) {
    final nestedFolders = _folders
        .where((folder) => folder.parentId == folderId)
        .length;
    final entries = _entries
        .where((entry) => entry.folderId == folderId)
        .length;
    final parts = <String>[];
    if (nestedFolders > 0) parts.add('$nestedFolders папок');
    if (entries > 0) parts.add('$entries записей');
    return parts.isEmpty ? 'Пустая папка' : parts.join(' · ');
  }

  String _folderLabel(VaultFolder folder) {
    var depth = 0;
    var parent = folder.parentId;
    while (parent != 'root' && depth < 6) {
      final match = _folders.where((item) => item.id == parent);
      if (match.isEmpty) break;
      parent = match.first.parentId;
      depth++;
    }
    return '${'› ' * depth}${folder.name}';
  }
}

class _FolderBreadcrumbs extends StatelessWidget {
  const _FolderBreadcrumbs({required this.folders, required this.onOpen});

  final List<VaultFolder> folders;
  final ValueChanged<VaultFolder> onOpen;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: folders.length,
      separatorBuilder: (_, _) => const Icon(Icons.chevron_right, size: 18),
      itemBuilder: (_, index) {
        final folder = folders[index];
        final current = index == folders.length - 1;
        return TextButton(
          onPressed: current ? null : () => onOpen(folder),
          child: Text(folder.name),
        );
      },
    ),
  );
}

class _UnlockScreen extends StatefulWidget {
  const _UnlockScreen({
    required this.onUnlock,
    this.onBiometricUnlock,
    required this.autoPromptBiometrics,
  });
  final Future<void> Function(String) onUnlock;
  final Future<void> Function()? onBiometricUnlock;
  final bool autoPromptBiometrics;
  @override
  State<_UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<_UnlockScreen> {
  final _pin = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoPromptBiometrics && widget.onBiometricUnlock != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _biometric());
    }
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onUnlock(_pin.text);
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _biometric() async {
    setState(() => _busy = true);
    try {
      await widget.onBiometricUnlock!();
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Gate(
    title: 'Хранилище заблокировано',
    subtitle: 'Введите мастер‑PIN, чтобы открыть записи.',
    controller: _pin,
    action: _submit,
    busy: _busy,
    error: _error,
    label: 'Открыть',
    secondaryAction: widget.onBiometricUnlock == null ? null : _biometric,
    secondaryLabel: 'Войти по отпечатку',
  );
}

class _CreatePinScreen extends StatefulWidget {
  const _CreatePinScreen({required this.onCreated});
  final Future<void> Function(String) onCreated;
  @override
  State<_CreatePinScreen> createState() => _CreatePinScreenState();
}

class _CreatePinScreenState extends State<_CreatePinScreen> {
  final _pin = TextEditingController();
  final _confirmation = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pin.text;
    if (pin.length < 6 || pin != _confirmation.text) {
      setState(
        () => _error = pin.length < 6
            ? 'PIN должен содержать не менее 6 символов.'
            : 'PIN-коды не совпадают.',
      );
      return;
    }
    setState(() => _busy = true);
    await widget.onCreated(pin);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => _Gate(
    title: 'Создайте мастер‑PIN',
    subtitle: 'Он защищает доступ к вашему локальному хранилищу. Восстановить его нельзя.',
    controller: _pin,
    confirmation: _confirmation,
    action: _submit,
    busy: _busy,
    error: _error,
    label: 'Создать хранилище',
  );
}

class _Gate extends StatelessWidget {
  const _Gate({
    required this.title,
    required this.subtitle,
    required this.controller,
    this.confirmation,
    required this.action,
    required this.busy,
    required this.error,
    required this.label,
    this.secondaryAction,
    this.secondaryLabel,
  });
  final String title, subtitle, label;
  final TextEditingController controller;
  final TextEditingController? confirmation;
  final Future<void> Function() action;
  final bool busy;
  final String? error;
  final Future<void> Function()? secondaryAction;
  final String? secondaryLabel;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.shield_outlined, size: 64),
                const SizedBox(height: 24),
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(subtitle, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.visiblePassword,
                  decoration: InputDecoration(
                    labelText: confirmation == null
                        ? 'Мастер‑PIN'
                        : 'Новый мастер‑PIN',
                    errorText: error,
                  ),
                ),
                if (confirmation != null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirmation,
                    obscureText: true,
                    keyboardType: TextInputType.visiblePassword,
                    decoration: const InputDecoration(
                      labelText: 'Повторите PIN',
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: busy ? null : action,
                  child: busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(label),
                ),
                if (secondaryAction != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: busy ? null : secondaryAction,
                    icon: const Icon(Icons.fingerprint),
                    label: Text(secondaryLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _EntryTile extends StatefulWidget {
  const _EntryTile({
    required this.entry,
    this.folderPath,
    required this.onEdit,
    required this.onDelete,
    required this.onHistory,
  });
  final PasswordEntry entry;
  final String? folderPath;
  final VoidCallback onEdit, onDelete;
  final VoidCallback onHistory;
  @override
  State<_EntryTile> createState() => _EntryTileState();
}

class _EntryTileState extends State<_EntryTile> {
  var _revealed = false;
  String? get _totp {
    final field = widget.entry.customFields.where(
      (item) => item.type == CustomFieldType.oneTimePassword,
    );
    if (field.isEmpty) return null;
    try {
      return const TotpGenerator().code(field.first.value);
    } on FormatException {
      return 'ошибка';
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: CircleAvatar(
      child: Text(
        widget.entry.title.isEmpty ? '?' : widget.entry.title[0].toUpperCase(),
      ),
    ),
    title: Text(widget.entry.title),
    subtitle: Text(
      _revealed
          ? widget.entry.password
          : [
              if (widget.folderPath != null) widget.folderPath!,
              widget.entry.username,
              if (_totp != null) 'TOTP: $_totp',
            ].where((text) => text.isNotEmpty).join(' · '),
    ),
    onTap: widget.onEdit,
    trailing: Wrap(
      spacing: -8,
      children: [
        IconButton(
          onPressed: () => setState(() => _revealed = !_revealed),
          icon: Icon(
            _revealed
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
          ),
        ),
        IconButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: widget.entry.password));
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Пароль скопирован')));
          },
          icon: const Icon(Icons.copy_outlined),
        ),
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'delete') widget.onDelete();
            if (value == 'history') widget.onHistory();
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'delete', child: Text('Удалить')),
            const PopupMenuItem(
              value: 'history',
              child: Text('История пароля'),
            ),
          ],
        ),
      ],
    ),
  );
}
