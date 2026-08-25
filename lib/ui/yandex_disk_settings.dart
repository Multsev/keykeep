import 'dart:async';

import 'package:flutter/material.dart';
import 'package:keykeep_passwords/services/yandex_disk_oauth.dart';
import 'package:keykeep_passwords/services/yandex_vault_sync.dart';

class YandexDiskSettings extends StatefulWidget {
  const YandexDiskSettings({
    super.key,
    required this.oauth,
    required this.sync,
    required this.onUpload,
    required this.onDownload,
  });

  final YandexDiskOAuthService oauth;
  final YandexVaultSync sync;
  final Future<void> Function() onUpload;
  final Future<void> Function() onDownload;

  @override
  State<YandexDiskSettings> createState() => _YandexDiskSettingsState();
}

class _YandexDiskSettingsState extends State<YandexDiskSettings>
    with WidgetsBindingObserver {
  var _loading = true;
  var _working = false;
  var _connected = false;
  var _folder = 'KeyKeep';
  List<String> _folders = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final connected = await widget.oauth.isConnected;
    final folder = await widget.oauth.syncFolder();
    List<String> folders = const [];
    if (connected) {
      try {
        folders = await widget.sync.listFolders();
      } catch (_) {
        // Connection errors are shown only after an explicit user action.
      }
    }
    if (mounted) {
      setState(() {
        _connected = connected;
        _folder = folder;
        _folders = folders;
        _loading = false;
      });
    }
  }

  Future<void> _connect() async {
    setState(() => _working = true);
    try {
      await widget.oauth.startAuthorization();
      _message('Подтвердите доступ в браузере и вернитесь в KeyKeep.');
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _chooseFolder() async {
    final controller = TextEditingController(text: _folder);
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Папка синхронизации'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_folders.isNotEmpty)
              DropdownButtonFormField<String>(
                initialValue: _folders.contains(_folder) ? _folder : null,
                decoration: const InputDecoration(labelText: 'Папка на Диске'),
                items: _folders
                    .map(
                      (folder) =>
                          DropdownMenuItem(value: folder, child: Text(folder)),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) controller.text = value;
                },
              ),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Имя новой или существующей папки',
                helperText: 'Папка создаётся внутри защищённой папки KeyKeep.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Выбрать'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (selected == null) return;
    try {
      await widget.oauth.saveSyncFolder(selected);
      await widget.sync.prepareFolder(await widget.oauth.syncFolder());
      await _refresh();
      _message('Папка синхронизации выбрана.');
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _working = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Яндекс Диск')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Синхронизация хранилища',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                'Хранилище сохраняется как зашифрованный KeePass-файл. Для каждой загрузки создаётся отдельная версия.',
              ),
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  leading: Icon(
                    _connected
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                  ),
                  title: Text(
                    _connected
                        ? 'Яндекс Диск подключён'
                        : 'Яндекс Диск не подключён',
                  ),
                  subtitle: Text(
                    _connected
                        ? 'Доступ предоставлен вашему аккаунту'
                        : 'Войдите и подтвердите доступ в браузере',
                  ),
                  trailing: _connected
                      ? TextButton(
                          onPressed: _working
                              ? null
                              : () async {
                                  await widget.oauth.disconnect();
                                  await _refresh();
                                },
                          child: const Text('Отключить'),
                        )
                      : null,
                ),
              ),
              if (!_connected) ...[
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _working ? null : _connect,
                  icon: const Icon(Icons.login),
                  label: const Text('Подключить Яндекс Диск'),
                ),
              ] else ...[
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('Папка синхронизации'),
                    subtitle: Text('$_folder / keykeep-vault.kdbx'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _working ? null : _chooseFolder,
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _working ? null : () => _run(widget.onUpload),
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Загрузить локальное хранилище'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _working ? null : () => _run(widget.onDownload),
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('Восстановить хранилище с Диска'),
                ),
              ],
              const SizedBox(height: 12),
              const Card(
                child: ListTile(
                  leading: Icon(Icons.lock_outline),
                  title: Text('Защищённая папка приложения'),
                  subtitle: Text(
                    'KeyKeep видит только свои папки на вашем Яндекс Диске. Другие файлы Диска недоступны.',
                  ),
                ),
              ),
            ],
          ),
  );
}
