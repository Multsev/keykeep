import 'package:flutter_test/flutter_test.dart';
import 'package:keykeep_passwords/domain/password_entry.dart';
import 'package:keykeep_passwords/domain/vault_folder.dart';
import 'package:keykeep_passwords/services/kdbx_vault_codec.dart';

void main() {
  test(
    'round trips folders and protected custom fields through KDBX',
    () async {
      final codec = KdbxVaultCodec();
      final bytes = await codec.export(
        password: 'vault-password',
        folders: const [
          VaultFolder(id: 'root', name: 'Все записи'),
          VaultFolder(id: 'work', name: 'Работа'),
        ],
        entries: [
          PasswordEntry(
            id: 'entry-1',
            title: 'Почта',
            username: 'max@example.com',
            password: 'correct-horse-battery-staple',
            website: '',
            note: '',
            updatedAt: DateTime(2026),
            folderId: 'work',
            customFields: const [
              CustomField(
                name: 'API token',
                value: 'token-123',
                type: CustomFieldType.protected,
              ),
            ],
          ),
        ],
      );
      final restored = await codec.import(bytes, 'vault-password');
      expect(restored.folders.map((folder) => folder.name), contains('Работа'));
      expect(
        restored.entries.single.customFields.single.type,
        CustomFieldType.protected,
      );
      expect(restored.entries.single.customFields.single.value, 'token-123');
    },
  );
}
