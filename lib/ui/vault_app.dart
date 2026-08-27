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
import 'package:url_launcher/url_launcher.dart';

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
      requestApproval: _confirmMcpAction,
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
    final delay = await widget.repository.unlockDelay();
    if (delay > Duration.zero) {
      throw StateError(
        'Повторите через ${delay.inSeconds + 1} с. после нескольких неверных PIN.',
      );
    }
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
        yandexOAuth: _yandex,
        yandexSync: _sync,
        onYandexUpload: _syncUpload,
        onYandexDownload: _syncDownload,
      ),
    ),
  );

  Future<void> _finishFirstVaultSetup(String pin) async {
    await widget.repository.createMasterPin(pin);
    await _completeFirstVaultSetup(pin);
  }

  /// Imports a KDBX before any local vault exists. The KeePass password only
  /// opens the selected file; the new master PIN protects its local copy.
  Future<void> _importFirstKdbx(String pin) async {
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
      await widget.repository.createMasterPin(pin);
      await widget.repository.saveFolders(snapshot.folders);
      await widget.repository.saveEntries(snapshot.entries);
      await _completeFirstVaultSetup(
        pin,
        folders: snapshot.folders,
        entries: snapshot.entries,
      );
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

  Future<void> _completeFirstVaultSetup(
    String pin, {
    List<VaultFolder>? folders,
    List<PasswordEntry>? entries,
  }) async {
    if (!mounted) return;
    // A newly created vault is already authenticated by the PIN confirmation.
    setState(() {
      _hasMasterPin = true;
      _folders = folders ?? _folders;
      _entries = entries ?? _entries;
      _folderId = 'root';
      _unlocked = true;
      _vaultPassword = pin;
    });
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
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('«${entry.title}» удалена'),
        action: SnackBarAction(
          label: 'Отменить',
          onPressed: () async {
            setState(() => _entries = [..._entries, entry]);
            await widget.repository.saveEntries(_entries);
          },
        ),
      ),
    );
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
    if (password == null) {
      _showMessage('Для восстановления введите мастер-PIN, а не биометрию.');
      return;
    }
    try {
      final remote = await _sync.remoteInfo();
      if (remote == null) {
        _showMessage('В выбранной папке пока нет хранилища.');
        return;
      }
      final localModifiedAt = await widget.repository.vaultModifiedAt();
      if (!mounted ||
          !await _confirmYandexRestore(
            localModifiedAt: localModifiedAt,
            remoteModifiedAt: remote.modifiedAt,
          )) {
        return;
      }
      await _sync.backupLocal(
        folders: _folders,
        entries: _entries,
        password: password,
      );
      final snapshot = await _sync.download(password: password);
      setState(() {
        _folders = snapshot.folders;
        _entries = snapshot.entries;
        _folderId = 'root';
      });
      await widget.repository.saveFolders(_folders);
      await widget.repository.saveEntries(_entries);
      if (mounted)
        _showMessage(
          'Данные восстановлены. Локальная версия сохранена в истории на Диске.',
        );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<bool> _confirmYandexRestore({
    required DateTime localModifiedAt,
    required DateTime remoteModifiedAt,
  }) async {
    final localIsNewer = localModifiedAt.isAfter(remoteModifiedAt);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Заменить локальное хранилище?'),
        content: Text(
          'Локальная версия: ${_formatDate(localModifiedAt)}\n'
          'Версия на Диске: ${_formatDate(remoteModifiedAt)}\n\n'
          '${localIsNewer ? 'Локальная версия новее. ' : ''}'
          'Перед восстановлением KeyKeep автоматически сохранит текущую локальную версию в истории на Яндекс Диске.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сохранить и восстановить'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<bool> _confirmMcpAction(McpApprovalRequest request) async {
    if (!mounted || !_unlocked) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.shield_outlined),
        title: Text(request.action),
        content: Text(request.details),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отклонить'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Разрешить'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _showMessage(String value) {
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
  }

  String _formatDate(DateTime value) {
    if (value.millisecondsSinceEpoch == 0) return 'нет локальной версии';
    return '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year} '
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
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

  Future<void> _showFolderActions(VaultFolder folder) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Переименовать'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: const Text('Переместить'),
              onTap: () => Navigator.pop(context, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Удалить'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'rename') await _renameFolder(folder);
    if (action == 'move') await _moveFolder(folder);
    if (action == 'delete') await _deleteFolder(folder);
  }

  Future<void> _renameFolder(VaultFolder folder) async {
    final controller = TextEditingController(text: folder.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Переименовать папку'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    setState(
      () => _folders = _folders
          .map(
            (item) => item.id == folder.id
                ? VaultFolder(id: item.id, name: name, parentId: item.parentId)
                : item,
          )
          .toList(),
    );
    await widget.repository.saveFolders(_folders);
  }

  Future<void> _moveFolder(VaultFolder folder) async {
    final descendants = _descendantIds(folder.id);
    final candidates = _folders
        .where((item) => item.id != folder.id && !descendants.contains(item.id))
        .toList();
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Переместить в папку'),
        children: candidates
            .map(
              (item) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, item.id),
                child: Text(_folderLabel(item)),
              ),
            )
            .toList(),
      ),
    );
    if (target == null || target == folder.parentId) return;
    setState(
      () => _folders = _folders
          .map(
            (item) => item.id == folder.id
                ? VaultFolder(id: item.id, name: item.name, parentId: target)
                : item,
          )
          .toList(),
    );
    await widget.repository.saveFolders(_folders);
  }

  Future<void> _deleteFolder(VaultFolder folder) async {
    final ids = _descendantIds(folder.id)..add(folder.id);
    final count = _entries
        .where((entry) => ids.contains(entry.folderId))
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить папку?'),
        content: Text('Будут удалены папка, вложенные папки и $count записей.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _folders = _folders.where((item) => !ids.contains(item.id)).toList();
      _entries = _entries
          .where((entry) => !ids.contains(entry.folderId))
          .toList();
      if (ids.contains(_folderId)) _folderId = 'root';
    });
    await widget.repository.saveFolders(_folders);
    await widget.repository.saveEntries(_entries);
  }

  Set<String> _descendantIds(String parentId) {
    final result = <String>{};
    var frontier = <String>{parentId};
    while (frontier.isNotEmpty) {
      final children = _folders
          .where((folder) => frontier.contains(folder.parentId))
          .map((folder) => folder.id)
          .toSet();
      result.addAll(children);
      frontier = children;
    }
    return result;
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
      return _CreatePinScreen(
        onCreated: _finishFirstVaultSetup,
        onImport: _importFirstKdbx,
      );
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
          final searchable = [
            entry.title,
            entry.username,
            entry.website,
            entry.note,
            ...entry.customFields.map(
              (field) => '${field.name} ${field.value}',
            ),
          ].join(' ');
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
                          onLongPress: () => _showFolderActions(folder),
                        ),
                        const Divider(height: 1),
                      ],
                      if (childFolders.isNotEmpty && visible.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
                          child: Text('Записи'),
                        ),
                      for (final entry in visible) ...[
                        Dismissible(
                          key: ValueKey(entry.id),
                          direction: DismissDirection.endToStart,
                          background: const ColoredBox(
                            color: Colors.red,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: EdgeInsets.only(right: 20),
                                child: Icon(
                                  Icons.delete_outline,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                          confirmDismiss: (_) async => true,
                          onDismissed: (_) => _delete(entry),
                          child: _EntryTile(
                            entry: entry,
                            folderPath: searching
                                ? _folderPathText(entry.folderId)
                                : null,
                            onEdit: () => _edit(entry),
                            onDelete: () => _delete(entry),
                            onHistory: () => _showPasswordHistory(entry),
                            onOpenWebsite: () => _openWebsite(entry.website),
                          ),
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
                        title: Text(
                          revision.values['title'] as String? ?? entry.title,
                        ),
                        subtitle: Text(
                          '${revision.changedAt.toLocal().toString().substring(0, 16)} · '
                          'логин: ${revision.values['username'] as String? ?? '—'}',
                        ),
                        trailing: IconButton(
                          tooltip: 'Показать пароль из версии',
                          icon: const Icon(Icons.visibility_outlined),
                          onPressed: () => _showRevisionPassword(revision),
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

  Future<void> _openWebsite(String source) async {
    if (source.trim().isEmpty) return;
    final uri = Uri.tryParse(
      source.contains('://') ? source : 'https://$source',
    );
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) {
      _showMessage('Не удалось открыть сайт.');
    }
  }

  Future<void> _showRevisionPassword(PasswordRevision revision) async {
    final password = revision.values['password'] as String? ?? '';
    if (password.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Пароль из версии'),
        content: SelectableText(password),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

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
  const _CreatePinScreen({required this.onCreated, required this.onImport});
  final Future<void> Function(String) onCreated;
  final Future<void> Function(String) onImport;
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
    if (!_validatePin(pin)) return;
    setState(() => _busy = true);
    await widget.onCreated(pin);
    if (mounted) setState(() => _busy = false);
  }

  bool _validatePin(String pin) {
    if (pin.length < 6 || pin != _confirmation.text) {
      setState(
        () => _error = pin.length < 6
            ? 'PIN должен содержать не менее 6 символов.'
            : 'PIN-коды не совпадают.',
      );
      return false;
    }
    return true;
  }

  Future<void> _import() async {
    final pin = _pin.text;
    if (!_validatePin(pin)) return;
    setState(() => _busy = true);
    await widget.onImport(pin);
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
    label: 'Создать пустое хранилище',
    secondaryAction: _import,
    secondaryLabel: 'Импортировать KeePass (.kdbx)',
    secondaryIcon: Icons.file_open_outlined,
    footer: const Text(
      'Для импорта также понадобится пароль выбранной KeePass-базы. '
      'Новый мастер-PIN защитит её локальную копию.',
      textAlign: TextAlign.center,
    ),
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
    this.secondaryIcon,
    this.footer,
  });
  final String title, subtitle, label;
  final TextEditingController controller;
  final TextEditingController? confirmation;
  final Future<void> Function() action;
  final bool busy;
  final String? error;
  final Future<void> Function()? secondaryAction;
  final String? secondaryLabel;
  final IconData? secondaryIcon;
  final Widget? footer;

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
                    icon: Icon(secondaryIcon ?? Icons.fingerprint),
                    label: Text(secondaryLabel!),
                  ),
                ],
                if (footer != null) ...[
                  const SizedBox(height: 12),
                  DefaultTextStyle.merge(
                    style: Theme.of(context).textTheme.bodySmall,
                    child: footer!,
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
    required this.onOpenWebsite,
  });
  final PasswordEntry entry;
  final String? folderPath;
  final VoidCallback onEdit, onDelete, onOpenWebsite;
  final VoidCallback onHistory;
  @override
  State<_EntryTile> createState() => _EntryTileState();
}

class _EntryTileState extends State<_EntryTile> {
  var _revealed = false;
  Timer? _clipboardTimer;
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
          onPressed: _copyPassword,
          icon: const Icon(Icons.copy_outlined),
        ),
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'delete') widget.onDelete();
            if (value == 'history') widget.onHistory();
            if (value == 'website') widget.onOpenWebsite();
          },
          itemBuilder: (_) => [
            if (widget.entry.website.trim().isNotEmpty)
              const PopupMenuItem(
                value: 'website',
                child: Text('Открыть сайт'),
              ),
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

  Future<void> _copyPassword() async {
    final password = widget.entry.password;
    await Clipboard.setData(ClipboardData(text: password));
    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(const Duration(seconds: 30), () async {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text == password) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Пароль скопирован на 30 секунд')),
      );
    }
  }

  @override
  void dispose() {
    _clipboardTimer?.cancel();
    super.dispose();
  }
}
