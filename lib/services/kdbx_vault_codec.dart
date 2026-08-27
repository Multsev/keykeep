import 'dart:convert';
import 'dart:typed_data';

import 'package:kdbx/kdbx.dart';
import 'package:keykeep_passwords/domain/password_entry.dart';
import 'package:keykeep_passwords/domain/vault_folder.dart';

class VaultSnapshot {
  const VaultSnapshot({required this.folders, required this.entries});
  final List<VaultFolder> folders;
  final List<PasswordEntry> entries;
}

/// Converts the compact local model to an interoperable KeePass KDBX file.
class KdbxVaultCodec {
  Future<Uint8List> export({
    required List<VaultFolder> folders,
    required List<PasswordEntry> entries,
    required String password,
    Uint8List? keyFile,
  }) async {
    final file = KdbxFormat().create(
      Credentials.composite(ProtectedValue.fromString(password), keyFile),
      'KeyKeep',
      generator: 'KeyKeep',
    );
    final groups = <String, KdbxGroup>{'root': file.body.rootGroup};
    final pending = folders.where((folder) => folder.id != 'root').toList();
    // Folders may arrive unsorted. Create them only after their parent exists,
    // preserving the full group tree in the KDBX file.
    while (pending.isNotEmpty) {
      final created = pending
          .where((folder) => groups.containsKey(folder.parentId))
          .toList();
      if (created.isEmpty) break;
      for (final folder in created) {
        final parent = groups[folder.parentId]!;
        final group = KdbxGroup.create(
          ctx: file.ctx,
          parent: parent,
          name: folder.name,
        );
        parent.addGroup(group);
        groups[folder.id] = group;
        pending.remove(folder);
      }
    }
    for (final item in entries) {
      final parent = groups[item.folderId] ?? file.body.rootGroup;
      final entry = KdbxEntry.create(file, parent);
      parent.addEntry(entry);
      _set(entry, KdbxKeyCommon.TITLE, item.title);
      _set(entry, KdbxKeyCommon.USER_NAME, item.username);
      _set(entry, KdbxKeyCommon.PASSWORD, item.password, protected: true);
      _set(entry, KdbxKeyCommon.URL, item.website);
      _set(entry, KdbxKey('Notes'), item.note);
      for (final field in item.customFields) {
        _set(
          entry,
          KdbxKey(field.name),
          field.value,
          protected: field.type != CustomFieldType.text,
        );
      }
      if (item.history.isNotEmpty) {
        _set(
          entry,
          KdbxKey('KeyKeep:PasswordHistory'),
          jsonEncode(
            item.history.map((revision) => revision.toJson()).toList(),
          ),
          protected: true,
        );
      }
    }
    return file.save();
  }

  Future<VaultSnapshot> import(
    Uint8List source,
    String password, {
    Uint8List? keyFile,
  }) async {
    final file = await KdbxFormat().read(
      source,
      Credentials.composite(ProtectedValue.fromString(password), keyFile),
    );
    final folders = <VaultFolder>[
      const VaultFolder(id: 'root', name: 'Все записи'),
    ];
    final entries = <PasswordEntry>[];
    void readGroup(KdbxGroup group, String folderId) {
      for (final entry in group.entries) {
        final values = {
          for (final value in entry.stringEntries) value.key.key: value.value,
        };
        final custom = values.entries
            .where(
              (value) => !const {
                'Title',
                'UserName',
                'Password',
                'URL',
                'Notes',
                'KeyKeep:PasswordHistory',
              }.contains(value.key),
            )
            .map(
              (value) => CustomField(
                name: value.key,
                value: value.value?.getText() ?? '',
                type:
                    value.key.toUpperCase().contains('TOTP') ||
                        value.key.toUpperCase().contains('OTP')
                    ? CustomFieldType.oneTimePassword
                    : (value.value is ProtectedValue
                          ? CustomFieldType.protected
                          : CustomFieldType.text),
              ),
            )
            .toList();
        entries.add(
          PasswordEntry(
            id: entry.uuid.toString(),
            title: values['Title']?.getText() ?? 'Без названия',
            username: values['UserName']?.getText() ?? '',
            password: values['Password']?.getText() ?? '',
            website: values['URL']?.getText() ?? '',
            note: values['Notes']?.getText() ?? '',
            updatedAt: DateTime.now(),
            folderId: folderId,
            customFields: custom,
            history: _history(values['KeyKeep:PasswordHistory']?.getText()),
          ),
        );
      }
      for (final groupChild in group.groups) {
        final id = groupChild.uuid.toString();
        folders.add(
          VaultFolder(
            id: id,
            name: groupChild.name.get() ?? 'Папка',
            parentId: folderId,
          ),
        );
        readGroup(groupChild, id);
      }
    }

    readGroup(file.body.rootGroup, 'root');
    return VaultSnapshot(folders: folders, entries: entries);
  }

  void _set(
    KdbxEntry entry,
    KdbxKey key,
    String value, {
    bool protected = false,
  }) {
    if (value.isNotEmpty) {
      entry.setString(
        key,
        protected ? ProtectedValue.fromString(value) : PlainValue(value),
      );
    }
  }

  List<PasswordRevision> _history(String? source) {
    if (source == null) return const [];
    try {
      return (jsonDecode(source) as List<dynamic>)
          .map(
            (item) => PasswordRevision.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
