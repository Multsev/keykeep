import 'package:flutter/material.dart';

class AboutKeyKeep extends StatelessWidget {
  const AboutKeyKeep({super.key});

  static const _version = String.fromEnvironment(
    'APP_RELEASE_VERSION',
    defaultValue: 'локальная сборка',
  );
  static const _buildDate = String.fromEnvironment(
    'APP_BUILD_DATE',
    defaultValue: 'дата сборки не указана',
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('О приложении')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Icon(Icons.shield_outlined, size: 56),
        const SizedBox(height: 16),
        Text(
          'KeyKeep',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        const Text(
          'Локальный менеджер паролей с совместимостью KeePass',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.numbers_outlined),
                title: const Text('Версия'),
                trailing: Text(_version),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('Дата сборки'),
                trailing: Text(_buildDate),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
