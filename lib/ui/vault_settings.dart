import 'package:flutter/material.dart';
import 'package:keykeep_passwords/services/password_mcp_controller.dart';
import 'package:keykeep_passwords/ui/mcp_settings.dart';

class VaultSettings extends StatefulWidget {
  const VaultSettings({
    super.key,
    required this.biometricEnabled,
    required this.biometricAutoPrompt,
    required this.onEnableBiometrics,
    required this.onDisableBiometrics,
    required this.onSetAutoPrompt,
    required this.onImportVault,
    required this.onExportVault,
    required this.onDeleteVault,
    required this.mcpController,
  });

  final bool biometricEnabled;
  final bool biometricAutoPrompt;
  final Future<bool> Function() onEnableBiometrics;
  final Future<void> Function() onDisableBiometrics;
  final Future<void> Function(bool enabled) onSetAutoPrompt;
  final Future<void> Function() onImportVault;
  final Future<void> Function() onExportVault;
  final Future<void> Function() onDeleteVault;
  final PasswordMcpController mcpController;

  @override
  State<VaultSettings> createState() => _VaultSettingsState();
}

class _VaultSettingsState extends State<VaultSettings> {
  late var _biometricEnabled = widget.biometricEnabled;
  late var _autoPrompt = widget.biometricAutoPrompt;

  Future<void> _toggleBiometrics(bool enabled) async {
    if (!enabled) {
      await widget.onDisableBiometrics();
      if (mounted) setState(() => _biometricEnabled = false);
      return;
    }
    final enabledNow = await widget.onEnableBiometrics();
    if (mounted && enabledNow) {
      setState(() {
        _biometricEnabled = true;
        _autoPrompt = true;
      });
    }
  }

  Future<void> _deleteVault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Удалить хранилище?'),
        content: const Text(
          'Все локальные записи, папки, мастер-PIN и настройки биометрии будут удалены с устройства. Файлы на Яндекс Диске не затрагиваются.',
        ),
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
    if (confirmed == true) await widget.onDeleteVault();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Настройки')),
    body: ListView(
      children: [
        const _SectionTitle('Безопасность'),
        SwitchListTile(
          secondary: const Icon(Icons.fingerprint),
          title: const Text('Вход по биометрии'),
          subtitle: const Text('Отпечаток пальца или распознавание лица'),
          value: _biometricEnabled,
          onChanged: _toggleBiometrics,
        ),
        if (_biometricEnabled)
          SwitchListTile(
            secondary: const Icon(Icons.login),
            title: const Text('Запрашивать сразу при открытии'),
            subtitle: const Text('Биометрия будет предложена автоматически'),
            value: _autoPrompt,
            onChanged: (enabled) async {
              await widget.onSetAutoPrompt(enabled);
              if (mounted) setState(() => _autoPrompt = enabled);
            },
          ),
        const _SectionTitle('Интеграции'),
        ListTile(
          leading: const Icon(Icons.memory_outlined),
          title: const Text('MCP для ИИ'),
          subtitle: Text(
            widget.mcpController.isRunning
                ? 'Локальный сервер включён'
                : 'Локальный доступ к хранилищу выключен',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => McpSettings(controller: widget.mcpController),
            ),
          ),
        ),
        const _SectionTitle('Хранилище'),
        ListTile(
          leading: const Icon(Icons.folder_open_outlined),
          title: const Text('Открыть другое хранилище KeePass'),
          subtitle: const Text('Заменяет локальные записи данными из .kdbx'),
          trailing: const Icon(Icons.chevron_right),
          onTap: widget.onImportVault,
        ),
        ListTile(
          leading: const Icon(Icons.ios_share_outlined),
          title: const Text('Экспортировать хранилище KeePass'),
          subtitle: const Text('Создать защищённый файл .kdbx'),
          trailing: const Icon(Icons.chevron_right),
          onTap: widget.onExportVault,
        ),
        ListTile(
          leading: const Icon(Icons.delete_forever_outlined, color: Colors.red),
          title: const Text('Удалить локальное хранилище'),
          subtitle: const Text('Не удаляет резервные копии на Яндекс Диске'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _deleteVault,
        ),
      ],
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.value);
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(value, style: Theme.of(context).textTheme.titleSmall),
  );
}
