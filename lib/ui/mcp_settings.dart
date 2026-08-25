import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keykeep_passwords/services/password_mcp_controller.dart';

/// Controls the explicitly opt-in, token-protected local MCP endpoint.
class McpSettings extends StatelessWidget {
  const McpSettings({super.key, required this.controller});

  final PasswordMcpController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('MCP для ИИ')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Локальный доступ',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          const Text(
            'Codex или другой MCP-клиент сможет работать с разблокированным хранилищем, пока телефон и компьютер находятся в одной Wi-Fi сети.',
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.memory_outlined),
                    title: const Text('Локальный MCP-сервер'),
                    subtitle: Text(
                      controller.isRunning
                          ? 'Работает до блокировки хранилища или ухода приложения в фон'
                          : 'Выключен — доступ к паролям по сети закрыт',
                    ),
                    value: controller.isRunning,
                    onChanged: (enabled) async {
                      if (enabled) {
                        await controller.start(readWrite: controller.readWrite);
                      } else {
                        await controller.stop();
                      }
                    },
                  ),
                  if (controller.isRunning) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      controller.endpoint!,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => _copyCommand(context),
                      icon: const Icon(Icons.content_copy_outlined),
                      label: const Text('Скопировать команду для Codex'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.edit_outlined),
                  title: const Text('Разрешить редактирование'),
                  subtitle: const Text(
                    'Каждое изменение потребуется подтвердить на телефоне',
                  ),
                  value: controller.readWrite,
                  onChanged: controller.setReadWrite,
                ),
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: const Text('Обновить ключ доступа'),
                  subtitle: const Text(
                    'Старые подключения перестанут работать',
                  ),
                  onTap: () => _rotateToken(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Card(
            child: ListTile(
              leading: Icon(Icons.warning_amber_outlined),
              title: Text('Данные хранилища'),
              subtitle: Text(
                'Структура доступна в режиме чтения. Каждый запрос пароля или защищённого поля, а также каждое изменение, подтверждается на телефоне.',
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _copyCommand(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: controller.connectionCommand));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Команда подключения для Codex скопирована'),
        ),
      );
    }
  }

  Future<void> _rotateToken(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Обновить ключ MCP?'),
        content: const Text('Старая команда подключения перестанет работать.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Обновить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.rotateToken();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Ключ MCP обновлён')));
    }
  }
}
