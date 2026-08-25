import 'package:flutter/material.dart';
import 'package:keykeep_passwords/domain/password_entry.dart';
import 'package:keykeep_passwords/domain/vault_folder.dart';
import 'package:keykeep_passwords/services/password_generator.dart';

class PasswordEditor extends StatefulWidget {
  const PasswordEditor({super.key, required this.folders, this.entry});

  final PasswordEntry? entry;
  final List<VaultFolder> folders;

  @override
  State<PasswordEditor> createState() => _PasswordEditorState();
}

class _PasswordEditorState extends State<PasswordEditor> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _website = TextEditingController();
  final _note = TextEditingController();
  var _obscure = true;
  late String _folderId;
  late List<CustomField> _customFields;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _folderId = entry?.folderId ?? 'root';
    _customFields = [...?entry?.customFields];
    if (entry != null) {
      _title.text = entry.title;
      _username.text = entry.username;
      _password.text = entry.password;
      _website.text = entry.website;
      _note.text = entry.note;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _username.dispose();
    _password.dispose();
    _website.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final current = widget.entry;
    final entry = current == null
        ? PasswordEntry(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            title: _title.text.trim(),
            username: _username.text.trim(),
            password: _password.text,
            website: _website.text.trim(),
            note: _note.text.trim(),
            updatedAt: DateTime.now(),
            folderId: _folderId,
            customFields: _customFields,
          )
        : current.copyWith(
            title: _title.text.trim(),
            username: _username.text.trim(),
            password: _password.text,
            website: _website.text.trim(),
            note: _note.text.trim(),
            folderId: _folderId,
            customFields: _customFields,
          );
    Navigator.pop(context, entry);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.entry == null ? 'Новая запись' : 'Изменить запись'),
      actions: [TextButton(onPressed: _save, child: const Text('Сохранить'))],
    ),
    body: SafeArea(
      child: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String>(
              initialValue: _folderId,
              decoration: const InputDecoration(labelText: 'Папка'),
              items: widget.folders
                  .map(
                    (folder) => DropdownMenuItem(
                      value: folder.id,
                      child: Text(folder.name),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _folderId = value ?? 'root'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Название',
                hintText: 'Например, Рабочая почта',
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Укажите название'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Логин или e-mail'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Укажите логин'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Пароль',
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.casino_outlined),
                      tooltip: 'Сгенерировать',
                      onPressed: () => setState(
                        () => _password.text = const PasswordGenerator()
                            .generate(),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ],
                ),
              ),
              validator: (value) =>
                  value == null || value.isEmpty ? 'Укажите пароль' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _website,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Сайт (необязательно)',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _note,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Заметка (необязательно)',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  'Пользовательские поля',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addCustomField,
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить'),
                ),
              ],
            ),
            for (final field in _customFields)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(field.name),
                subtitle: Text(
                  field.type == CustomFieldType.protected
                      ? 'Защищённое поле'
                      : 'Текстовое поле',
                ),
                trailing: IconButton(
                  onPressed: () => setState(() => _customFields.remove(field)),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _addCustomField() async {
    final name = TextEditingController();
    final value = TextEditingController();
    var type = CustomFieldType.text;
    final field = await showDialog<CustomField>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Пользовательское поле'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Название'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: value,
                obscureText: type != CustomFieldType.text,
                decoration: InputDecoration(
                  labelText: type == CustomFieldType.oneTimePassword
                      ? 'Base32-секрет TOTP'
                      : 'Значение',
                ),
              ),
              DropdownButtonFormField<CustomFieldType>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Тип'),
                items: const [
                  DropdownMenuItem(
                    value: CustomFieldType.text,
                    child: Text('Текстовое'),
                  ),
                  DropdownMenuItem(
                    value: CustomFieldType.protected,
                    child: Text('Защищённое'),
                  ),
                  DropdownMenuItem(
                    value: CustomFieldType.oneTimePassword,
                    child: Text('TOTP (одноразовые коды)'),
                  ),
                ],
                onChanged: (next) =>
                    setDialogState(() => type = next ?? CustomFieldType.text),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                CustomField(
                  name: name.text.trim(),
                  value: value.text,
                  type: type,
                ),
              ),
              child: const Text('Добавить'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    value.dispose();
    if (field != null && field.name.isNotEmpty) {
      setState(() => _customFields.add(field));
    }
  }
}
